[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$SigningCertificateThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Development manifest is missing.' }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.manifest_version -ne 1 -or $manifest.channel -ne 'development') {
    throw 'Only a version 1 development-channel manifest can be signed by this helper.'
}

$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) { throw 'The development-channel signing certificate has no private key.' }
$bytes = [IO.File]::ReadAllBytes($manifestPath)
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
try {
    $signature = $rsa.SignData(
        $bytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
} finally {
    $rsa.Dispose()
}
$signaturePath = "$manifestPath.sig"
[IO.File]::WriteAllText($signaturePath, [Convert]::ToBase64String($signature), [Text.Encoding]::ASCII)
Write-Host "Signed development manifest: $signaturePath"
