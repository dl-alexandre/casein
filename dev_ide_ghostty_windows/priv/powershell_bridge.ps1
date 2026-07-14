$ErrorActionPreference = 'Stop'

$dataPort = [int]$args[0]
$controlPort = [int]$args[1]
$bridgeToken = $args[2]
$cols = [int16]$args[3]
$rows = [int16]$args[4]
$workingDirectory = $args[5]
$bridgeSource = Join-Path $PSScriptRoot 'conpty_bridge.cs'

Add-Type -Path $bridgeSource

$commandParts = @($args | Select-Object -Skip 6)
$commandLine = ($commandParts | ForEach-Object {
    '"{0}"' -f $_.Replace('"', '\"')
}) -join ' '

$exitCode = [DevIDE.ConPtyBridge]::Run(
    $dataPort,
    $controlPort,
    $bridgeToken,
    $commandLine,
    $workingDirectory,
    $cols,
    $rows
)

exit $exitCode
