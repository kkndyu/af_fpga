# -----------------------------------------------------------------------------
# udp_host.ps1  -  drive the loader over UDP
# -----------------------------------------------------------------------------
# Frame format (from moe_loader.v):
#   0      0xA5                magic
#   1      cmd
#   2      len[15:8]
#   3      len[7:0]
#   4..    payload
#   4+len  crc8 over bytes 1 .. 4+len-1   (poly 0x07, init 0, no reflection)
#
#   0x01 WRITE_W  [target][addr_hi][addr_lo] + 32*N data bytes
#   0x02 WRITE_A  [addr_hi][addr_lo] + 2*N data bytes
#   0x03 RUN      empty, refused unless weights_ready
#   0x04 STATUS   empty, replies 8 bytes
#   0x05 READOUT
#   0x06 READ_W
# -----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$BOARD_IP = '192.168.8.6'
$PORT     = 1234

function New-Crc8Table {
    $t = New-Object byte[] 256
    for ($i = 0; $i -lt 256; $i++) {
        [int]$c = $i
        for ($b = 0; $b -lt 8; $b++) {
            if ($c -band 0x80) { $c = (($c -shl 1) -band 0xFF) -bxor 0x07 }
            else               { $c = ($c -shl 1) -band 0xFF }
        }
        $t[$i] = [byte]$c
    }
    return $t
}
$CRC8 = New-Crc8Table

function Get-Crc8 {
    param([byte[]]$Data)
    [int]$c = 0
    foreach ($d in $Data) { $c = $CRC8[($c -bxor $d) -band 0xFF] }
    return [byte]$c
}

function New-Frame {
    param([byte]$Cmd, [byte[]]$Payload = @())
    $len = $Payload.Length
    $body = [byte[]]::new(3 + $len)
    $body[0] = $Cmd
    $body[1] = [byte](($len -shr 8) -band 0xFF)
    $body[2] = [byte]($len -band 0xFF)
    if ($len -gt 0) { [Array]::Copy($Payload, 0, $body, 3, $len) }
    $crc = Get-Crc8 $body
    $frame = [byte[]]::new(1 + $body.Length + 1)
    $frame[0] = 0xA5
    [Array]::Copy($body, 0, $frame, 1, $body.Length)
    $frame[$frame.Length - 1] = $crc
    return $frame
}

function New-Udp {
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $PORT)
    $u = New-Object System.Net.Sockets.UdpClient($ep)
    $u.Client.ReceiveTimeout = 3000
    return $u
}

function Send-Cmd {
    param($Udp, [byte]$Cmd, [byte[]]$Payload = @())
    $f = New-Frame -Cmd $Cmd -Payload $Payload
    [void]$Udp.Send($f, $f.Length, $BOARD_IP, $PORT)
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    try {
        $r = $Udp.Receive([ref]$ep)
        return $r
    } catch {
        return $null
    }
}

function Show-Status {
    param([byte[]]$R)
    if ($null -eq $R) { "  STATUS: no reply"; return }
    $names = @('E_OK','E_CRC','E_NOTLOADED','E_BADCMD','E_BADARG','E_NODATA')
    $ec = $R[2]
    $nm = if ($ec -lt $names.Count) { $names[$ec] } else { 'E_?' }
    "  STATUS: weights_ready=$($R[0]) act_valid=$($R[1]) err_code=$ec ($nm) any_error=$($R[3])"
}

function Show-Bytes {
    param([byte[]]$R)
    if ($null -eq $R) { return '  (no reply)' }
    return '  ' + (($R | ForEach-Object { $_.ToString('X2') }) -join ' ')
}
