#Requires -Version 7.0
<#
.SYNOPSIS
    Container Apps上のMinecraftサーバーを安全に停止します(minReplicasを0に変更)。

.DESCRIPTION
    停止前に rcon-cli save-all flush でワールドを保存してから、
    minReplicasを0に設定してスケールインします。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER SkipSave
    ワールド保存処理をスキップする場合に指定します(緊急停止時のみ使用)。

.PARAMETER WhatIf
    実際の変更を行わず、実行内容のみ表示します。

.EXAMPLE
    ./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [switch]$SkipSave
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) が見つかりません。'
    }

    $replicas = az containerapp replica list `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --output json | ConvertFrom-Json

    $runningReplica = $replicas | Where-Object { $_.properties.runningState -eq 'Running' } | Select-Object -First 1

    if ($runningReplica -and -not $SkipSave) {
        if ($PSCmdlet.ShouldProcess($AppName, 'ワールドデータをsave-all flushで保存')) {
            Write-Host "ワールドデータを保存しています (replica: $($runningReplica.name))..." -ForegroundColor Cyan
            az containerapp exec `
                --name $AppName `
                --resource-group $ResourceGroupName `
                --replica $runningReplica.name `
                --command 'rcon-cli save-all flush'

            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'rcon-cliによる保存に失敗しました。コンテナー停止時の自動セーブに委ねます。'
            }
            else {
                Start-Sleep -Seconds 15
            }
        }
    }
    elseif (-not $runningReplica) {
        Write-Host 'すでに実行中のレプリカがないため、保存処理をスキップします。' -ForegroundColor Yellow
    }
    else {
        Write-Host '-SkipSave が指定されたため、保存処理をスキップします。' -ForegroundColor Yellow
    }

    if ($PSCmdlet.ShouldProcess($AppName, 'minReplicasを0に設定')) {
        Write-Host "minReplicasを0に設定します: $AppName" -ForegroundColor Cyan
        az containerapp update `
            --name $AppName `
            --resource-group $ResourceGroupName `
            --min-replicas 0 `
            --max-replicas 1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Container Appの更新に失敗しました (終了コード: $LASTEXITCODE)"
        }
        Write-Host 'サーバーの停止処理が完了しました。' -ForegroundColor Green
    }
    else {
        Write-Host '(WhatIf) minReplicasを0に設定します。' -ForegroundColor Yellow
    }

    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
