#Requires -Version 7.0
<#
.SYNOPSIS
    Minecraft Java Edition の Server List Ping (SLP) を実装した共通ヘルパーです。

.DESCRIPTION
    Container Apps の TCP Ingress は、バックエンドのコンテナーが異常な状態でも
    TCPハンドシェイクを成立させてしまいます。そのため「ポート25565へ接続できる」ことだけでは
    Minecraftサーバーの正常性を判断できません。
    このヘルパーは handshake -> status request を送信し、サーバー本体からのステータス応答
    (JSON) を受け取れるかどうかで正常性を判定します。

    運用スクリプトからドット ソースして利用します。

.EXAMPLE
    . "$PSScriptRoot/lib/minecraft-ping.ps1"
    $status = Get-MinecraftServerStatus -Hostname 'example.azurecontainerapps.io'
#>

function Add-McVarInt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[byte]]$Buffer,
        [Parameter(Mandatory = $true)][int]$Value
    )

    $current = [uint32]$Value
    do {
        $b = [byte]($current -band 0x7F)
        $current = $current -shr 7
        if ($current -ne 0) { $b = [byte]($b -bor 0x80) }
        $Buffer.Add($b)
    } while ($current -ne 0)
}

function Add-McString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[byte]]$Buffer,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($Value)
    Add-McVarInt -Buffer $Buffer -Value $utf8.Length
    $Buffer.AddRange($utf8)
}

function New-McPacket {
    param(
        [Parameter(Mandatory = $true)][int]$PacketId,
        [Parameter(Mandatory = $false)][byte[]]$Payload = @()
    )

    $body = [System.Collections.Generic.List[byte]]::new()
    Add-McVarInt -Buffer $body -Value $PacketId
    if ($Payload.Length -gt 0) { $body.AddRange($Payload) }

    $packet = [System.Collections.Generic.List[byte]]::new()
    Add-McVarInt -Buffer $packet -Value $body.Count
    $packet.AddRange($body)
    # カンマ演算子で配列のアンロールを防ぐ。
    return , $packet.ToArray()
}

function Read-McVarInt {
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $result = 0
    $shift = 0
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { throw 'ストリームが予期せず閉じられました。' }
        $result = $result -bor (($b -band 0x7F) -shl $shift)
        if (($b -band 0x80) -eq 0) { return $result }
        $shift += 7
        if ($shift -ge 35) { throw 'VarIntの形式が不正です。' }
    }
}

<#
.SYNOPSIS
    MinecraftサーバーへServer List Pingを送信し、ステータス応答(JSON)を返します。

.DESCRIPTION
    応答が得られない場合は $null を返します(例外は投げません)。
#>
function Get-MinecraftServerStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $false)][int]$Port = 25565,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 5000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        if (-not $client.ConnectAsync($Hostname, $Port).Wait($TimeoutMs)) { return $null }

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        $payload = [System.Collections.Generic.List[byte]]::new()
        # プロトコルバージョンは0(未指定)。ステータス取得のみのため任意の値でよい。
        Add-McVarInt -Buffer $payload -Value 0
        Add-McString -Buffer $payload -Value $Hostname
        $payload.Add([byte](($Port -shr 8) -band 0xFF))
        $payload.Add([byte]($Port -band 0xFF))
        # next state = 1 (status)
        Add-McVarInt -Buffer $payload -Value 1

        $handshake = New-McPacket -PacketId 0 -Payload $payload.ToArray()
        $stream.Write($handshake, 0, $handshake.Length)
        $statusRequest = New-McPacket -PacketId 0
        $stream.Write($statusRequest, 0, $statusRequest.Length)
        $stream.Flush()

        $null = Read-McVarInt -Stream $stream
        if ((Read-McVarInt -Stream $stream) -ne 0) { return $null }

        $jsonLength = Read-McVarInt -Stream $stream
        if ($jsonLength -le 0 -or $jsonLength -gt 262144) { return $null }

        $buffer = [byte[]]::new($jsonLength)
        $read = 0
        while ($read -lt $jsonLength) {
            $chunk = $stream.Read($buffer, $read, $jsonLength - $read)
            if ($chunk -le 0) { return $null }
            $read += $chunk
        }
        return [System.Text.Encoding]::UTF8.GetString($buffer) | ConvertFrom-Json
    }
    catch {
        return $null
    }
    finally {
        $client.Dispose()
    }
}

<#
.SYNOPSIS
    Server List Pingの応答内容を1行のサマリー文字列に整形します。
#>
function Format-MinecraftServerStatus {
    param([Parameter(Mandatory = $true)]$Status)

    $versionName = if ($Status.PSObject.Properties.Name -contains 'version') { $Status.version.name } else { '不明' }
    $players = if ($Status.PSObject.Properties.Name -contains 'players') {
        "$($Status.players.online) / $($Status.players.max)"
    }
    else {
        '不明'
    }
    return "version: $versionName, players: $players"
}
