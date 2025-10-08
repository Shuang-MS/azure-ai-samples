param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AccountName,
    [string]$DeploymentName = "gpt-5-ptu",
    [string]$SpillOverDeploymentName = "gpt-5",
    [string]$SKUName = "DataZoneProvisionedManaged",
    [string]$ModelName = "gpt-5",
    [string]$ModelVersion = "2025-08-07",
    [string]$ModelFormat = "OpenAI",
    [int]$DaysBefore = -1,
    [int]$DaysAfter = 0,
    [int]$HoursBefore = -1,
    [int]$HoursAfter = 0
)

$FilterDimension = "ModelDeploymentName"h
$noretryErrorCodes = @(
    "BadRequest",
    "Authentication",
    "NotFound",
    "ResourceNotFound"
)

$TargetTimeUTC = (Get-Date).ToUniversalTime()
$TargetStartTimeUTC = $TargetTimeUTC.AddDays($DaysBefore).AddHours($HoursBefore)
$TargetEndTimeUTC = $TargetTimeUTC.AddDays($DaysAfter).AddHours($HoursAfter)

$StartTimeUTC = $TargetStartTimeUTC.ToString("yyyy-MM-ddTHH:00:00Z")
$EndTimeUTC = $TargetEndTimeUTC.ToString("yyyy-MM-ddTHH:00:00Z")
$StartHourUTC = $TargetStartTimeUTC.Hour
$EndHourUTC = $TargetEndTimeUTC.Hour

Write-Output "From $StartTimeUTC to $EndTimeUTC"

class ModelInfo {
    [string]$Format
    [string]$Name
    [string]$Version

    ModelInfo([string]$format, [string]$name, [string]$version) {
        $this.Format  = $format
        $this.Name    = $name
        $this.Version = $version
    }
}

class WorkloadInfo {
    [int]$RequestPerMinute
    [int]$AvgPromptTokens
    [int]$AvgGeneratedTokens

    WorkloadInfo([int]$rpm, [int]$promptTokens, [int]$generatedTokens) {
        $this.RequestPerMinute   = $rpm
        $this.AvgPromptTokens    = $promptTokens
        $this.AvgGeneratedTokens = $generatedTokens
    }
}

class MgmtCognitiveServices {
    [string]$ApiVersion = "2024-10-01"
    [string]$Provider   = "Microsoft.CognitiveServices"
    [string]$BaseUrl
    [string]$Token

    MgmtCognitiveServices([string]$subscriptionId) {
        $this.BaseUrl = "https://management.azure.com/subscriptions/$subscriptionId"
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

    [object] CalculateModelCapacity([ModelInfo]$model, [string]$skuName, [WorkloadInfo[]]$workloads) {
        if (-not $workloads -or $workloads.Count -eq 0) {
            throw [ArgumentException]::new("At least one workload is required to calculate model capacity.")
        }

        $uri = "$($this.BaseUrl)/providers/$($this.Provider)/calculateModelCapacity?api-version=$($this.ApiVersion)"

        $workloadPayload = foreach ($workload in $workloads) {
            @{
                requestPerMinute  = $workload.RequestPerMinute
                requestParameters = @{
                    avgPromptTokens    = $workload.AvgPromptTokens
                    avgGeneratedTokens = $workload.AvgGeneratedTokens
                }
            }
        }

        $body = @{
            model = @{
                format  = $model.Format
                name    = $model.Name
                version = $model.Version
            }
            skuName   = $skuName
            workloads = $workloadPayload
        } | ConvertTo-Json -Depth 5 -Compress

        $client = $this
        try {
            $response = Invoke-WithRetry -Operation "Calculate model capacity" -ScriptBlock {
                $client.RefreshToken()
                Invoke-RestMethod -Uri $uri -Method Post -Headers $client.GetHeaders() -Body $body
            }
            return $response.estimatedCapacity.deployableValue
        } catch {
            Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Error calling Calculate Model Capacity API: $($_.Exception.Message)"
            throw
        }
    }
}

function IsInterested {
    param (
        [string]$TimeStamp,
        [int]$StartHour,
        [int]$EndHour
    )
    $dateTime = [datetime]::Parse($TimeStamp)
    $date = $dateTime.Date
    $windowStart = $date.AddHours($StartHour)
    $windowEnd = if ($EndHour -le $StartHour) {
        $date.AddDays(1).AddHours($EndHour)
    } else {
        $date.AddHours($EndHour)
    }

    return ($dateTime -ge $windowStart -and $dateTime -lt $windowEnd)
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
            if ($_.Exception.Message -match ($noretryErrorCodes -join "|")) {
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

function Get-Metrics {
    param(
        [string]$ResourceId,
        [string[]]$MetricNames,
        [string]$StartTime,
        [string]$EndTime,
        [string]$Interval = "PT1H",
        [string]$Namespace,
        [string[]]$Aggregation,
        [string]$Filter
    )

    $command = @(
        "monitor", "metrics", "list",
        "--resource", $ResourceId,
        "--metrics", $MetricNames,
        "--namespace", $Namespace,
        "--start-time", $StartTime,
        "--end-time", $EndTime,
        "--interval", $Interval,
        "--filter", $Filter,
        "--output", "json"
    )

    $command += @("--metrics", ($MetricNames -join ","))
    $command += "--aggregation"
    $command += $Aggregation

    try {
        return Invoke-AzCli @command -AsJson
    } catch {
        Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Failed to fetch metrics '$MetricNames' for resource '$ResourceId'. Reason: $($_.Exception.Message)"
        return $null
    }
}

function CollectUsageMetrics {
    param (
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$StartTime,
        [Parameter(Mandatory=$true)][string]$EndTime,
        [Parameter(Mandatory=$true)][string]$FilterDimensionName,
        [Parameter(Mandatory=$true)][string[]]$FilterDimensionValues
    )

    $metrics = @("ProcessedPromptTokens","GeneratedTokens")
    $filterStatements = foreach ($value in $FilterDimensionValues) {
        "$FilterDimensionName eq '$value'"
    }
    $metricsFilter = [string]::Join(" or ", $filterStatements)

    $usageMetrics = Get-Metrics `
        -ResourceId $ResourceId `
        -MetricNames $metrics `
        -StartTime $StartTime `
        -EndTime $EndTime `
        -Interval "PT1H" `
        -Namespace "Microsoft.CognitiveServices/accounts" `
        -Aggregation @("Total","Count") `
        -Filter $metricsFilter
    if (-not $usageMetrics -or -not $usageMetrics.value) {
        Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') No metric data returned for the specified parameters."
        return @{}
    }

    $tokensData = $usageMetrics.value

    $workloads = @{}
    foreach ($value in $FilterDimensionValues) {
        $workloads["$value"] = @{
            "ProcessedPromptTokens" = @()
            "GeneratedTokens"       = @()
        }
    }

    foreach ($data in $tokensData) {
        $metricName = $data.name.value

        foreach ($timeseries in $data.timeseries) {
            $metadataMatch = $timeseries.metadatavalues | Where-Object {
                $_.name.value -eq $FilterDimensionName.toLower()
            }

            $deploymentName = $metadataMatch | Select-Object -ExpandProperty value
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Processing metric '$metricName'... for deployment '$deploymentName'"
            
            foreach ($point in $timeseries.data) {
                $withinTargetHours = IsInterested `
                    -TimeStamp $point.timeStamp `
                    -StartHour $StartHourUTC `
                    -EndHour $EndHourUTC
                if ($withinTargetHours -and $point.total -ne $null -and $point.total -gt 0) {
                    $workloads[$deploymentName][$metricName] += $point
                    Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Added data point for '$deploymentName' at '$($point.timeStamp)': total=$($point.total), count=$($point.count)"
                }
            }
        }
    }

    return $workloads
}

function CalculateUsageMetrics {
    param (
        [MgmtCognitiveServices]$MgmtClient,
        [ModelInfo]$ModelInfo,
        [string]$SKUName,
        [object]$UsageWorkloads
    )

    $workloadInfo = @()

    foreach ($workload in $UsageWorkloads.GetEnumerator()) {
        $deploymentName = $workload.Key
        $metrics = $workload.Value
    
        $promptTokensData = $metrics["ProcessedPromptTokens"]
        $completionTokensData = $metrics["GeneratedTokens"]
        if (-not $promptTokensData -or $promptTokensData.Count -eq 0) {
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Skipping workload '$deploymentName' because no prompt token data was found in the selected window."
            continue
        }

        $totalRequests      = 0
        $totalPromptTokens  = 0.0
        $totalGenerated     = 0.0
        $bucketCount        = $promptTokensData.Count

        foreach ($point in $promptTokensData) {
            $totalRequests += [int]$point.count
            $totalPromptTokens += [double]$point.total
        }

        foreach ($point in $completionTokensData) {
            $totalGenerated += [double]$point.total
        }

        if ($totalRequests -le 0 -or $bucketCount -le 0) {
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Skipping workload '$deploymentName' because calculated request counts are zero."
            continue
        }

        $requestsPerMinute   = [int][Math]::Ceiling($totalRequests / ($bucketCount * 60))
        $avgPromptTokens     = [int][Math]::Ceiling($totalPromptTokens / $totalRequests)
        $avgGeneratedTokens  = [int][Math]::Ceiling(($totalGenerated) / $totalRequests)

        Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') For workload '$deploymentName': RPM=$requestsPerMinute, AvgPromptTokens=$avgPromptTokens, AvgGeneratedTokens=$avgGeneratedTokens"

        $workloadInfo += [WorkloadInfo]::new(
            $requestsPerMinute, 
            $avgPromptTokens, 
            $avgGeneratedTokens)
    }

    if (-not $workloadInfo -or $workloadInfo.Count -eq 0) {
        Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Unable to calculate workload statistics; no valid workloads were produced."
        return 0
    }

    $calculatedCapacity = $MgmtClient.CalculateModelCapacity(
        $ModelInfo,
        $SKUName,
        $workloadInfo
    )

    return $calculatedCapacity
}

try {
    Invoke-WithRetry -Operation "Connect-AzAccount (Managed Identity)" -ScriptBlock {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }
    Invoke-WithRetry -Operation "az login (Managed Identity)" -ScriptBlock {
        & az login --identity --output none --only-show-errors | Out-Null
    }

    $accountInfo = Invoke-AzCli `
        "cognitiveservices" "account" "show" `
        "--name" $AccountName `
        "--resource-group" $ResourceGroupName `
        "--output" "json" `
        "--only-show-errors" `
        -AsJson
    
    $resourceId = $accountInfo.id
    $subscriptionId = $accountInfo.id.Split("/")[2]

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Calculating average usage for $resourceId from $StartTimeUTC to $EndTimeUTC during hours $StartHourUTC to $EndHourUTC UTC..." 

    $usageWorkloads = CollectUsageMetrics `
        -ResourceId $resourceId `
        -StartTime $StartTimeUTC `
        -EndTime $EndTimeUTC `
        -FilterDimensionName $FilterDimension `
        -FilterDimensionValues @($DeploymentName, $SpillOverDeploymentName)
    
    if (-not $usageWorkloads -or $usageWorkloads.Count -eq 0) {
        Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') No usage data found for the specified time range and deployments."
        return
    }

    $mgmtClient = [MgmtCognitiveServices]::new($SubscriptionId)
    $modelInfo = [ModelInfo]::new($ModelFormat, $ModelName, $ModelVersion)

    $calculatedCapacity = CalculateUsageMetrics `
        -MgmtClient $mgmtClient `
        -ModelInfo $modelInfo `
        -SKUName $SKUName `
        -UsageWorkloads $usageWorkloads
    Write-Output "Calculated SKU Capacity: $calculatedCapacity"
    
    if ($calculatedCapacity -and $calculatedCapacity -gt 0) {
        Set-AutomationVariable -Name "PTUCalculatedCapacity" -Value $calculatedCapacity
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Successfully calculated and wrote $calculatedCapacity to Automation variable 'PTUCalculatedCapacity'."
    } else {
        Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') SKU capacity calculated as $calculatedCapacity; skipping update."
    }
} catch {
    Write-Error "Error: $($_.Exception.Message)"
    throw
}