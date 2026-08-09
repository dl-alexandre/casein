[CmdletBinding()]
param(
    [string]$Subject = 'CN=Casein Development Update Channel'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$certificate = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Subject `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -KeyUsage DigitalSignature `
    -NotAfter ([DateTime]::UtcNow.AddYears(5)) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')

Write-Host 'Created a non-exportable Casein development-channel signing key.'
Write-Host "Subject: $($certificate.Subject)"
Write-Host "Thumbprint: $($certificate.Thumbprint)"
Write-Host 'Store this thumbprint in the protected release-runner configuration; never commit private key material.'
