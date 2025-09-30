import os
import json
import time
import uuid
import sys
from dotenv import load_dotenv
from azure.identity import AzureCliCredential
from azure.mgmt.automation import AutomationClient
from azure.mgmt.authorization import AuthorizationManagementClient
from azure.mgmt.resource import ResourceManagementClient
from azure.core.exceptions import ResourceNotFoundError

load_dotenv()  # Load environment variables from .env file if present

RG = os.environ["AUTOMATION_RESOURCE_GROUP_NAME"]
LOC = os.environ["LOCATION"]
AA = os.environ["AUTOMATION_ACCOUNT_NAME"]
SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]

VARS_JSON_REL = os.environ["AUTOMATION_VARIABLES_JSON"]
SCHEDULES_JSON_REL = os.environ.get("AUTOMATION_SCHEDULES_JSON")
RESOURCE_DEF_JSON_REL = os.environ.get("PTU_RESOURCES_JSON")
UPDATE_RUNBOOK_PATH_REL = os.environ["UPDATE_RUNBOOK_PATH"]
UPDATE_RUNBOOK_NAME = os.environ["UPDATE_RUNBOOK_NAME"]

vars_path = os.path.abspath(VARS_JSON_REL)
schedules_path = SCHEDULES_JSON_REL
resource_def_path = RESOURCE_DEF_JSON_REL
update_runbook_path = UPDATE_RUNBOOK_PATH_REL

with open(vars_path, "r", encoding="utf-8") as f:
    vars_data = json.load(f)

schedules_data = []
if schedules_path and os.path.exists(schedules_path):
    with open(schedules_path, "r", encoding="utf-8") as f:
        schedules_data = json.load(f)
else:
    print(f"Schedules file not found or not specified: {schedules_path}")

with open(resource_def_path, "r", encoding="utf-8") as f:
    resource_def_data = json.load(f)
    ptu_rg = resource_def_data["ResourceGroupName"]
    ptu_account_name = resource_def_data["AccountName"]                                      

ptu_subscription_resource_id = f"/subscriptions/{SUBSCRIPTION_ID}"
ptu_account_required_role = "Cognitive Services Contributor"

credential = AzureCliCredential()
automation_client = AutomationClient(credential, SUBSCRIPTION_ID)
auth_client = AuthorizationManagementClient(credential, SUBSCRIPTION_ID)
resource_client = ResourceManagementClient(credential, SUBSCRIPTION_ID)

def find_role_definition_id(scope: str, role_name: str) -> str:
    for rd in auth_client.role_definitions.list(scope, filter=f"roleName eq '{role_name}'"):
        return rd.id
    raise RuntimeError(f"Role definition '{role_name}' not found in scope {scope}")

def ensure_role_assignment(principal_id: str, scope: str, role_name: str):
    role_def_id = find_role_definition_id(scope, role_name)

    existing = [
        ra for ra in auth_client.role_assignments.list_for_scope(scope)
        if ra.principal_id == principal_id and ra.role_definition_id.lower() == role_def_id.lower()
    ]
    if existing:
        print(f"Role '{role_name}' already assigned on {scope}")
        return
    assignment_name = str(uuid.uuid4())
    print(f"Assigning role '{role_name}' on {scope}")

    auth_client.role_assignments.create(
        scope,
        assignment_name,
        {
            "principal_id": principal_id,
            "role_definition_id": role_def_id,
        },
    )

def ensure_automation_account():
    print(f"Ensuring Automation Account '{AA}' in resource group '{RG}'")

    try:
        acct = automation_client.automation_account.get(RG, AA)
        print("Using existing Automation Account. Please ensure it has a managed identity assigned, with role 'Cognitive Services OpenAI Contributor' or equivalent permissions assigned on the PTU resource.")

    except ResourceNotFoundError:
        print("Creating Automation Account...")
        acct = automation_client.automation_account.create_or_update(
            RG,
            AA,
            {
                "location": LOC,
                "sku": {"name": "Basic"},
            },
        )
        
        poller = resource_client.resources.begin_update_by_id(
            acct.id,
            "2024-10-23",
            {
                "identity": {
                    "type": "SystemAssigned"
                }
            }
        )
        result = poller.result()
        time.sleep(30)
        managed_identity = result.identity
        principal_id = managed_identity.principal_id
        if not principal_id:
            raise RuntimeError(f"Managed identity was not assigned properly to {acct.id}.")

        ensure_role_assignment(principal_id, ptu_subscription_resource_id, ptu_account_required_role)
        
    return acct

def create_variables():
    print("Creating Automation Variables...")
    print(f"Variables: {vars_data.keys()}")
    for name, v in vars_data.items():
        value = json.dumps(v["Value"])
        print(f"Value for {name}: {value}")
        encrypted = bool(v.get("Encrypted", False))
        print(f"  Variable: {name}")

        automation_client.variable.create_or_update(
            RG,
            AA,
            name,
            {
                "name": name,
                "value": value,
                "is_encrypted": encrypted,
                "description": "",
            },
        )

def run_step(step_name: str, fn, *args, **kwargs):
    print(f"==> {step_name}")
    try:
        result = fn(*args, **kwargs)
        print(f"[OK] {step_name}")
        return result
    except Exception as e:
        print(f"[FAIL] {step_name}: {e}")
        raise

def read_file_utf8(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def import_and_publish_runbook(runbook_name: str, file_path: str):
    print(f"Importing runbook '{runbook_name}' from {file_path}")
    content = read_file_utf8(file_path)
    # Create or get runbook
    try:
        rb = automation_client.runbook.get(RG, AA, runbook_name)
        print(rb)
    except ResourceNotFoundError:
        rb = automation_client.runbook.create_or_update(
            RG,
            AA,
            runbook_name,
            {
                "location": LOC,
                "log_verbose": True,
                "log_progress": True,
                "runbook_type": "PowerShell72",
                "draft": {}
            },
        )
    # Replace draft content
    automation_client.runbook_draft.begin_replace_content(RG, AA, runbook_name, content)
    # Publish
    print(f"Publishing runbook '{runbook_name}'")
    poller = automation_client.runbook.begin_publish(RG, AA, runbook_name)
    poller.result()

def ensure_schedule_and_link(name, schedule_def: dict, params: dict):
    runbook_name = schedule_def["RunbookName"]
    start_time = schedule_def["StartTime"]
    frequency = schedule_def["Frequency"]
    interval = schedule_def["Interval"]
    time_zone = schedule_def.get("TimeZone", "UTC")
    parameters = schedule_def.get("Parameters", {})
    parameters.update(params or {})

    print(f"Ensuring schedule '{name}' for runbook '{runbook_name}'")
    try:
        automation_client.schedule.get(RG, AA, name)
        print(f"Schedule '{name}' already exists")
    except ResourceNotFoundError:
        automation_client.schedule.create_or_update(
            RG,
            AA,
            name,
            {
                "name": name,
                "description": "",
                "start_time": start_time,
                "frequency": frequency,
                "interval": interval,
                "time_zone": time_zone,
                "advanced_schedule": None,
            },
        )

    existing_links = [js for js in automation_client.job_schedule.list_by_automation_account(RG, AA) if js.schedule.name == name and js.runbook.name == runbook_name]
    if existing_links:
        print(f"Link for schedule '{name}' to runbook '{runbook_name}' already exists")
        return
    
    job_schedule_id = str(uuid.uuid4())
    params_payload = { key: str(value) for key, value in parameters.items() } if parameters else {}
    print(f"Linking schedule '{name}' to runbook '{runbook_name}'")
    automation_client.job_schedule.create(
        RG,
        AA,
        job_schedule_id,
        {
            "schedule": {"name": name},
            "runbook": {"name": runbook_name},
            "parameters": params_payload
        },
    )

def main():
    try:
        run_step("Ensure Automation Account", ensure_automation_account)
        run_step("Create Variables", create_variables)
        run_step(f"Import & Publish Runbook {UPDATE_RUNBOOK_NAME}", import_and_publish_runbook, UPDATE_RUNBOOK_NAME, update_runbook_path)
        for name, s in schedules_data.items():
            run_step(f"Ensure Schedule {name}", ensure_schedule_and_link, name, s, resource_def_data)
        print("Done.")
    except Exception as e:
        print("Aborting due to previous failure. ", {e})
        sys.exit(1)

if __name__ == "__main__":
    main()