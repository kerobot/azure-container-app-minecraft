#Requires -Version 7.0
<#
.SYNOPSIS
    Minecraftワールドデータのバックアップを作成します。

.DESCRIPTION
    実行中のコンテナー内で save-all flush を行った後、/data配下のワールド・設定・
    ホワイトリスト・operator情報を /data/backups 配下へtar.gzとして世代管理付きで保存します。
    -DryRun を指定すると実際のコマンドは実行せず、実行予定の内容のみ表示します。

.PARAMETER ResourceGroupName
    Container Appが存在するリソースグループ名。

.PARAMETER AppName
    Container App名。

.PARAMETER Label
    バックアップ名に付与するラベル (例: 'manual', 'pre-update-26.2')。既定値は 'manual'。

.PARAMETER RetentionCount
    保持する世代数。これを超える古いバックアップは削除されます。0以下を指定すると世代整理を行いません。

.PARAMETER DryRun
    実際のコマンドを実行せず、内容のみ表示します。

.EXAMPLE
    ./scripts/backup-world.ps1 -ResourceGroupName rg-minecraft-dev -AppName mcaca-dev-minecraft -Label manual
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Label = 'manual',

    [Parameter(Mandatory = $false)]
    [int]$RetentionCount = 10,

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

    if (-not $runningReplica) {
        throw 'バックアップ対象のレプリカが実行されていません。サーバーを起動してから再実行してください。'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupName = "$Label-$timestamp"
    $tarCommand = "sh -c 'mkdir -p /data/backups && tar -czf /data/backups/$backupName.tar.gz -C /data world world_nether world_the_end whitelist.json ops.json server.properties'"
    $saveCommand = 'rcon-cli save-all flush'

    if ($DryRun -or -not $PSCmdlet.ShouldProcess($AppName, "バックアップ作成 ($backupName)")) {
        Write-Host '(DryRun) 以下のコマンドを実行予定です:' -ForegroundColor Yellow
        Write-Host "  1. $saveCommand"
        Write-Host "  2. $tarCommand"
        if ($RetentionCount -gt 0) {
            Write-Host "  3. 世代整理 (最新 $RetentionCount 件を保持し、それより古いものを削除)"
        }
        exit 0
    }

    Write-Host 'ワールドデータをフラッシュ保存しています...' -ForegroundColor Cyan
    az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $runningReplica.name --command $saveCommand
    Start-Sleep -Seconds 10

    Write-Host "バックアップを作成しています: $backupName.tar.gz" -ForegroundColor Cyan
    az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $runningReplica.name --command $tarCommand
    if ($LASTEXITCODE -ne 0) {
        throw "バックアップの作成に失敗しました (終了コード: $LASTEXITCODE)"
    }

    if ($RetentionCount -gt 0) {
        Write-Host "世代整理を行っています (保持数: $RetentionCount)..." -ForegroundColor Cyan
        $pruneCommand = "sh -c 'cd /data/backups && ls -1t *.tar.gz 2>/dev/null | tail -n +$($RetentionCount + 1) | xargs -r rm -f'"
        az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $runningReplica.name --command $pruneCommand | Out-Null
    }

    Write-Host "バックアップが完了しました: /data/backups/$backupName.tar.gz" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
