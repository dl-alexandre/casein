[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SigningCertificateThumbprint,
    [string]$ManifestUrl = 'https://casein.devbox.milcgroup.com/downloads/windows/development/casein-development.json',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\dist\Casein-Setup.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path $root 'windows\bootstrap\Casein.DevelopmentBootstrap.cs'
$outputPath = [IO.Path]::GetFullPath($OutputPath)
$uri = [Uri]$ManifestUrl
if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'The development manifest URL must be credential-free HTTPS without a query string or fragment.'
}

$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) { throw 'The development-channel signing certificate has no private key.' }
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
try {
    $parameters = $rsa.ExportParameters($false)
} finally {
    $rsa.Dispose()
}

$source = Get-Content -Raw -LiteralPath $sourcePath
$source = $source.Replace('__CASEIN_MANIFEST_URL__', $ManifestUrl.Replace('"', '\"'))
$source = $source.Replace('__CASEIN_RSA_MODULUS__', [Convert]::ToBase64String($parameters.Modulus))
$source = $source.Replace('__CASEIN_RSA_EXPONENT__', [Convert]::ToBase64String($parameters.Exponent))
$stage = Join-Path $env:TEMP "Casein-bootstrap-$PID.cs"
try {
    Set-Content -LiteralPath $stage -Value $source -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw 'The .NET Framework C# compiler is unavailable.' }
    & $csc /nologo /target:exe /optimize+ /platform:x64 `
        "/out:$outputPath" `
        /reference:System.IO.Compression.dll `
        /reference:System.IO.Compression.FileSystem.dll `
        /reference:System.Web.Extensions.dll `
        $stage
    if ($LASTEXITCODE -ne 0) { throw "C# bootstrap compilation failed with exit code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
}

Write-Host "Built Casein development bootstrap: $outputPath"
Write-Host "Pinned manifest: $ManifestUrl"
Write-Host "Pinned key: $($certificate.Thumbprint)"
