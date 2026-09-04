#Requires -Version 7.0
<#
.SYNOPSIS
    Minecraftワールドデータのバックアップから復元します。

.DESCRIPTION
    /data/backups 配下の指定したバックアップアーカイブを展開してワールドを復元します。
    展開には起動中レプリカへの exec が必要なため、サーバーを起動したうえで
    プレイヤーの接続を禁止し、-Force を指定して実行してください。
    -DryRun を指定すると実際のコマンドは実行せず、実行予定の内容のみ表示します。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER BackupFileName
    復元するバックアップファイル名 (例: 'manual-20240101T120000Z.tar.gz')。

.PARAMETER Force
    起動中のレプリカ上で復元を続行することを明示的に承認します。
    復元中はプレイヤー接続を禁止してください(非推奨。データ不整合のリスクがあります)。

.PARAMETER DryRun
    実際のコマンドを実行せず、内容のみ表示します。

.EXAMPLE
    ./scripts/restore-world.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -BackupFileName manual-20240101T120000Z.tar.gz -Force
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [string]$BackupFileName,

    [switch]$Force,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/lib/containerapp.ps1"

try {
    Assert-AzureCli

    $app = Get-ContainerAppInfo -ResourceGroupName $ResourceGroupName -AppName $AppName
    Write-RevisionMismatchWarning -AppInfo $app

    $runningReplica = Get-RunningReplica -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision

    if ($runningReplica -and -not $Force -and -not $DryRun) {
        throw "復元には起動中レプリカへのexecが必要です。プレイヤー接続を禁止し、復元リスクを承認したうえで -Force を指定してください。"
    }

    if ($runningReplica -and $Force) {
        Write-Warning '起動中レプリカ上で -Force により復元を続行します。復元中はプレイヤー接続を禁止してください。'
    }

    # レプリカが存在しない(minReplicas=0)場合、az containerapp exec は利用できないため、
    # 一時的にレプリカを1つ起動してから復元処理を行い、完了後に再度停止する運用を前提とする。
    if (-not $runningReplica) {
        throw '復元には起動中レプリカへのexecが必要です。先に start-server.ps1 を実行し、プレイヤー接続を禁止したうえで -Force を指定して再実行してください。'
    }

    $backupPath = "/data/backups/$BackupFileName"
    $verifyCommand = "sh -c 'test -f $backupPath && echo FOUND || echo MISSING'"
    $restoreCommand = "sh -c 'rm -rf /data/world /data/world_nether /data/world_the_end && tar -xzf $backupPath -C /data && echo done'"
    $verifyIntegrityCommand = "sh -c 'test -d /data/world && test -f /data/world/level.dat && echo OK || echo NG'"

    if ($DryRun -or -not $PSCmdlet.ShouldProcess($AppName, "復元 ($BackupFileName)")) {
        Write-Host '(DryRun) 以下のコマンドを実行予定です:' -ForegroundColor Yellow
        Write-Host "  1. $verifyCommand"
        Write-Host "  2. $restoreCommand"
        Write-Host "  3. $verifyIntegrityCommand"
        exit 0
    }

    Write-Host "バックアップファイルの存在を確認しています: $backupPath" -ForegroundColor Cyan
    $verifyResult = az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $runningReplica.name --command $verifyCommand
    if ($verifyResult -notmatch 'FOUND') {
        throw "バックアップファイルが見つかりません: $backupPath"
    }

    Write-Host 'ワールドデータを復元しています...' -ForegroundColor Cyan
    az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $runningReplica.name --command $restoreCommand
    if ($LASTEXITCODE -ne 0) {
        throw "復元処理に失敗しました (終了コード: $LASTEXITCODE)"
    }

    Write-Host '復元後の整合性を確認しています...' -ForegroundColor Cyan
    $integrityResult = az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $runningReplica.name --command $verifyIntegrityCommand
    if ($integrityResult -notmatch 'OK') {
        throw '復元後の整合性確認に失敗しました。ワールドデータ(level.dat)が見つかりません。'
    }

    Write-Host '復元が完了しました。Container Appを再起動してワールドを反映してください。' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
