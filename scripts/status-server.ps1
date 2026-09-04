#Requires -Version 7.0
<#
.SYNOPSIS
    Container Apps上のMinecraftサーバーの現在の状態を表示します。

.DESCRIPTION
    レプリカ数、実行状態、Ingress FQDN、直近のリビジョン情報を取得して表示します。
    レプリカが起動している場合は Server List Ping でサーバー本体の応答も確認します。
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

. "$PSScriptRoot/lib/minecraft-ping.ps1"
. "$PSScriptRoot/lib/containerapp.ps1"

try {
    Assert-AzureCli

    $app = Get-ContainerAppInfo -ResourceGroupName $ResourceGroupName -AppName $AppName
    Write-RevisionMismatchWarning -AppInfo $app

    $replicas = Get-ContainerAppReplicas -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision
    $runningCount = @($replicas | Where-Object { $_.properties.runningState -eq 'Running' }).Count

    $status = [PSCustomObject]@{
        AppName           = $app.Name
        FQDN              = $app.Fqdn
        Port              = $app.Port
        MinReplicas       = $app.MinReplicas
        MaxReplicas       = $app.MaxReplicas
        RunningRepl       = $runningCount
        ActiveRevision    = $app.ActiveRevision
        LatestRevision    = $app.LatestRevision
        ProvisioningState = $app.ProvisioningState
    }

    $status | Format-List

    if ($runningCount -gt 0) {
        # TCPハンドシェイクはIngress(Envoy)がバックエンド異常時でも成立させるため、
        # Server List Pingでサーバー本体の応答まで確認する。
        $serverStatus = Get-MinecraftServerStatus -Hostname $status.FQDN -Port 25565
        if ($serverStatus) {
            Write-Host "サーバーは起動中です。接続先: $($status.FQDN):25565 ($(Format-MinecraftServerStatus -Status $serverStatus))" -ForegroundColor Green
        }
        else {
            Write-Warning "レプリカは起動していますが、Minecraftサーバーがステータス応答を返しません。起動途中か、異常終了している可能性があります。"
            Write-Host "  az containerapp logs show --name $AppName --resource-group $ResourceGroupName --container minecraft --tail 100"
        }
    }
    else {
        $crashed = Get-CrashedContainer -Replicas $replicas
        if ($crashed) {
            Write-Warning "コンテナーがクラッシュしています (再起動 $($crashed.restartCount) 回): $($crashed.runningStateDetails)"
            Write-Host "  az containerapp logs show --name $AppName --resource-group $ResourceGroupName --container minecraft --tail 100"
        }
        else {
            Write-Host 'サーバーは現在停止中です (レプリカ0)。' -ForegroundColor Yellow
        }
    }

    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
