# Create & Delete Azure OpenAI PTU Deployments with Azure Automation

Automatically create and delete Azure OpenAI (AOAI) Provisioned Throughput Unit (PTU) model deployments (e.g., GPT series) on a schedule using Azure Automation runbooks. This setup helps optimize costs by provisioning resources only during peak hours.

## Components
- **`create-automation.ps1`**: Idempotent script to bootstrap resources: Resource Group, Automation Account, Runbooks, Variables, and Schedules.
- **`runbooks/CreatePTUDeployment.ps1`**: Provisions or updates PTU AOAI deployment resources.
- **`runbooks/DeletePTUDeployment.ps1`**: Safely tears down PTU AOAI deployment resources.
- **`variables/ptu-runbook-vars.json`**: JSON definitions for Automation Account variables (e.g., resource names, model details).
- **`schedules/ptu-runbook-schedules.json`**: JSON definitions for schedules (e.g., daily create at 6 PM PDT, delete at 10 PM PDT).

## Prerequisites

1. **Azure CLI**: Install and verify with `az --version`.
2. **PowerShell 7+**: Verify with `pwsh --version`.
3. **Az PowerShell Modules**: Install the required modules (includes Automation and Resources):
   ```powershell
   Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -AllowClobber
   ```
   For environment variable loading, install the `dotenv` module (recommended for simplicity):
   ```powershell
   Install-Module -Name dotenv -Scope CurrentUser
   ```
4. **Azure Login**:
   ```powershell
   Connect-AzAccount
   ```
   Or via Azure CLI:
   ```bash
   az login
   ```
   Set your subscription ID:
   ```powershell
   $env:SUBSCRIPTION_ID = (az account show --query id -o tsv)
   ```

**Note**: Ensure the Automation Account's managed identity has Contributor role on the target Resource Group for AOAI operations. Assign it via the Azure portal or PowerShell:
```powershell
$identity = Get-AzAutomationAccount -ResourceGroupName $env:ResourceGroupName -Name $env:AutomationAccountName | Select-Object -ExpandProperty Identity
New-AzRoleAssignment -ObjectId $identity.PrincipalId -RoleDefinitionName "Contributor" -Scope "/subscriptions/$env:SUBSCRIPTION_ID/resourceGroups/$env:ResourceGroupName"
```

## Setup Environment Variables

Copy `.env.example` to `.env` and fill in your values (e.g., ResourceGroupName, Location).

To load the `.env` file (using the `dotenv` module for reliability):
```powershell
Import-Module dotenv
Set-DotEnv  # Loads ./.env by default
```

If you prefer not to use the module, use this custom loader:
```powershell
Get-Content .env | Where-Object { $_ -and ($_ -notmatch '^\s*#') } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), "Process")
    $env:($k.Trim()) = $v.Trim()
}
```

**Example `.env`** (use consistent casing; paths are relative to the repo root):
```
ResourceGroupName=your-rg-name
Location=eastus
AutomationAccountName=your-automation-account
AutomationVariablesJson=./variables/ptu-runbook-vars.json
CreateRunbookName=CreatePTUDeployment
CreateRunbookPath=./runbooks/CreatePTUDeployment.ps1
DeleteRunbookName=DeletePTUDeployment
DeleteRunbookPath=./runbooks/DeletePTUDeployment.ps1
SchedulesJson=./schedules/ptu-runbook-schedules.json
```

## Create Automation Resources

Run the bootstrap script from the repo root:
```powershell
pwsh -File ./create-automation.ps1
```

This script is idempotent—it checks for existing resources before creating them.

## Running Runbooks Manually

Start the create runbook:
```powershell
Start-AzAutomationRunbook -AutomationAccountName $env:AutomationAccountName -ResourceGroupName $env:ResourceGroupName -Name $env:CreateRunbookName
```

Start the delete runbook:
```powershell
Start-AzAutomationRunbook -AutomationAccountName $env:AutomationAccountName -ResourceGroupName $env:ResourceGroupName -Name $env:DeleteRunbookName
```

Monitor jobs:
```powershell
Get-AzAutomationJob -AutomationAccountName $env:AutomationAccountName -ResourceGroupName $env:ResourceGroupName | Select-Object JobId, RunbookName, Status, CreationTime | Format-Table
```

## Troubleshooting
- **Path Issues**: Ensure paths in `.env` are relative to the script's execution directory (e.g., `./runbooks/...`). Use absolute paths if running from elsewhere.
- **Permissions**: Verify the Automation Account's system-assigned identity has access to AOAI resources.
- **Logs**: Check runbook output in the Azure portal under Automation Account > Jobs.
- **Cleanup**: To delete resources, use `Remove-AzAutomationAccount` or the portal.