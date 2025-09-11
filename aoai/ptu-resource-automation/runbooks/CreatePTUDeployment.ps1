# Optional params for overrides
param(
    [string]$SKUName = "GlobalProvisionedManaged",
    [int]$PTUCapacity = 50
)

Connect-AzAccount -Identity
az login --identity

$ResourceGroupName = Get-AutomationVariable -Name 'PTUResourceGroupName'
$AccountName = Get-AutomationVariable -Name 'PTUFoundryAccountName'
$ModelName = Get-AutomationVariable -Name 'PTUModelName'
$ModelVersion = Get-AutomationVariable -Name 'PTUModelVersion'
$ModelFormat = Get-AutomationVariable -Name 'PTUModelFormat'
$DeploymentName = Get-AutomationVariable -Name 'PTUDeploymentName'

if (-not $PTUCapacity) { $PTUCapacity = Get-AutomationVariable -Name 'PTUDefaultCapacity' }
if (-not $SKUName) { $SKUName = Get-AutomationVariable -Name 'PTUSKUName' }

$WebhookUrl = Get-AutomationVariable -Name 'PTUWebhookUrl'
$RunbookName = "Runbook-CreatePTUDeployment"

function Send-Alert {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrEmpty($WebhookUrl)) {
        Write-Warning "Missing Feishu webhook URL or secret; alert skipped."
        return
    }

    try {
        $alertContent = "Alert: $Message`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
        
        $body = @{
            msg_type = "text"
            content = @{
                text = "[$RunbookName] $alertContent"
            }
        } | ConvertTo-Json -Depth 3

        # Headers for Feishu
        $headers = @{
            "Content-Type" = "application/json"
        }

        $response = Invoke-WebRequest -Method Post -Uri $WebhookUrl -Body $body -Headers $headers -UseBasicParsing
        Write-Output "Feishu response: $($response)"
        $responseContent = $response | ConvertFrom-Json
        if ($responseContent.code -eq 0) {
            Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert sent successfully to Feishu webhook."
        } else {
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert failed: $($responseContent.msg)"
        }
    }
    catch {
        Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Failed to send alert to Feishu: $($_.Exception.Message)"
    }
}

# Validate the DeploymentName should start with ModelName
if (-not $DeploymentName.StartsWith($ModelName)) {
    Write-Error "DeploymentName '$DeploymentName' must start with ModelName '$ModelName'. Please check the Automation Variable 'PTUDeploymentName'."
    Send-Alert -Message "Mismatch DeploymentName '$DeploymentName' and ModelName '$ModelName'. The DeploymentName must start with ModelName '$ModelName'."
}

# Check if deployment exists
$existing = az cognitiveservices account deployment show `
    --name $AccountName `
    --resource-group $ResourceGroupName `
    --deployment-name $DeploymentName --output json 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment $DeploymentName already exists. Skipping creation."
    Send-Alert -Message "Deployment '$DeploymentName' already exists in resource '$AccountName'. Creation skipped."
    return
}

# Todo: Calculate PTU capacity based on last 7-day metrics if not provided
if ($PTUCapacity -le 0 -or [string]::IsNullOrEmpty($PTUCapacity)) {
    $PTUCapacity = 50  # Use provided if >0
    Write-Output "Using calculated PTU Capacity: $PTUCapacity"
}

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Starting creation for deployment '$DeploymentName' in resource '$AccountName'.`nUsing: Resource=$ResourceGroupName, Model=$ModelName v$ModelVersion, SKU=$SKUName, Capacity=$PTUCapacity"

# Run the CLI create with output redirection to capture stderr
$cliOutput = & az cognitiveservices account deployment create `
    --name $AccountName `
    --resource-group $ResourceGroupName `
    --deployment-name $DeploymentName `
    --model-name $ModelName `
    --model-version $ModelVersion `
    --model-format $ModelFormat `
    --sku-capacity $PTUCapacity `
    --sku-name $SKUName 2>&1

# Check exit code
if ($LASTEXITCODE -ne 0) {
    $errorMessage = $cliOutput | Out-String
    Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') CLI Error Output: $errorMessage"
    Send-Alert -Message "Failed to create deployment '$DeploymentName'. Error: $errorMessage"
} else {
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC'): Global Provisioned deployment '$DeploymentName' created successfully with $PTUCapacity PTUs."
}