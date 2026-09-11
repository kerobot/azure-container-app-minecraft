#Requires -Version 7.0
<#
.SYNOPSIS
    Minecraftワールドデータのバックアップを作成します。

.DESCRIPTION
    実行中のコンテナー内で /data配下のワールド・設定・ホワイトリスト・operator情報を
    /data/backups 配下へtar.gzとして世代管理付きで保存します。ワールドの保存(flush)は
    行いません。事前に flush が必要な場合は呼び出し側で stop-server.ps1 等を使ってください
    (az containerapp exec のレート制限を避けるため、このスクリプトではflushを実行しません)。
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

. "$PSScriptRoot/lib/containerapp.ps1"

try {
    Assert-AzureCli

    $app = Get-ContainerAppInfo -ResourceGroupName $ResourceGroupName -AppName $AppName
    Write-RevisionMismatchWarning -AppInfo $app

    $runningReplica = Get-RunningReplica -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $app.ActiveRevision

    if (-not $runningReplica) {
        throw 'バックアップ対象のレプリカが実行されていません。サーバーを起動してから再実行してください。'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $backupName = "$Label-$timestamp"
    # az containerapp exec は Windows上のPowerShellから `&&` やパイプを含む文字列を渡すと
    # cmd.exe側で誤解釈され、コンテナー側に壊れたコマンドが届くことがある
    # (docs/incident-records.md のINC-005を参照)。そのため単純なコマンド1つずつをexecで実行する。
    $mkdirCommand = 'mkdir -p /data/backups'
    $tarCommand = "tar -czf /data/backups/$backupName.tar.gz -C /data world world_nether world_the_end whitelist.json ops.json server.properties"

    if ($DryRun -or -not $PSCmdlet.ShouldProcess($AppName, "バックアップ作成 ($backupName)")) {
        Write-Host '(DryRun) 以下のコマンドを順に実行予定です:' -ForegroundColor Yellow
        Write-Host "  1. $mkdirCommand"
        Write-Host "  2. $tarCommand"
        if ($RetentionCount -gt 0) {
            Write-Host "  3. 世代整理 (最新 $RetentionCount 件を保持し、それより古いものを削除)"
        }
        exit 0
    }

    Write-Host "バックアップを作成しています: $backupName.tar.gz" -ForegroundColor Cyan
    Invoke-ContainerAppExecCommand -ResourceGroupName $ResourceGroupName -AppName $AppName -ReplicaName $runningReplica.name -Command $mkdirCommand | Out-Null
    Invoke-ContainerAppExecCommand -ResourceGroupName $ResourceGroupName -AppName $AppName -ReplicaName $runningReplica.name -Command $tarCommand | Out-Null

    if ($RetentionCount -gt 0) {
        Write-Host "世代整理を行っています (保持数: $RetentionCount)..." -ForegroundColor Cyan
        # 一覧取得と世代数の判定はPowerShell側で行い、削除だけをexec経由の単純なコマンドで実行する。
        try {
            $listResult = Invoke-ContainerAppExecCommand -ResourceGroupName $ResourceGroupName -AppName $AppName -ReplicaName $runningReplica.name -Command 'ls -1t /data/backups'
            $backupFiles = @($listResult -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.tar\.gz$' })
            $filesToDelete = $backupFiles | Select-Object -Skip $RetentionCount
            foreach ($file in $filesToDelete) {
                Invoke-ContainerAppExecCommand -ResourceGroupName $ResourceGroupName -AppName $AppName -ReplicaName $runningReplica.name -Command "rm -f /data/backups/$file" | Out-Null
            }
        }
        catch {
            Write-Warning "世代整理に失敗したためスキップしました: $($_.Exception.Message)"
        }
    }

    Write-Host "バックアップが完了しました: /data/backups/$backupName.tar.gz" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
