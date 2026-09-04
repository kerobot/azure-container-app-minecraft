#Requires -Version 7.0
<#
.SYNOPSIS
    Container Apps上のMinecraftサーバーを安全に停止します。

.DESCRIPTION
    rcon-cli save-all flush でワールドを保存したうえで、TCPスケールルールによる
    自動スケールインを待ちます。

    minReplicas は変更しません。minReplicas の変更は新しいリビジョンを生成し、
    ワールドの session.lock 競合を招くためです (`scripts/start-server.ps1` の説明を参照)。
    接続がすべて途絶えると、Bicepの `scaleCooldownSeconds` の経過後にレプリカが0になります。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER TimeoutSeconds
    スケールインを待つタイムアウト秒数。

.PARAMETER SkipSave
    ワールド保存処理をスキップする場合に指定します(緊急停止時のみ使用)。

.PARAMETER SkipWait
    スケールインの完了を待たずに終了します。

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

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 900,

    [switch]$SkipSave,

    [switch]$SkipWait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/lib/minecraft-ping.ps1"
. "$PSScriptRoot/lib/containerapp.ps1"

try {
    Assert-AzureCli

    $app = Get-ContainerAppInfo -ResourceGroupName $ResourceGroupName -AppName $AppName
    Write-RevisionMismatchWarning -AppInfo $app

    $replica = Get-RunningReplica -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision
    if (-not $replica) {
        Write-Host 'サーバーは既に停止しています (稼働中のレプリカはありません)。' -ForegroundColor Green
        exit 0
    }

    $status = Get-MinecraftServerStatus -Hostname $app.Fqdn -Port 25565
    if ($status -and $status.PSObject.Properties.Name -contains 'players' -and $status.players.online -gt 0) {
        Write-Warning "プレイヤーが $($status.players.online) 人接続中です。接続が残っている間はスケールインしません。"
    }

    if (-not $SkipSave) {
        if ($PSCmdlet.ShouldProcess($AppName, 'ワールドデータのフラッシュ保存 (save-all flush)')) {
            Write-Host 'ワールドデータをフラッシュ保存しています...' -ForegroundColor Cyan
            # itzgイメージ同梱の rcon-cli をコンテナー内部から実行する。RCONは外部公開していない。
            az containerapp exec `
                --name $AppName `
                --resource-group $ResourceGroupName `
                --replica $replica.name `
                --command 'rcon-cli save-all flush'
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'rcon-cliによる保存に失敗しました。コンテナー停止時の自動セーブに委ねます。'
            }
            Start-Sleep -Seconds 10
        }
    }

    if ($SkipWait -or -not $PSCmdlet.ShouldProcess($AppName, 'スケールインの完了を待機')) {
        Write-Host '接続が途絶えると自動的にスケールインします。' -ForegroundColor Yellow
        exit 0
    }

    Write-Host 'スケールインを待機しています (すべての接続が切断されている必要があります)...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $replicas = Get-ContainerAppReplicas -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision
        $running = @($replicas | Where-Object { $_.properties.runningState -eq 'Running' })
        if ($running.Count -eq 0) {
            Write-Host 'サーバーが停止しました (レプリカ0)。' -ForegroundColor Green
            exit 0
        }
        Write-Host "待機中... (稼働レプリカ: $($running.Count))"
        Start-Sleep -Seconds 15
    }

    Write-Warning "タイムアウト: レプリカがまだ稼働しています。Minecraftクライアントの接続が残っていないか確認してください。"
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
