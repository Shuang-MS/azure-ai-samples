function Get-WebhookProvider {
    param([string]$WebhookUrl)

    if ($WebhookUrl -match "oapi.dingtalk.com") {
        return "DingTalk"
    } elseif ($WebhookUrl -match "open.feishu.cn") {
        return "Feishu"
    } else {
        return "Unknown"
    }
}

function Send-Alert-DingTalk {
    param(
        [string]$WebhookUrl, 
        [string]$Message
    )

    try {
        $alertContent = "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')`nAlert: `n`t$Message`n"
        $body = @{
            msgtype = "text"
            text  = @{ content = "$alertContent" }
        } | ConvertTo-Json -Depth 3

        $headers = @{ "Content-Type" = "application/json" }
        $response = Invoke-WebRequest -Method Post -Uri $WebhookUrl -Body $body -Headers $headers -UseBasicParsing
        $responseContent = $response | ConvertFrom-Json

        if ($responseContent.errcode -eq 0) {
            Write-Information "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert sent successfully to Feishu webhook."
        } else {
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert failed: $($responseContent.msg)"
        }
    } catch {
        Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Failed to send alert to Feishu: $($_.Exception.Message)"
    }
}

function Send-Alert-Feishu {
    param(
        [string]$WebhookUrl,
        [string]$Message
    )

    try {
        $alertContent = "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')`nAlert: `n`t$Message`n"
        $body = @{
            msg_type = "text"
            content  = @{ text = "$alertContent" }
        } | ConvertTo-Json -Depth 3

        $headers = @{ "Content-Type" = "application/json" }
        $response = Invoke-WebRequest -Method Post -Uri $WebhookUrl -Body $body -Headers $headers -UseBasicParsing
        $responseContent = $response | ConvertFrom-Json

        if ($responseContent.code -eq 0) {
            Write-Information "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert sent successfully to Feishu webhook."
        } else {
            Write-Warning "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Alert failed: $($responseContent.msg)"
        }
    } catch {
        Write-Error "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') Failed to send alert to Feishu: $($_.Exception.Message)"
    }
}

function Send-AlertByProvider {
    param([string]$WebhookUrl, [string]$Message)

    $provider = Get-WebhookProvider -WebhookUrl $WebhookUrl
    $webhookAlertFunction = "Send-Alert-$provider"

    & $webhookAlertFunction -WebhookUrl $WebhookUrl -Message $Message
}

Export-ModuleMember -Function Send-AlertByProvider