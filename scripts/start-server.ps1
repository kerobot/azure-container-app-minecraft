#Requires -Version 7.0
<#
.SYNOPSIS
    Container Apps上のMinecraftサーバーを起動します(TCPスケールルールを誘発)。

.DESCRIPTION
    ポート25565へのTCP接続を保持してTCPスケールルールを発火させ、レプリカが0→1へ
    スケールアウトするのを待ちます。続いてServer List Pingでサーバー本体の応答を確認します。

    minReplicas は変更しません。minReplicas の変更はContainer Appのテンプレート変更にあたり、
    実行のたびに新しいリビジョンが生成されます。Container Appsは新旧リビジョンを重ねて
    切り替えるため、ワールドを session.lock で排他ロックするMinecraftでは
    'already locked' による起動失敗を引き起こします。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER TimeoutSeconds
    起動完了までのタイムアウト秒数。

.EXAMPLE
    ./scripts/start-server.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft
#>
[CmdletBinding()]
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

. "$PSScriptRoot/lib/minecraft-ping.ps1"
. "$PSScriptRoot/lib/containerapp.ps1"

$trigger = $null

try {
    Assert-AzureCli

    $app = Get-ContainerAppInfo -ResourceGroupName $ResourceGroupName -AppName $AppName
    Write-RevisionMismatchWarning -AppInfo $app

    if ([string]::IsNullOrWhiteSpace($app.Fqdn)) {
        throw "Ingress FQDNを取得できませんでした: $AppName"
    }

    # stop-server.ps1 -Force でリビジョンを非アクティブ化した場合、TCP接続だけでは
    # トラフィックが届かないため、先にリビジョンを再アクティブ化しておく必要がある。
    if (-not (Test-RevisionActive -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision)) {
        Write-Host "リビジョンが非アクティブです。再アクティブ化します: $($app.ActiveRevision)" -ForegroundColor Cyan
        az containerapp revision activate `
            --name $AppName `
            --resource-group $ResourceGroupName `
            --revision $app.ActiveRevision `
            --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            throw "リビジョンの再アクティブ化に失敗しました: $($app.ActiveRevision)"
        }
        Start-Sleep -Seconds 5
    }

    $serverStatus = Get-MinecraftServerStatus -Hostname $app.Fqdn -Port 25565
    if ($serverStatus) {
        Write-Host "サーバーは既に起動しています: $($app.Fqdn):25565 ($(Format-MinecraftServerStatus -Status $serverStatus))" -ForegroundColor Green
        exit 0
    }

    Write-Host "TCP接続でスケールアウトを誘発します: $($app.Fqdn):25565" -ForegroundColor Cyan
    # スケールルールは同時接続数を見るため、起動が終わるまで接続を張り続ける。
    $trigger = [System.Net.Sockets.TcpClient]::new()
    if (-not $trigger.ConnectAsync($app.Fqdn, 25565).Wait(30000)) {
        throw "ポート25565へ接続できませんでした: $($app.Fqdn)"
    }

    Write-Host 'レプリカの起動を待機しています...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $serverStatus = Get-MinecraftServerStatus -Hostname $app.Fqdn -Port 25565
        if ($serverStatus) { break }

        $app = Get-ContainerAppInfo -ResourceGroupName $ResourceGroupName -AppName $AppName
        $replicas = Get-ContainerAppReplicas -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision
        $crashed = Get-CrashedContainer -Replicas $replicas
        if ($crashed) {
            throw "コンテナーが繰り返しクラッシュしています (再起動 $($crashed.restartCount) 回): $($crashed.runningStateDetails)`n" +
                "  az containerapp logs show --name $AppName --resource-group $ResourceGroupName --container minecraft --tail 100"
        }

        Write-Host "待機中... (レプリカ: $(@($replicas).Count), リビジョン: $($app.ActiveRevision))"
        Start-Sleep -Seconds 10
    }

    if (-not $serverStatus) {
        throw "タイムアウト: Minecraftサーバーがステータス応答を返しませんでした ($($app.Fqdn):25565)`n" +
            "  az containerapp logs show --name $AppName --resource-group $ResourceGroupName --container minecraft --tail 100"
    }

    Write-Host "Minecraftサーバーが応答しました: $($app.Fqdn):25565 ($(Format-MinecraftServerStatus -Status $serverStatus))" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($trigger) { $trigger.Dispose() }
}
