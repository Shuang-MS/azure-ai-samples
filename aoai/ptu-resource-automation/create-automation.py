import os
import json
import uuid
from datetime import datetime
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.mgmt.automation import AutomationClient
from azure.mgmt.authorization import AuthorizationManagementClient
from azure.mgmt.resource import ResourceManagementClient
from azure.core.exceptions import ResourceNotFoundError, HttpResponseError

# Load .env located next to this script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(SCRIPT_DIR, ".env"))

# Required env vars (same names as PowerShell script assumed)
RG = os.environ["RESOURCE_GROUP_NAME"]
LOC = os.environ["LOCATION"]
AA = os.environ["AUTOMATION_ACCOUNT_NAME"]
SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]

VARS_JSON_REL = os.environ["AUTOMATION_VARIABLES_JSON"]
SCHEDULES_JSON_REL = os.environ.get("SCHEDULES_JSON")
CREATE_RUNBOOK_PATH_REL = os.environ["CREATE_RUNBOOK_PATH"]
DELETE_RUNBOOK_PATH_REL = os.environ["DELETE_RUNBOOK_PATH"]
CREATE_RUNBOOK_NAME = os.environ["CREATE_RUNBOOK_NAME"]
DELETE_RUNBOOK_NAME = os.environ["DELETE_RUNBOOK_NAME"]

# Paths
vars_path = os.path.join(SCRIPT_DIR, VARS_JSON_REL)
schedules_path = os.path.join(SCRIPT_DIR, SCHEDULES_JSON_REL) if SCHEDULES_JSON_REL else None
create_runbook_path = os.path.join(SCRIPT_DIR, CREATE_RUNBOOK_PATH_REL)
delete_runbook_path = os.path.join(SCRIPT_DIR, DELETE_RUNBOOK_PATH_REL)

# Load JSON data
with open(vars_path, "r", encoding="utf-8") as f:
    vars_data = json.load(f)

schedules_data = []
if schedules_path and os.path.exists(schedules_path):
    with open(schedules_path, "r", encoding="utf-8") as f:
        schedules_data = json.load(f)
else:
    print(f"Schedules file not found or not specified: {schedules_path}")

# Extract PTU values
ptu_rg = next(v["Value"] for v in vars_data if v["Name"] == "PTUResourceGroupName")
ptu_account_name = next(v["Value"] for v in vars_data if v["Name"] == "PTUFoundryAccountName")  # retained for parity (not directly used)

credential = DefaultAzureCredential(exclude_interactive_browser_credential=False)
automation_client = AutomationClient(credential, SUBSCRIPTION_ID)
auth_client = AuthorizationManagementClient(credential, SUBSCRIPTION_ID)
resource_client = ResourceManagementClient(credential, SUBSCRIPTION_ID)

def ensure_automation_account():
    print(f"Ensuring Automation Account '{AA}' in resource group '{RG}'")
    try:
        acct = automation_client.automation_account.get(RG, AA)
    except ResourceNotFoundError:
        print("Creating Automation Account...")
        acct = automation_client.automation_account.create_or_update(
            RG,
            AA,
            {
                "location": LOC,
                "identity": {"type": "SystemAssigned"},
                "sku": {"name": "Basic"},
            },
        )
    # Ensure system-assigned identity
    if not getattr(acct, "identity", None) or acct.identity.type != "SystemAssigned":
        print("Enabling system-assigned managed identity...")
        acct = automation_client.automation_account.update(
            RG,
            AA,
            {
                "location": LOC,
                "identity": {"type": "SystemAssigned"},
            },
        )
    return acct

def find_role_definition_id(scope: str, role_name: str) -> str:
    for rd in auth_client.role_definitions.list(scope, filter=f"roleName eq '{role_name}'"):
        return rd.id
    raise RuntimeError(f"Role definition '{role_name}' not found in scope {scope}")

def ensure_role_assignment(principal_id: str, scope: str, role_name: str):
    role_def_id = find_role_definition_id(scope, role_name)
    # Check existing
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

def create_variables():
    print("Creating Automation Variables...")
    for v in vars_data:
        name = v["Name"]
        value = v["Value"]
        encrypted = bool(v.get("Encrypted"))
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

def read_file_utf8(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def import_and_publish_runbook(runbook_name: str, file_path: str):
    print(f"Importing runbook '{runbook_name}' from {file_path}")
    content = read_file_utf8(file_path)
    # Create or get runbook
    try:
        rb = automation_client.runbook.get(RG, AA, runbook_name)
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
    automation_client.runbook_draft.replace_content(RG, AA, runbook_name, content)
    # Publish
    print(f"Publishing runbook '{runbook_name}'")
    poller = automation_client.runbook.begin_publish(RG, AA, runbook_name)
    poller.result()

def ensure_schedule_and_link(schedule_def: dict):
    name = schedule_def["Name"]
    runbook_name = schedule_def["RunbookName"]
    start_time = datetime.fromisoformat(schedule_def["StartTime"])
    frequency = schedule_def["Frequency"]
    interval = schedule_def["Interval"]

    print(f"Creating schedule '{name}' for runbook '{runbook_name}'")
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
            "time_zone": "UTC",
            "advanced_schedule": None,
        },
    )
    # Link schedule via job schedule
    job_schedule_id = str(uuid.uuid4())
    print(f"Linking schedule '{name}' to runbook '{runbook_name}'")
    automation_client.job_schedule.create(
        RG,
        AA,
        job_schedule_id,
        {
            "schedule": {"name": name},
            "runbook": {"name": runbook_name},
        },
    )

def list_resources():
    print(f"Resources in resource group '{RG}':")
    for res in resource_client.resources.list_by_resource_group(RG):
        print(f"{res.name:40} {res.type:55} {res.location}")

def main():
    try:
        acct = ensure_automation_account()
        principal_id = acct.identity.principal_id
        scope = f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{ptu_rg}"
        ensure_role_assignment(principal_id, scope, "Cognitive Services OpenAI Contributor")
        create_variables()
        import_and_publish_runbook(CREATE_RUNBOOK_NAME, create_runbook_path)
        import_and_publish_runbook(DELETE_RUNBOOK_NAME, delete_runbook_path)
        for s in schedules_data:
            ensure_schedule_and_link(s)
        list_resources()
        print("Done.")
    except (HttpResponseError, Exception) as e:
        print(f"Error: {e}")
        raise

if __name__ == "__main__":
    main()