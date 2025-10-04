# Create & Delete Azure OpenAI PTU Deployments (Python Automation)

Automate scheduled creation and deletion of Azure OpenAI (AOAI) Provisioned Throughput Unit (PTU) deployments (e.g., GPT models) using Azure Automation. The Python bootstrap script provisions (idempotently) the Azure Automation Account, uploads runbooks, sets/update variables, and applies schedules so PTU capacity exists only during required hours (cost optimization).

## Components
- `create-automation.py`: Idempotent bootstrap script (Automation Account, Runbooks, Variables, Schedules).
- `runbooks/UpdatePTUDeployment.ps1`: Runbook to tear down AOAI PTU deployment resources safely.
- `variables/ptu-automation-vars.json`: Key/value definitions consumed as Automation Variables.
- `schedules/ptu-runbook-schedules.json`: Schedule definitions (e.g., create at 18:00 PDT, delete at 22:00 PDT).
- `schedules/ptu-runbook-resources.json`: Parameters for the Schedule to trigger the Runbook.
- `.env`: Local development environment variable file (not committed).

## Prerequisites
1. Azure subscription + permissions to create:
   - Resource Group
   - Automation Account
   - Role assignment (Cognitive Services Contributor) to Automation Account managed identity
2. Python 3.10+ (recommend 3.11+)
3. Azure CLI (`az --version`)
4. (Optional) PowerShell 7 if you want to run the existing PowerShell runbooks locally for testing
5. Git
6. Virtual environment tool (`python -m venv`)

## Python Environment Setup
```bash
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
```
```bash
cd aoai/ptu-resource-automation
pip install -r requirements.txt
```

## Deployment

### Set Environment Variables

```bash
cp .env.example .env
```
- Required Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AUTOMATION_RESOURCE_GROUP_NAME` | Resource group name to manage the Automation resources | ✅ |
| `LOCATION` | Region of the Automation Resource | ✅ |
| `AUTOMATION_ACCOUNT_NAME` | Automation account name | Will be created if not found |

### Set PTU Variables

```bash
cp variables/ptu-automation-vars-example.json variables/.ptu-automation-vars.json
```

- Variables to customize

| Variable | Description | Required |
|----------|-------------| ---------|
| `PTUCalculatedCapacity` | Calculated with past metrics and will be updated with other Runbooks | can be 0 |
| `PTUUpscaleCapacity` | As a sample for manually changing capacity | fallback to baseline |
| `PTUDownscaleCapacity` | As a sample for manually changing capacity | fallback to baseline |
| `PTUBaselineCapacity` | Set as baseline | 15 by default |
| `PTUWebhookUrl` | Feishu Webhook url to send alert |

### Set up Schedules

```bash
cp schedules/ptu-runbook-resources-example.json schedules/.ptu-runbook-resources.json
cp schedules/ptu-runbook-schedules-example.json schedules/.ptu-runbook-schedules.json
```
- Add resource details as parameters for Schedule
- Customize the StartTime (format "YYYY-MM-DDTHH:mm:ss" in the Timezone) & TimeZone, Frequency & Interval, IsEnabled, and Parameters (for the linked runbook) for running runbooks.

### Create Automation resources

#### Azure login

Login as a user with Contributor role to the `AUTOMATION_RESOURCE_GROUP_NAME`

```bash
az login
```
```bash
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

#### Run creation script

```bash
python create-automation.py
```

## Next steps

- Dynamically calculate the SKU Capacity base on last 7-day tokens 