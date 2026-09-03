#Requires -Version 7.0
<#
.SYNOPSIS
    Minecraftワールドデータのバックアップから復元します。

.DESCRIPTION
    /data/backups 配下の指定したバックアップアーカイブを展開してワールドを復元します。
    データ不整合を避けるため、復元前にサーバーを停止(minReplicas=0)することを強く推奨します。
    -DryRun を指定すると実際のコマンドは実行せず、実行予定の内容のみ表示します。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER BackupFileName
    復元するバックアップファイル名 (例: 'manual-20240101T120000Z.tar.gz')。

.PARAMETER Force
    実行中のレプリカがある場合でも復元を続行します(非推奨。データ不整合のリスクがあります)。

.PARAMETER DryRun
    実際のコマンドを実行せず、内容のみ表示します。

.EXAMPLE
    ./scripts/restore-world.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -BackupFileName manual-20240101T120000Z.tar.gz
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

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) が見つかりません。'
    }

    $replicas = az containerapp replica list `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --output json | ConvertFrom-Json

    $runningReplica = $replicas | Where-Object { $_.properties.runningState -eq 'Running' } | Select-Object -First 1

    if ($runningReplica -and -not $Force) {
        throw "サーバーが実行中です。データ不整合を避けるため、先に stop-server.ps1 でサーバーを停止してから実行してください。強制的に続行する場合は -Force を指定してください(非推奨)。"
    }

    if ($runningReplica -and $Force) {
        Write-Warning 'サーバー実行中に -Force で復元を続行します。ワールドデータが破損する可能性があります。'
    }

    # レプリカが存在しない(minReplicas=0)場合、az containerapp exec は利用できないため、
    # 一時的にレプリカを1つ起動してから復元処理を行い、完了後に再度停止する運用を前提とする。
    if (-not $runningReplica) {
        throw '復元にはレプリカが起動している必要があります。先に start-server.ps1 を実行し、Minecraftプロセス自体は起動前提として復元コマンドを実行できる状態にしてから再実行してください(復元完了後は速やかにサーバーを再起動してください)。'
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
