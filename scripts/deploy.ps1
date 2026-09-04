#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Container Apps Minecraftサーバー環境をデプロイします。

.DESCRIPTION
    infra/main.bicep を指定した環境パラメーター(dev/prod)でデプロイします。
    -WhatIf を指定すると実際の変更は行わず、What-If結果のみを表示します。

.PARAMETER Environment
    デプロイ対象の環境。'dev' または 'prod'。

.PARAMETER ResourceGroupName
    デプロイ先のリソースグループ名。

.PARAMETER Location
    リソースグループが存在しない場合に作成するリージョン。

.PARAMETER RconPassword
    RCON接続用パスワード (SecureString)。省略時は環境変数 MINECRAFT_RCON_PASSWORD を利用。

.PARAMETER WhatIf
    実際のデプロイを行わず、変更内容のプレビューのみを表示します。

.EXAMPLE
    ./scripts/deploy.ps1 -Environment dev -ResourceGroupName rg-minecraft-dev -WhatIf

.EXAMPLE
    ./scripts/deploy.ps1 -Environment prod -ResourceGroupName rg-minecraft-prod
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = 'japaneast',

    [Parameter(Mandatory = $false)]
    [SecureString]$RconPassword,

    [Parameter(Mandatory = $false)]
    [string]$WhitelistUsers,

    [Parameter(Mandatory = $false)]
    [string]$OpUsers
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PlainTextFromSecureString {
    param([SecureString]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

try {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $templateFile = Join-Path $repoRoot 'infra/main.bicep'
    $paramFile = Join-Path $repoRoot "infra/environments/$Environment.bicepparam"

    if (-not (Test-Path $templateFile)) {
        throw "テンプレートファイルが見つかりません: $templateFile"
    }
    if (-not (Test-Path $paramFile)) {
        throw "パラメーターファイルが見つかりません: $paramFile"
    }

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCommand) {
        throw 'Azure CLI (az) が見つかりません。インストールしてから再実行してください。'
    }

    Write-Host "リソースグループの存在確認: $ResourceGroupName" -ForegroundColor Cyan
    $rgExists = az group exists --name $ResourceGroupName | ConvertFrom-Json
    if (-not $rgExists) {
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'リソースグループを作成')) {
            az group create --name $ResourceGroupName --location $Location | Out-Null
        }
    }

    $plainRcon = Get-PlainTextFromSecureString -Secure $RconPassword
    if (-not $plainRcon) {
        $plainRcon = $env:MINECRAFT_RCON_PASSWORD
    }
    if (-not $plainRcon) {
        throw 'RCONパスワードが指定されていません。-RconPassword または環境変数 MINECRAFT_RCON_PASSWORD を設定してください。'
    }

    $whitelist = if ($WhitelistUsers) { $WhitelistUsers } else { $env:MINECRAFT_WHITELIST_USERS }
    $ops = if ($OpUsers) { $OpUsers } else { $env:MINECRAFT_OP_USERS }

    $overrideParams = @(
        "rconPassword=$plainRcon"
    )
    if ($whitelist) { $overrideParams += "whitelistUsers=$whitelist" }
    if ($ops) { $overrideParams += "opUsers=$ops" }

    if ($WhatIfPreference -or -not $PSCmdlet.ShouldProcess($ResourceGroupName, 'Bicepデプロイを実行')) {
        Write-Host 'What-If モードで実行します。実際のリソース変更は行われません。' -ForegroundColor Yellow
        az deployment group what-if `
            --resource-group $ResourceGroupName `
            --template-file $templateFile `
            --parameters $paramFile `
            --parameters $overrideParams
        if ($LASTEXITCODE -ne 0) {
            throw "What-Ifの実行に失敗しました (終了コード: $LASTEXITCODE)"
        }
        exit 0
    }

    Write-Host "デプロイを開始します: $Environment ($ResourceGroupName)" -ForegroundColor Cyan
    az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file $templateFile `
        --parameters $paramFile `
        --parameters $overrideParams

    if ($LASTEXITCODE -ne 0) {
        throw "デプロイに失敗しました (終了コード: $LASTEXITCODE)"
    }

    Write-Host 'デプロイが完了しました。' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "エラーが発生しました: $($_.Exception.Message)"
    exit 1
}
