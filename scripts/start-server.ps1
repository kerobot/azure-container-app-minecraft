#Requires -Version 7.0
<#
.SYNOPSIS
    Container Apps上のMinecraftサーバーを起動します(minReplicasを1に変更)。

.DESCRIPTION
    az containerapp update で minReplicas=1 を設定し、レプリカが起動して
    Minecraft(TCP 25565)へ接続可能になるまで待機します。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER TimeoutSeconds
    接続確認のタイムアウト秒数。

.PARAMETER WhatIf
    実際の変更を行わず、実行内容のみ表示します。

.EXAMPLE
    ./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) が見つかりません。'
    }

    if ($PSCmdlet.ShouldProcess($AppName, 'minReplicasを1に設定')) {
        Write-Host "minReplicasを1に設定します: $AppName" -ForegroundColor Cyan
        az containerapp update `
            --name $AppName `
            --resource-group $ResourceGroupName `
            --min-replicas 1 `
            --max-replicas 1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Container Appの更新に失敗しました (終了コード: $LASTEXITCODE)"
        }
    }
    else {
        Write-Host '(WhatIf) minReplicasを1に設定します。' -ForegroundColor Yellow
        exit 0
    }

    Write-Host 'レプリカの起動を待機しています...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $replicaRunning = $false
    while ((Get-Date) -lt $deadline) {
        $replicas = az containerapp replica list `
            --name $AppName `
            --resource-group $ResourceGroupName `
            --output json | ConvertFrom-Json

        if ($replicas | Where-Object { $_.properties.runningState -eq 'Running' }) {
            $replicaRunning = $true
            break
        }
        Write-Host '待機中...'
        Start-Sleep -Seconds 10
    }

    if (-not $replicaRunning) {
        throw 'タイムアウト: レプリカが起動しませんでした。'
    }
    Write-Host 'レプリカが起動しました。' -ForegroundColor Green

    $fqdn = az containerapp show `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --query 'properties.configuration.ingress.fqdn' -o tsv

    Write-Host "Minecraftサーバーへの接続を確認しています: ${fqdn}:25565" -ForegroundColor Cyan
    $connected = $false
    $connectDeadline = (Get-Date).AddSeconds([Math]::Min($TimeoutSeconds, 300))
    while ((Get-Date) -lt $connectDeadline) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $task = $client.ConnectAsync($fqdn, 25565)
            if ($task.Wait(3000) -and $client.Connected) {
                $connected = $true
                $client.Close()
                break
            }
            $client.Close()
        }
        catch {
            # 接続失敗時は待機して再試行する。
        }
        Write-Host '接続確認中...'
        Start-Sleep -Seconds 10
    }

    if ($connected) {
        Write-Host "Minecraftサーバーに接続できます: ${fqdn}:25565" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Warning "接続確認がタイムアウトしましたが、サーバー起動処理中の可能性があります。少し待ってから再度接続してください: ${fqdn}:25565"
        exit 0
    }
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
