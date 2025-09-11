param()

Connect-AzAccount -Identity
az login --identity

$ResourceGroupName = Get-AutomationVariable -Name 'PTUResourceGroupName'
$AccountName = Get-AutomationVariable -Name 'PTUFoundryAccountName'
$DeploymentName = Get-AutomationVariable -Name 'PTUDeploymentName'

$WebhookUrl = Get-AutomationVariable -Name 'PTUWebhookUrl'
$RunbookName = "Runbook-DeletePTUDeployment"

function Send-Alert {
    param(
        [string]$Message
    )

    if ([string]::IsNullOrEmpty($WebhookUrl)) {
        Write-Warning "Missing Feishu webhook URL; alert skipped."
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

        $headers = @{
            "Content-Type" = "application/json"
        }

        $response = Invoke-WebRequest -Method Post -Uri $WebhookUrl -Body $body -Headers $headers -UseBasicParsing

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

# Check if deployment exists
$existing = az cognitiveservices account deployment show `
    --name $AccountName `
    --resource-group $ResourceGroupName `
    --deployment-name $DeploymentName --output json 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment $DeploymentName does not exist. Skipping deletion."
    Send-Alert -Message "Deployment '$DeploymentName' does not exist in resource '$AccountName'. Deletion skipped."
    return
}

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC'): Starting deletion for deployment '$DeploymentName' in resource '$AccountName'.`nUsing: Resource=$ResourceGroupName"

# Run the CLI delete with output redirection to capture stderr
$cliOutput = & az cognitiveservices account deployment delete `
    --name $AccountName `
    --resource-group $ResourceGroupName `
    --deployment-name $DeploymentName 2>&1

# Check exit code
if ($LASTEXITCODE -ne 0) {
    $errorMessage = $cliOutput | Out-String
    Send-Alert -Message "Failed to delete deployment '$DeploymentName'. Error: $errorMessage"
} else {
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC'): Global Provisioned deployment '$DeploymentName' deleted successfully."
}