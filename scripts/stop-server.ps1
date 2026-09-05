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

    TCPスケールルールはEnvoy/システムサイドカーの内部コネクションを引きずって
    `RunningAtMaxScale` のまま固着し、接続が皆無でもスケールインしないことがあります
    (`docs/troubleshooting.md` の「TCPスケールルールが固着してスケールインしない」を参照)。
    -Force を指定すると、TCPスケールルールに依存せず `az containerapp revision deactivate`
    でリビジョンを非アクティブ化し、レプリカを確実に0にします。次回 `start-server.ps1` は
    非アクティブなリビジョンを自動的に再アクティブ化してから起動します。

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

.PARAMETER Force
    TCPスケールルールによる自動スケールインを待たず、リビジョンを非アクティブ化して
    レプリカを確実に0にします。通常の待機でスケールインしない場合に使用してください。

.PARAMETER WhatIf
    実際の変更を行わず、実行内容のみ表示します。

.EXAMPLE
    ./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft

.EXAMPLE
    ./scripts/stop-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Force
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

    [switch]$SkipWait,

    [switch]$Force
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
            try {
                # itzgイメージ同梱の rcon-cli をコンテナー内部から実行する。RCONは外部公開していない。
                Invoke-ContainerAppExecCommand -ResourceGroupName $ResourceGroupName -AppName $AppName -ReplicaName $replica.name -Command 'rcon-cli save-all flush' | Out-Null
            }
            catch {
                Write-Warning "rcon-cliによる保存に失敗しました。コンテナー停止時の自動セーブに委ねます: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 10
        }
    }

    if (-not $Force -and ($SkipWait -or -not $PSCmdlet.ShouldProcess($AppName, 'スケールインの完了を待機'))) {
        Write-Host '接続が途絶えると自動的にスケールインします。' -ForegroundColor Yellow
        exit 0
    }

    if ($Force) {
        Write-Host 'リビジョンを非アクティブ化し、TCPスケールルールに依存せずレプリカを強制的に0にします...' -ForegroundColor Cyan
        if ($PSCmdlet.ShouldProcess($AppName, 'リビジョンの非アクティブ化 (強制停止)')) {
            az containerapp revision deactivate `
                --name $AppName `
                --resource-group $ResourceGroupName `
                --revision $app.ActiveRevision `
                --only-show-errors --output none
            if ($LASTEXITCODE -ne 0) {
                throw "リビジョンの非アクティブ化に失敗しました: $($app.ActiveRevision)"
            }
        }

        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $replicas = Get-ContainerAppReplicas -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision
            $running = @($replicas | Where-Object { $_.properties.runningState -eq 'Running' })
            if ($running.Count -eq 0) {
                Write-Host 'サーバーが停止しました (レプリカ0)。次回 start-server.ps1 実行時にリビジョンは自動的に再アクティブ化されます。' -ForegroundColor Green
                exit 0
            }
            Write-Host "レプリカの停止を待機中... (稼働レプリカ: $($running.Count))"
            Start-Sleep -Seconds 5
        }

        throw '非アクティブ化してもレプリカが停止しませんでした。Azureポータルでの確認が必要です。'
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

    Write-Warning "タイムアウト: レプリカがまだ稼働しています。Minecraftクライアントの接続が残っていないか確認してください。" +
        "`n  TCPスケールルールが固着している場合は -Force を付けて再実行すると、リビジョンの非アクティブ化により確実に停止できます。"
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
