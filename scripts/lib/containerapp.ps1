#Requires -Version 7.0
<#
.SYNOPSIS
    Container App のリビジョン/レプリカを扱う共通ヘルパーです。

.DESCRIPTION
    `az containerapp replica list` は --revision を省略すると最新リビジョンを参照します。
    Single revision mode でも新リビジョンの起動に失敗している間は
    latestRevisionName != latestReadyRevisionName となり、実際に稼働しているレプリカを
    見失います。運用スクリプトはこのヘルパー経由で「稼働中リビジョン」を明示的に解決します。

    運用スクリプトからドット ソースして利用します。
#>

<#
.SYNOPSIS
    Container Appのレプリカ上でコマンドをexec実行し、結果のテキストを返します。
#>
function Invoke-ContainerAppExecCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$ReplicaName,
        [Parameter(Mandatory = $true)][string]$Command
    )

    $output = az containerapp exec --name $AppName --resource-group $ResourceGroupName --replica $ReplicaName --command $Command 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | Out-String)

    if ($exitCode -ne 0) {
        if ($outputText -match '429|Too Many Requests') {
            throw "az containerapp exec がレート制限(429 Too Many Requests)で失敗しました。" +
                "『しばらく待ってから再実行してください』と表示されますが、実際には数分〜1時間以上" +
                "かかることがあります。短時間にexecを連続実行しすぎないようにしてください。"
        }
        throw "az containerapp exec の実行に失敗しました (終了コード: $exitCode)`n$outputText"
    }

    return $outputText
}

<#
<#
.SYNOPSIS
    Assert-AzureCli
#>
function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) が見つかりません。'
    }
}

<#
.SYNOPSIS
    Container App の情報を取得し、運用スクリプトで使う要素へ整形して返します。
#>
function Get-ContainerAppInfo {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AppName
    )

    $json = az containerapp show --name $AppName --resource-group $ResourceGroupName --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Container Appが見つかりません: $AppName ($ResourceGroupName)"
    }

    $app = $json | ConvertFrom-Json
    $latest = $app.properties.latestRevisionName
    $latestReady = $app.properties.latestReadyRevisionName
    # 実際にレプリカが動くのは Ready 済みリビジョン。未確定なら latest にフォールバックする。
    $active = if ([string]::IsNullOrWhiteSpace($latestReady)) { $latest } else { $latestReady }

    return [PSCustomObject]@{
        Name                = $app.name
        Fqdn                = $app.properties.configuration.ingress.fqdn
        Port                = $app.properties.configuration.ingress.exposedPort
        MinReplicas         = $app.properties.template.scale.minReplicas
        MaxReplicas         = $app.properties.template.scale.maxReplicas
        LatestRevision      = $latest
        LatestReadyRevision = $latestReady
        ActiveRevision      = $active
        ProvisioningState   = $app.properties.provisioningState
    }
}

<#
.SYNOPSIS
    指定リビジョンのレプリカ一覧を取得します。
#>
function Get-ContainerAppReplicas {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RevisionName
    )

    if ([string]::IsNullOrWhiteSpace($RevisionName)) { return @() }

    $json = az containerapp replica list `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --revision $RevisionName `
        --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return @() }

    return @($json | ConvertFrom-Json)
}

<#
.SYNOPSIS
    稼働中リビジョンで Running 状態のレプリカを1件返します。無ければ $null。
#>
function Get-RunningReplica {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RevisionName
    )

    $replicas = Get-ContainerAppReplicas -ResourceGroupName $ResourceGroupName -AppName $AppName -RevisionName $RevisionName
    return $replicas | Where-Object { $_.properties.runningState -eq 'Running' } | Select-Object -First 1
}

<#
.SYNOPSIS
    レプリカ一覧からクラッシュしているコンテナーを1件返します。無ければ $null。
#>
function Get-CrashedContainer {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Replicas)

    return $Replicas |
        ForEach-Object { $_.properties.containers } |
        Where-Object { $_.runningStateDetails -like '*CrashLoopBackOff*' } |
        Select-Object -First 1
}

<#
.SYNOPSIS
    指定リビジョンがアクティブ(トラフィックを受け付ける状態)かどうかを返します。
#>
function Test-RevisionActive {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RevisionName
    )

    if ([string]::IsNullOrWhiteSpace($RevisionName)) { return $false }

    $json = az containerapp revision show `
        --name $AppName `
        --resource-group $ResourceGroupName `
        --revision $RevisionName `
        --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $false }

    return [bool]($json | ConvertFrom-Json).properties.active
}

<#
.SYNOPSIS
    新リビジョンが起動できずに旧リビジョンが残っている状態を検出し、警告を表示します。
#>
function Write-RevisionMismatchWarning {
    param([Parameter(Mandatory = $true)]$AppInfo)

    if ([string]::IsNullOrWhiteSpace($AppInfo.LatestReadyRevision)) { return }
    if ($AppInfo.LatestRevision -eq $AppInfo.LatestReadyRevision) { return }

    Write-Warning @"
最新リビジョンが起動できていません。旧リビジョンが稼働を続けています。
  最新   : $($AppInfo.LatestRevision)
  稼働中 : $($AppInfo.LatestReadyRevision)
Minecraftはワールドを session.lock で排他ロックするため、新旧リビジョンが同時に起動すると
新しい方が 'already locked' で失敗します。docs/troubleshooting.md を参照してください。
"@
}
