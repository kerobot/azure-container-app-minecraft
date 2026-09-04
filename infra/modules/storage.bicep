// storage.bicep
// ワールドデータ・設定・ホワイトリスト・operator情報を永続化するためのAzure Files共有を作成します。
// リソースの再デプロイ (increment mode) ではストレージアカウント・ファイル共有は削除されず、
// 既存データはそのまま維持されます。誤操作による削除を防ぐため、CanNotDeleteロックを付与します。
//
// プロトコルはSMBではなくNFS 4.1を使用します。Minecraftサーバーはワールドディレクトリの
// session.lock をO_SYNCで書き込むため、SMB(cifs)マウントでは mountOptions を調整しても
// java.io.IOException: Permission denied となり起動できません。NFSはPOSIXセマンティクスを
// 満たすためこの制約がなく、その代わりPremium FileStorage (最小100GiB) が必須となります。

@description('リソースの共通名プレフィックス (英数字とハイフンのみ、storage account名の生成に利用)')
param namePrefix string

@description('リソースを配置するAzureリージョン')
param location string

@description('Minecraftデータ用ファイル共有名')
param fileShareName string = 'minecraft-data'

@description('ファイル共有の割り当て容量(GiB)。Premium FileStorageのNFS共有は最小100GiB')
@minValue(100)
@maxValue(102400)
param fileShareQuotaGiB int = 100

@description('Storage Accountへのアクセスを許可するサブネットのリソースID')
param allowedSubnetId string

@description('ストレージアカウントの再デプロイ時に誤って削除されないようリソースロックを付与するか')
param enableDeleteLock bool = true

@description('共通タグ')
param tags object = {}

var normalizedNamePrefix = toLower(replace(namePrefix, '-', ''))
var storageNamePrefix = length(normalizedNamePrefix) > 9 ? substring(normalizedNamePrefix, 0, 9) : normalizedNamePrefix
var storageAccountName = '${storageNamePrefix}${uniqueString(resourceGroup().id, namePrefix)}st'

resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    // NFS 4.1共有はPremium FileStorageアカウントでのみ利用できる。
    name: 'Premium_LRS'
  }
  kind: 'FileStorage'
  properties: {
    // 公開アクセスを制限し、指定サブネットからのアクセスのみを許可する。
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // NFSはアカウントキーを使わずVNet境界で認可するため、共有キーアクセスは無効化する。
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: allowedSubnetId
          action: 'Allow'
        }
      ]
    }
    // Container AppsはNFSの転送時暗号化に非対応のため、'Secure transfer required' を無効にする。
    // 有効なままだと mount.nfs: access denied by server while mounting となる。
    supportsHttpsTrafficOnly: false
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2026-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    protocolSettings: {
      nfs: {
        encryptionInTransit: {
          required: false
        }
      }
    }
  }
}

resource minecraftShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2026-04-01' = {
  parent: fileServices
  name: fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'NFS'
    // コンテナーはroot起動後にuid=1000へ降格するため、rootのsquashを行わない。
    rootSquash: 'NoRootSquash'
  }
}

resource deleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: storageAccount
  name: '${storageAccountName}-delete-lock'
  properties: {
    level: 'CanNotDelete'
    notes: 'Minecraftワールドデータ保護のための削除防止ロック。解除するには明示的にロックを削除すること。'
  }
}

@description('ストレージアカウント名')
output storageAccountName string = storageAccount.name

@description('ファイル共有名')
output fileShareName string = minecraftShare.name

@description('NFSマウント先のサーバーアドレス')
output nfsServer string = '${storageAccount.name}.file.${environment().suffixes.storage}'

@description('NFSマウント時に指定する共有パス (/<account>/<share> 形式)')
output nfsShareName string = '/${storageAccount.name}/${minecraftShare.name}'

@description('ストレージアカウントのリソースID')
output storageAccountId string = storageAccount.id
