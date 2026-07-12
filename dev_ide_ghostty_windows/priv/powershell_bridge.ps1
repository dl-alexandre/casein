$ErrorActionPreference = "Stop"
$port = [int]$args[0]
$client = [System.Net.Sockets.TcpClient]::new()
$client.Connect("127.0.0.1", $port)
$stream = $client.GetStream()
$reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
$writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

while ($null -ne ($line = $reader.ReadLine())) {
    try {
        $result = Invoke-Expression $line 2>&1 | Out-String
        $writer.Write($result)
    }
    catch {
        $writer.WriteLine($_.Exception.Message)
    }
}

$reader.Dispose()
$writer.Dispose()
$stream.Dispose()
$client.Dispose()
