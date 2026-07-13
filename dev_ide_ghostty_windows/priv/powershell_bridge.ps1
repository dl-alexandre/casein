$ErrorActionPreference = "Stop"
$port = [int]$args[0]
$client = [System.Net.Sockets.TcpClient]::new()
$client.Connect("127.0.0.1", $port)
$stream = $client.GetStream()
$reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
$writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

function Write-Prompt {
    $location = (Get-Location).Path
    $label = Split-Path -Leaf $location
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = $location
    }
    $writer.Write("PS $label> ")
}

Write-Prompt

while ($null -ne ($line = $reader.ReadLine())) {
    # Redirected stdin does not provide console echo, so mirror the completed
    # command after the prompt before evaluating it.
    $writer.WriteLine($line)

    try {
        $result = Invoke-Expression $line 2>&1 | Out-String
        $writer.Write($result)
    }
    catch {
        $writer.WriteLine($_.Exception.Message)
    }

    Write-Prompt
}

$reader.Dispose()
$writer.Dispose()
$stream.Dispose()
$client.Dispose()
