param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AccountName,
    [string]$ModelName = "gpt-5",
    [string]$ModelVersion = "2025-08-07",
    [string]$DeploymentName = "gpt-5-ptu",
    [string]$SKUName = "DataZoneProvisionedManaged",
    [string]$ModelFormat = "OpenAI",
    [string]$CapacityVariableName = "PTUCalculatedCapacity"
)

$VerbosePreference = 'SilentlyContinue'
$ProgressPreference  = 'SilentlyContinue'
$InformationPreference = 'Continue'

$script:RunbookName = "Runbook-UpdatePTUCapacity"
$script:WebhookUrl = ""

Import-Module -Name Webhook-Alert

function Send-Alert {
    param([string]$Message)

    if ([string]::IsNullOrEmpty($script:WebhookUrl)) {
        Write-Warning "Missing webhook URL or secret; alert skipped."
        return
    }

    $alertContent = "[$($script:RunbookName)]`nAlert: $Message`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
    Send-AlertByProvider -WebhookUrl $script:WebhookUrl -Message $alertContent
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][ScriptBlock]$ScriptBlock,
        [int]$RetryCount = 3,
        [int]$InitialDelaySeconds = 2,
        [string]$Operation = "operation"
    )

    $nonretryErrors = @("Authentication", "Authorization", "ResourceNotFound", "NotFound", "BadRequest", "QuotaExceeded")

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
            if ($_.Exception.Message -match ($nonretryErrors -join "|")) {
                throw
            }

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

    # Requires Cognitive Services Contributor role on the Subscription assigned to the Automation Account Managed Identity
    # https://learn.microsoft.com/en-us/rest/api/aiservices/accountmanagement/location-based-model-capacities/list?view=rest-aiservices-accountmanagement-2024-10-01&tabs=HTTP#code-try-0
    [object] GetModelCapacities([string]$location, [string]$modelFormat, [string]$modelName, [string]$modelVersion, [string]$skuName) {
        $uri = "$($this.BaseUrl)/providers/$($this.Provider)/locations/$location/modelCapacities?api-version=$($this.ApiVersion)&modelFormat=$modelFormat&modelName=$modelName&modelVersion=$modelVersion"

        try {
            $response = Invoke-WithRetry -Operation "Get model capacities" -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Get -Headers $this.GetHeaders()
            }

            if ($null -eq $response -or $null -eq $response.value) {
                Write-Warning "Model capacities response is empty. Skipped. "
                # throw [InvalidOperationException]::new("Model capacities response is empty.")
            }

            foreach ($item in $response.value) {
                if ($item.name -eq $skuName) {
                    return $item.properties.availableCapacity
                }
            }

            $msg = "SKU '$skuName' not found in model capacities."
            Write-Warning $msg
            # throw [InvalidOperationException]::new($msg)
        } catch {
            Write-Error "Error calling Model Capacities List API: $($_.Exception.Message)"
            # throw
        }

        return -1
    }

    [object] UpdateModelCapacity([string]$resourceGroupName, [string]$accountName, [string]$deploymentName, [string]$skuName, [int]$ptuCapacity) {
        $basePath = "$($this.BaseUrl)/resourceGroups/$resourceGroupName/providers/$($this.Provider)/accounts/$accountName/deployments/$deploymentName"
        $uriBuilder = [System.UriBuilder]::new($basePath)
        $uriBuilder.Query = "api-version=$($this.ApiVersion)"
        $uri = $uriBuilder.Uri.AbsoluteUri

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

function Determine-PTUCapacity {
    param([string]$CapacityVariableName)
    
    $targetCapacity = Get-AutomationVariable -Name $CapacityVariableName

    Write-Information "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')  capacities - Target: $targetCapacity"

    if ($targetCapacity -gt 0) {
        return $targetCapacity
    }

    throw [InvalidOperationException]::new("No valid PTU capacity available from '$CapacityVariableName'.")
}

function Confirm-PTUCapacityAvailable {
    param(
        [MgmtCognitiveServices]$MgmtClient,
        [string]$Location,
        [string]$ModelFormat,
        [string]$ModelName,
        [string]$ModelVersion,
        [string]$SKUName,
        [int]$CurrentCapacity,
        [int]$RequestedCapacity,
        [string]$DeploymentName
    )

    if ([string]::IsNullOrWhiteSpace($Location)) {
        Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') No location provided; skipping capacity validation."
        return
    }

    $availableCapacities = $MgmtClient.GetModelCapacities($Location, $ModelFormat, $ModelName, $ModelVersion, $SKUName)
    if ($availableCapacities -le 0) {
        $msg = "Failed to retrieve available capacities for model '$ModelName' version '$ModelVersion' in location '$Location'. Skipping capacity check."
        Write-Warning $msg
        return
    }

    if ($availableCapacities -lt $RequestedCapacity) {
        $msg = "Insufficient PTU capacity: Requested '$RequestedCapacity' exceeds available '$availableCapacities' for model '$ModelName' version '$ModelVersion' in location '$Location'."
        Write-Error $msg
        Send-Alert -Message $msg
        throw [InvalidOperationException]::new($msg)
    }

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Sufficient capacity $availableCapacities for model '$ModelName' version '$ModelVersion' in location '$Location'. Updating deployment '$DeploymentName' capacity from $CurrentCapacity to $RequestedCapacity."
}

try {
    $script:WebhookUrl = Get-AutomationVariable -Name 'PTUWebhookUrl' -ErrorAction SilentlyContinue
    $PTUCapacity = Determine-PTUCapacity -CapacityVariableName $CapacityVariableName
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Expected capacity: $PTUCapacity"

    Invoke-WithRetry -Operation "Connect-AzAccount (Managed Identity)" -ScriptBlock {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }
    Invoke-WithRetry -Operation "az login (Managed Identity)" -ScriptBlock {
        & az login --identity --output none --only-show-errors | Out-Null
    }
    $SubscriptionId = (Get-AzContext -ErrorAction Stop).Subscription.Id

    $account = Invoke-AzCli `
        "cognitiveservices" "account" "show" `
        "--name" $AccountName `
        "--resource-group" $ResourceGroupName `
        "--output" "json" `
        "--only-show-errors" `
        -AsJson

    $deployment = Get-PTUDeployment -AccountName $AccountName -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment $DeploymentName exists. Validating capacity..."

    $deploymentSKUName = $deployment.sku.name
    if ($deploymentSKUName -ne $SKUName) {
        $msg = "Deployment '$DeploymentName' SKU Name '$deploymentSKUName' does not match expected '$SKUName'."
        throw [InvalidOperationException]::new($msg)
    }

    $currentCapacity = [int]$deployment.sku.capacity
    if ($currentCapacity -eq $PTUCapacity) {
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment '$DeploymentName' capacity is already set to '$PTUCapacity'. No update needed."
        return
    }

        $mgmtClient = [MgmtCognitiveServices]::new($SubscriptionId)

    $location = $account.location
    if ($location) {
        Confirm-PTUCapacityAvailable `
            -MgmtClient $mgmtClient `
            -Location $location `
            -ModelFormat $ModelFormat `
            -ModelName $ModelName `
            -ModelVersion $ModelVersion `
            -SKUName $SKUName `
            -CurrentCapacity $currentCapacity `
            -RequestedCapacity $PTUCapacity `
            -DeploymentName $DeploymentName
    }
    
    $updatedCapacity = $mgmtClient.UpdateModelCapacity($ResourceGroupName, $AccountName, $DeploymentName, $SKUName, $PTUCapacity)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Deployment '$DeploymentName' capacity updated successfully to '$updatedCapacity'."
} catch {
    $failureMessage = "Runbook failed: $($_.Exception.Message)"
    Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') $failureMessage"
    Send-Alert -Message $failureMessage
    throw
}