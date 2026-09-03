using '../main.bicep'

// 開発環境向けパラメーター。
// Minecraftバージョンは開発中は最新を追従してよいため LATEST を既定とする。

param environmentName = 'dev'
param location = 'japaneast'
param namePrefix = 'mcaca-dev'

param vnetAddressPrefix = '10.100.0.0/16'
param infraSubnetAddressPrefix = '10.100.0.0/23'

param logRetentionInDays = 30
param fileShareQuotaGiB = 32

// 開発環境ではデータ保護の柔軟性を優先し、削除ロックは付与しない。
param enableStorageDeleteLock = false

param containerImage = 'itzg/minecraft-server:latest'
// 開発環境は最新バージョンを追従する。
param minecraftVersion = 'LATEST'

// ホワイトリストユーザーはCI/CD変数または実行時に上書きすること。
param whitelistUsers = readEnvironmentVariable('MINECRAFT_WHITELIST_USERS', 'dev-user1,dev-user2')
param opUsers = readEnvironmentVariable('MINECRAFT_OP_USERS', 'dev-user1')

param onlineMode = true
param enableWhitelist = true

param cpuCores = '1.0'
param memorySize = '2Gi'
param javaMaxMemory = '1536M'
param javaInitMemory = '1024M'

param minReplicas = 0
param maxReplicas = 1
param tcpConcurrentConnections = 1

// RCONパスワードはGitHub Actionsのシークレットから環境変数経由で注入する。
param rconPassword = readEnvironmentVariable('MINECRAFT_RCON_PASSWORD', '')
