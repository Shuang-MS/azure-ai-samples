# Create & Delete Azure OpenAI PTU Deployments (Python Automation)

Automate scheduled creation and deletion of Azure OpenAI (AOAI) Provisioned Throughput Unit (PTU) deployments (e.g., GPT models) using Azure Automation. The Python bootstrap script provisions (idempotently) the Azure Automation Account, uploads runbooks, sets/update variables, and applies schedules so PTU capacity exists only during required hours (cost optimization).

## Components
- `create-automation.py`: Idempotent bootstrap script (Automation Account, Runbooks, Variables, Schedules).
- `runbooks/CreatePTUDeployment.ps1`: Runbook to create/update AOAI PTU deployment resources.
- `runbooks/DeletePTUDeployment.ps1`: Runbook to tear down AOAI PTU deployment resources safely.
- `variables/ptu-runbook-vars.json`: Key/value definitions consumed as Automation Variables.
- `schedules/ptu-runbook-schedules.json`: Schedule definitions (e.g., create at 18:00 PDT, delete at 22:00 PDT).
- `.env`: Local development environment variable file (not committed).

## Prerequisites
1. Azure subscription + permissions to create:
   - Resource Group
   - Automation Account
   - Role assignment (Cognitive Services OpenAI Contributor) to Automation Account managed identity
2. Python 3.10+ (recommend 3.11+)
3. Azure CLI (`az --version`)
4. (Optional) PowerShell 7 if you want to run the existing PowerShell runbooks locally for testing
5. Git
6. Virtual environment tool (`python -m venv`)

## Python Environment Setup
```bash
# From repo root
python -m venv .venv
source .venv/bin/activate  # Windows bash (Git Bash / WSL)
pip install --upgrade pip
pip install -r requirements.txt
```

## Deployment

### Set Environment Variables

```bash
cp .env.examples .env
```
- Required Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AUTOMATION_RESOURCE_GROUP_NAME` | Resource group name to manage the Automation resources | ✅ |
| `LOCATION` | Region of the Automation Resource | ✅ |
| `AUTOMATION_ACCOUNT_NAME` | Automation account name | Will be created if not found |

### Azure login

Login as a user with Contributor role to the `AUTOMATION_RESOURCE_GROUP_NAME` 

```bash
az login
```
```bash
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

### Set PTU Variables

```bash
cp variables/ptu-runbook-vars-example.json .ptu-runbook-vars.json
```

- Variables required to customize

| Variable | Description | Required |
|----------|-------------|----------|
| `PTUResourceGroupName` | Resource group name to manage the AI Foundry resource | ✅ |
| `PTUFoundryAccountName` | AI Foundry account name to manage AOAI deployments | ✅ |
| `PTUWebhookUrl` | Feishu Webhook url to send alert | Leave blank if do not need. |

### Set up Schedules

```bash
cp schedules/ptu-runbook-schedules-example.json .ptu-runbook-schedules.json
```

- Customize the StartTime & TimeZone, Frequency & Interval, Parameters for creation and deletion runbooks.

### Create Automation resources

```bash
python create-automation.py
```

## Next steps

- Dynamically calculate the SKU Capacity base on last 7-day tokens 