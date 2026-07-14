$ErrorActionPreference = 'Stop'

$dataPort = [int]$args[0]
$controlPort = [int]$args[1]
$cols = [int16]$args[2]
$rows = [int16]$args[3]
$workingDirectory = $args[4]
$bridgeSource = Join-Path $PSScriptRoot 'conpty_bridge.cs'

Add-Type -Path $bridgeSource

$commandParts = @($args | Select-Object -Skip 5)
$commandLine = ($commandParts | ForEach-Object {
    '"{0}"' -f $_.Replace('"', '\"')
}) -join ' '

$exitCode = [DevIDE.ConPtyBridge]::Run(
    $dataPort,
    $controlPort,
    $commandLine,
    $workingDirectory,
    $cols,
    $rows
)

exit $exitCode
