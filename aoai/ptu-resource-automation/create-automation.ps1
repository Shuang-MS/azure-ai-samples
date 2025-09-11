# This script automates the creation and configuration of an Azure Automation Account.
# Required: poshdotenv module (Install-Module dotenv -Scope CurrentUser)
# Assumptions:
# - You are authenticated to Azure (run Connect-AzAccount if needed).
# - The Az.Automation module is installed (Install-Module -Name Az.Automation if not).
# - JSON files are well-formed and paths in .env are relative to the script's directory.
# - No handling for existing resources (will overwrite or fail if conflicts occur).
# - Rename .env.example to .env and fill in values before running.
# - Run the script from any directory; paths will be resolved relative to this script's location.
# - $env:SUBSCRIPTION_ID is set.

# Get the script's directory for relative path resolution
$scriptDir = $PSScriptRoot
Import-Module dotenv -Force -Verbose
Set-DotEnv -Path (Join-Path -Path $scriptDir -ChildPath ".env")

$rg = $env:ResourceGroupName
$loc = $env:Location
$aa = $env:AutomationAccountName
$subscriptionId = $env:SUBSCRIPTION_ID

# Resolve JSON paths early
$varsRelativePath = $env:AutomationVariablesJson
$varsPath = Join-Path -Path $scriptDir -ChildPath $varsRelativePath
if (Test-Path $varsPath) {
    $vars = Get-Content $varsPath -Raw | ConvertFrom-Json
} else {
    Write-Error "Variables file not found: $varsPath (resolved from $varsRelativePath)"
    exit
}

# Extract PTU values from variables.json
$ptuRg = ($vars | Where-Object { $_.Name -eq 'PTUResourceGroupName' }).Value
$ptuAccountName = ($vars | Where-Object { $_.Name -eq 'PTUFoundryAccountName' }).Value

# 1. Check if Automation Account exists; create if not
$account = Get-AzAutomationAccount -ResourceGroupName $rg -Name $aa -ErrorAction SilentlyContinue
if (-not $account) {
    Write-Output "Creating Automation Account: $aa"
    New-AzAutomationAccount -ResourceGroupName $rg -Name $aa -Location $loc
    $account = Get-AzAutomationAccount -ResourceGroupName $rg -Name $aa
}

# Enable system-assigned managed identity if not already enabled
if (-not $account.Identity -or $account.Identity.Type -ne 'SystemAssigned') {
    Write-Output "Enabling system-assigned managed identity for Automation Account: $aa"
    Set-AzAutomationAccount -ResourceGroupName $rg -Name $aa -AssignSystemIdentity $true
    $account = Get-AzAutomationAccount -ResourceGroupName $rg -Name $aa
}

$principalId = $account.Identity.PrincipalId

# Assign Contributor role to the managed identity on the PTU resource group
$scope = "/subscriptions/$subscriptionId/resourceGroups/$ptuRg"
$existingAssignment = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName "Cognitive Services OpenAI Contributor" -Scope $scope -ErrorAction SilentlyContinue
if (-not $existingAssignment) {
    Write-Output "Assigning Cognitive Services OpenAI Contributor role to managed identity on scope: $scope"
    New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName "Cognitive Services OpenAI Contributor" -Scope $scope
} else {
    Write-Output "Cognitive Services OpenAI Contributor role already assigned to managed identity on scope: $scope"
}

# 2. Create Automation Variables from JSON file
foreach ($v in $vars) {
    Write-Output "Creating variable: $($v.Name)"
    New-AzAutomationVariable -AutomationAccountName $aa -ResourceGroupName $rg -Name $v.Name -Value $v.Value -Encrypted $v.Encrypted
}

# 3. Create and import the two PowerShell 7.2 runbooks
# Resolve runbook paths
$createRelativePath = $env:CreateRunbookPath
$createPath = Join-Path -Path $scriptDir -ChildPath $createRelativePath
$deleteRelativePath = $env:DeleteRunbookPath
$deletePath = Join-Path -Path $scriptDir -ChildPath $deleteRelativePath

# Create runbook
Write-Output "Importing create runbook: $($env:CreateRunbookName) from $createPath"
Import-AzAutomationRunbook -AutomationAccountName $aa -ResourceGroupName $rg -Name $env:CreateRunbookName -Path $createPath -Type PowerShell72

# Delete runbook
Write-Output "Importing delete runbook: $($env:DeleteRunbookName) from $deletePath"
Import-AzAutomationRunbook -AutomationAccountName $aa -ResourceGroupName $rg -Name $env:DeleteRunbookName -Path $deletePath -Type PowerShell72

# 4. Publish the runbooks
Write-Output "Publishing create runbook: $($env:CreateRunbookName)"
Publish-AzAutomationRunbook -AutomationAccountName $aa -ResourceGroupName $rg -Name $env:CreateRunbookName

Write-Output "Publishing delete runbook: $($env:DeleteRunbookName)"
Publish-AzAutomationRunbook -AutomationAccountName $aa -ResourceGroupName $rg -Name $env:DeleteRunbookName

# 5. Create schedules from JSON file path in env var and link to runbooks
$schedulesRelativePath = $env:SchedulesJson
$schedulesPath = Join-Path -Path $scriptDir -ChildPath $schedulesRelativePath
if (Test-Path $schedulesPath) {
    $schedules = Get-Content $schedulesPath -Raw | ConvertFrom-Json
    foreach ($s in $schedules) {
        $startTime = [DateTime]::Parse($s.StartTime)
        Write-Output "Creating schedule: $($s.Name) for runbook $($s.RunbookName)"
        New-AzAutomationSchedule -AutomationAccountName $aa -ResourceGroupName $rg -Name $s.Name -StartTime $startTime -Frequency $s.Frequency -Interval $s.Interval -TimeZone "UTC"
        
        Write-Output "Linking schedule $($s.Name) to runbook $($s.RunbookName)"
        Register-AzAutomationScheduledRunbook -AutomationAccountName $aa -ResourceGroupName $rg -RunbookName $s.RunbookName -ScheduleName $s.Name
    }
} else {
    Write-Error "Schedules file not found: $schedulesPath (resolved from $schedulesRelativePath)"
}

# 6. List all resources in the resource group
Write-Output "Listing all resources in resource group $rg:"
Get-AzResource -ResourceGroupName $rg | Format-Table Name, ResourceType, Location

# Clean up env vars (optional)
Remove-DotEnv