#Requires -Version 7.0
<#
.SYNOPSIS
    Container Apps上のMinecraftサーバーの現在の状態を表示します。

.DESCRIPTION
    レプリカ数、実行状態、Ingress FQDN、直近のリビジョン情報を取得して表示します。
    読み取り専用のスクリプトであり、リソースへの変更は行いません。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.EXAMPLE
    ./scripts/status-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) が見つかりません。'
    }

    $app = az containerapp show `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --output json | ConvertFrom-Json

    if (-not $app) {
        throw "Container Appが見つかりません: $AppName ($ResourceGroupName)"
    }

    $replicas = az containerapp replica list `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --output json | ConvertFrom-Json

    $runningCount = @($replicas | Where-Object { $_.properties.runningState -eq 'Running' }).Count

    $status = [PSCustomObject]@{
        AppName       = $app.name
        FQDN          = $app.properties.configuration.ingress.fqdn
        Port          = $app.properties.configuration.ingress.exposedPort
        MinReplicas   = $app.properties.template.scale.minReplicas
        MaxReplicas   = $app.properties.template.scale.maxReplicas
        RunningRepl   = $runningCount
        ActiveRevision = $app.properties.latestRevisionName
        ProvisioningState = $app.properties.provisioningState
    }

    $status | Format-List

    if ($runningCount -gt 0) {
        Write-Host "サーバーは起動中です。接続先: $($status.FQDN):25565" -ForegroundColor Green
    }
    else {
        Write-Host 'サーバーは現在停止中です (レプリカ0)。' -ForegroundColor Yellow
    }

    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
