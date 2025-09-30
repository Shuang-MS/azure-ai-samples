param(
    [string]$SKUName = "DataZoneProvisionedManaged",
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AccountName,
    [Parameter(Mandatory=$true)][string]$ModelName,
    [Parameter(Mandatory=$true)][string]$ModelVersion,
    [Parameter(Mandatory=$true)][string]$DeploymentName,
    [string]$ModelFormat = "OpenAI",
    [int]$ManualPTUCapacity = 15
)

$script:RunbookName = "Runbook-UpdatePTUCapacity"
$script:WebhookUrl = ""

function Send-Alert {
    param([string]$Message)

    if ([string]::IsNullOrEmpty($script:WebhookUrl)) {
        Write-Warning "Missing Feishu webhook URL or secret; alert skipped."
        return
    }

    try {
        $alertContent = "Alert: $Message`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
        $body = @{
            msg_type = "text"
            content  = @{ text = "[$($script:RunbookName)] $alertContent" }
        } | ConvertTo-Json -Depth 3

        $headers = @{ "Content-Type" = "application/json" }
        $response = Invoke-WebRequest -Method Post -Uri $script:WebhookUrl -Body $body -Headers $headers -UseBasicParsing
        $responseContent = $response | ConvertFrom-Json

        if ($responseContent.code -eq 0) {
            Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert sent successfully to Feishu webhook."
        } else {
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert failed: $($responseContent.msg)"
        }
    } catch {
        Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Failed to send alert to Feishu: $($_.Exception.Message)"
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][ScriptBlock]$ScriptBlock,
        [int]$RetryCount = 3,
        [int]$InitialDelaySeconds = 2,
        [string]$Operation = "operation"
    )

    $attempt = 0
    $delay   = [double]$InitialDelaySeconds

    while ($attempt -lt $RetryCount) {
        try {
            $attempt++
            if ($attempt -gt 1) {
                Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Retrying $Operation (attempt $attempt of $RetryCount)..."
            }

            return & $ScriptBlock
        } catch {
            if ($attempt -ge $RetryCount) {
                throw
            }

            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') $Operation failed: $($_.Exception.Message). Waiting $delay second(s) before retry."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 30)
        }
    }
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$CommandArgs,

        [switch]$AsJson,
        [int]$RetryCount = 3
    )

    $operation = "az $($CommandArgs -join ' ')"
    $result = Invoke-WithRetry -RetryCount $RetryCount -Operation $operation -ScriptBlock {
        $output = & az @CommandArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [InvalidOperationException]::new(($output | Out-String).Trim())
        }
        return $output
    }

    if ($AsJson) {
        return $result | ConvertFrom-Json
    }

    return $result
}

function Get-AutomationIntVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$DefaultValue = 0
    )

    $rawValue = Get-AutomationVariable -Name $Name -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $DefaultValue
    }

    if ([int]::TryParse($rawValue.ToString(), [ref]([int]$parsed = 0))) {
        return $parsed
    }

    Write-Warning "Automation variable '$Name' has non-numeric value '$rawValue'. Using default '$DefaultValue'."
    return $DefaultValue
}

function Get-PTUDeployment {
    param(
        [string]$AccountName,
        [string]$ResourceGroupName,
        [string]$DeploymentName
    )

    $command = @(
        "cognitiveservices", "account", "deployment", "show",
        "--name", $AccountName,
        "--resource-group", $ResourceGroupName,
        "--deployment-name", $DeploymentName,
        "--output", "json",
        "--only-show-errors"
    )

    try {
        return Invoke-AzCli @command -AsJson
    } catch {
        Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Failed to fetch deployment '$DeploymentName' for account '$AccountName' in resource group '$ResourceGroupName'. Reason: $($_.Exception.Message)"
        throw
    }
}

class MgmtCognitiveServices {
    [string]$ApiVersion = "2024-10-01"
    [string]$Provider   = "Microsoft.CognitiveServices"
    [string]$BaseUrl
    [string]$Token

    MgmtCognitiveServices([string]$subscriptionId) {
        $this.BaseUrl = "https://management.azure.com/subscriptions/$subscriptionId"
        $this.RefreshToken()
    }

    hidden [void] RefreshToken() {
        $this.Token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop).Token
    }

    hidden [hashtable] GetHeaders() {
        return @{
            Authorization = "Bearer $($this.Token)"
            "Content-Type" = "application/json"
        }
    }

    ## Todo: Use the real API to get available capacities
    [object] GetAvailableCapacities([string]$location, [string]$modelFormat, [string]$modelName, [string]$modelVersion, [string]$skuName) {
        # Placeholder implementation; replace with actual API call if available
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Fetching available capacities for model '$modelName' version '$modelVersion' in location '$location' with SKU '$skuName'."
        return 300
    }

    [object] GetModelCapacities([string]$location, [string]$modelFormat, [string]$modelName, [string]$modelVersion, [string]$skuName) {
        $uri = "$($this.BaseUrl)/providers/$($this.Provider)/locations/$location/modelCapacities?api-version=$($this.ApiVersion)&modelFormat=$modelFormat&modelName=$modelName&modelVersion=$modelVersion"

        try {
            $response = Invoke-WithRetry -Operation "Get model capacities" -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Get -Headers $this.GetHeaders()
            }

            if ($null -eq $response -or $null -eq $response.value) {
                throw [InvalidOperationException]::new("Model capacities response is empty.")
            }

            foreach ($item in $response.value) {
                if ($item.name -eq $skuName) {
                    return $item.properties.availableCapacity
                }
            }

            $msg = "SKU '$skuName' not found in model capacities."
            Write-Warning $msg
            throw [InvalidOperationException]::new($msg)
        } catch {
            Write-Error "Error calling Model Capacities List API: $($_.Exception.Message)"
            throw
        }
    }

    [object] UpdateModelCapacity([string]$resourceGroupName, [string]$accountName, [string]$deploymentName, [string]$skuName, [int]$ptuCapacity) {
        $basePath = "$($this.BaseUrl)/resourceGroups/$resourceGroupName/providers/$($this.Provider)/accounts/$accountName/deployments/$deploymentName"
        $uriBuilder = [System.UriBuilder]::new($basePath)
        $uriBuilder.Query = "api-version=$($this.ApiVersion)"
        $uri = $uriBuilder.Uri.AbsoluteUri
        Write-Verbose "Deployment Update URI: $uri"

        $body = @{
            sku = @{
                name     = $skuName
                capacity = $ptuCapacity
            }
        } | ConvertTo-Json

        try {
            $response = Invoke-WithRetry -Operation "Update deployment capacity" -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Patch -Headers $this.GetHeaders() -Body $body
            }
            return $response.sku.capacity
        } catch {
            if ($_.Exception.Message -match "Authentication|Authorization") {
                Write-Warning "Token may be expired; attempting refresh."
                $this.RefreshToken()
                try {
                    $response = Invoke-WithRetry -Operation "Update deployment capacity (after token refresh)" -ScriptBlock {
                        Invoke-RestMethod -Uri $uri -Method Patch -Headers $this.GetHeaders() -Body $body
                    }
                    return $response.sku.capacity
                } catch {
                    Write-Error "Error calling Deployments - Update API after token refresh: $($_.Exception.Message)"
                }
            } else {
                Write-Error "Error calling Deployments - Update API: $($_.Exception.Message)"
            }

            $msg = "Failed to update deployment '$deploymentName' capacity."
            Send-Alert -Message $msg
            throw
        }
    }
}

try {
    Invoke-WithRetry -Operation "Connect-AzAccount (Managed Identity)" -ScriptBlock {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }

    Invoke-WithRetry -Operation "az login (Managed Identity)" -ScriptBlock {
        & az login --identity --output none --only-show-errors | Out-Null
    }

    $SubscriptionId = (Get-AzContext -ErrorAction Stop).Subscription.Id

    $PTUCapacity      = Get-AutomationIntVariable -Name 'PTUCalculatedCapacity'
    $BaselineCapacity = Get-AutomationIntVariable -Name 'PTUBaselineCapacity'
    if ($PTUCapacity -le 0) {
        if ($ManualPTUCapacity -gt 0) {
            $PTUCapacity = $ManualPTUCapacity
            Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Using manual PTU capacity: $ManualPTUCapacity"
        } elseif ($BaselineCapacity -gt 0) {
            $PTUCapacity = $BaselineCapacity
            Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') No calculated PTU capacity found. Using baseline capacity: $BaselineCapacity"
        }
    }

    $webhookVariable = Get-AutomationVariable -Name 'PTUWebhookUrl' -ErrorAction SilentlyContinue
    if ($null -ne $webhookVariable) {
        $script:WebhookUrl = $webhookVariable
    }

    $account = Invoke-AzCli `
        "cognitiveservices" "account" "show" `
        "--name" $AccountName `
        "--resource-group" $ResourceGroupName `
        "--output" "json" `
        "--only-show-errors" `
        -AsJson

    $location = $account.location
    if ([string]::IsNullOrWhiteSpace($location)) {
        throw [InvalidOperationException]::new("Account '$AccountName' returned an empty location.")
    }

    $deployment = Get-PTUDeployment -AccountName $AccountName -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment $DeploymentName exists. Validating capacity..."

    $skuName = $deployment.sku.name
    if ($skuName -ne $SKUName) {
        $msg = "Deployment '$DeploymentName' SKU Name '$skuName' does not match expected '$SKUName'."
        throw [InvalidOperationException]::new($msg)
    }

    $currentCapacity = [int]$deployment.sku.capacity
    if ($currentCapacity -eq $PTUCapacity) {
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment '$DeploymentName' capacity is already set to '$PTUCapacity'. No update needed."
        return
    }

    $mgmtClient = [MgmtCognitiveServices]::new($SubscriptionId)
    $availableCapacities = $mgmtClient.GetModelCapacities($location, $ModelFormat, $ModelName, $ModelVersion, $SKUName)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Available capacity: $availableCapacities"

    if ($availableCapacities -lt $PTUCapacity) {
        $msg = "Insufficient PTU capacity: Requested '$PTUCapacity' exceeds available '$availableCapacities' for model '$ModelName' version '$ModelVersion' in location '$location'."
        Write-Error $msg
        Send-Alert -Message $msg
        throw [InvalidOperationException]::new($msg)
    }

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Sufficient capacity $availableCapacities for model '$ModelName' version '$ModelVersion' in location '$location'. Proceeding with deployment update..."

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Updating deployment '$DeploymentName' capacity from $currentCapacity to $PTUCapacity."
    $updatedCapacity = $mgmtClient.UpdateModelCapacity($ResourceGroupName, $AccountName, $DeploymentName, $SKUName, $PTUCapacity)

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment '$DeploymentName' capacity updated successfully to '$updatedCapacity'."
} catch {
    $failureMessage = "Runbook failed: $($_.Exception.Message)"
    Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') $failureMessage"
    Send-Alert -Message $failureMessage
    throw
}