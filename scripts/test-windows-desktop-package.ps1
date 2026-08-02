[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [switch]$KeepTestData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$metadataPath = Join-Path $packageRoot 'releases\casein.relmeta.json'
$installer = Join-Path $packageRoot 'windows\Install-Casein.ps1'
$uninstaller = Join-Path $packageRoot 'windows\Uninstall-Casein.ps1'
$trayHost = Join-Path $packageRoot 'windows\Casein.Tray.ps1'
$trustedLan = Join-Path $packageRoot 'windows\Casein.TrustedLan.ps1'
$backupLibrary = Join-Path $packageRoot 'windows\Casein.Backup.ps1'
$updateLibrary = Join-Path $packageRoot 'windows\Update-Casein.ps1'
$supportBundleScript = Join-Path $packageRoot 'windows\New-CaseinSupportBundle.ps1'

Assert-Condition (Test-Path -LiteralPath $metadataPath) "Release metadata is missing at $metadataPath"
Assert-Condition (Test-Path -LiteralPath $installer) "Installer is missing at $installer"
Assert-Condition (Test-Path -LiteralPath $uninstaller) "Uninstaller is missing at $uninstaller"
Assert-Condition (Test-Path -LiteralPath $trayHost) "Tray host is missing at $trayHost"
Assert-Condition (Test-Path -LiteralPath $trustedLan) "Trusted LAN helper is missing at $trustedLan"
Assert-Condition (Test-Path -LiteralPath $backupLibrary) "Backup helper is missing at $backupLibrary"
Assert-Condition (Test-Path -LiteralPath $updateLibrary) "Updater is missing at $updateLibrary"
Assert-Condition (Test-Path -LiteralPath $supportBundleScript) "Support bundle helper is missing at $supportBundleScript"
foreach ($name in @('Install-Casein.cmd', 'Repair-Casein.cmd', 'Uninstall-Casein.cmd')) {
    $commandPath = Join-Path $packageRoot $name
    Assert-Condition (Test-Path -LiteralPath $commandPath) "Offline lifecycle command is missing: $name"
    if ($name -ne 'Uninstall-Casein.cmd') {
        Assert-Condition ((Get-Content -Raw -LiteralPath $commandPath).Contains('-RequireSigned')) "$name does not require a signed release"
    }
}
Assert-Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'windows\Test-CaseinCleanMachine.ps1')) 'Clean-machine acceptance harness is missing'
Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'docs'))) 'Internal docs must not be included in a public desktop package'

$releaseScripts = Get-ChildItem -LiteralPath (Join-Path $packageRoot 'lib') -Directory |
    ForEach-Object { Join-Path $_.FullName 'priv\scripts' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'preview_playwright.mjs') } |
    Select-Object -First 1
Assert-Condition ([bool]$releaseScripts) 'Packaged Playwright helper is missing'
$previewNode = Join-Path $releaseScripts 'runtime\node.exe'
$playwrightPackage = Join-Path $releaseScripts 'node_modules\playwright\package.json'
$headless = Get-ChildItem -LiteralPath (Join-Path $releaseScripts 'playwright-browsers') -Directory |
    Where-Object Name -Like 'chromium_headless_shell-*' |
    Select-Object -First 1
Assert-Condition (Test-Path -LiteralPath $previewNode) 'Packaged preview node.exe is missing'
Assert-Condition (Test-Path -LiteralPath $playwrightPackage) 'Packaged Playwright dependency is missing'
Assert-Condition ([bool]$headless) 'Packaged Chromium headless shell is missing'

$smokeScript = Join-Path ([IO.Path]::GetTempPath()) ("casein-preview-bridge-smoke-" + [guid]::NewGuid().ToString('N') + '.cjs')
$originalPlaywrightBrowsersPath = $env:PLAYWRIGHT_BROWSERS_PATH
try {
    @'
const { spawn } = require('child_process');
const http = require('http');
const readline = require('readline');

const helper = process.argv[2];
const server = http.createServer((_request, response) => {
  response.writeHead(200, { 'content-type': 'text/html' });
  response.end(`<!doctype html><input id="name"><button id="apply" onclick="localStorage.setItem('applied', document.getElementById('name').value)">Apply</button><script>document.getElementById('name').addEventListener('keydown', event => { if (event.key === 'Enter') sessionStorage.setItem('pressed', event.target.value) })</script>`);
});

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const bridge = spawn(process.execPath, [helper, '--daemon'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: process.env,
  });
  const lines = readline.createInterface({ input: bridge.stdout });
  const pending = [];
  let stderr = '';
  bridge.stderr.on('data', chunk => { stderr += chunk; });
  lines.on('line', line => pending.shift()?.resolve(JSON.parse(line)));
  bridge.on('exit', code => {
    const error = new Error(`preview bridge exited ${code}: ${stderr}`);
    while (pending.length) pending.shift().reject(error);
  });

  const command = payload => new Promise((resolve, reject) => {
    pending.push({ resolve, reject });
    bridge.stdin.write(JSON.stringify(payload) + '\n');
  });
  const request = (action, params = {}) => command({
    action,
    url,
    browser_id: 'windows-package-smoke',
    params,
  });

  try {
    const diagnostic = await request('diagnose');
    assert(diagnostic.ok && diagnostic.diagnostic?.status === 'ready', 'diagnose did not report ready');
    assert((await request('observe_live')).ok, 'observe failed');
    assert((await request('type', { selector: '#name', text: 'Casein bridge' })).ok, 'type failed');
    assert((await request('click', { selector: '#apply' })).ok, 'click failed');
    const clickedStorage = await request('get_storage');
    assert(clickedStorage.ok && clickedStorage.local_storage?.applied === 'Casein bridge', 'click did not update browser storage');
    assert((await request('click', { selector: '#name' })).ok, 'input focus failed');
    assert((await request('press', { key: 'Enter' })).ok, 'press failed');
    const pressedStorage = await request('get_storage');
    assert(pressedStorage.ok && pressedStorage.session_storage?.pressed === 'Casein bridge', 'press did not update browser storage');
    const screenshot = await request('screenshot');
    assert(screenshot.ok && screenshot.artifact?.startsWith('data:image/png;base64,'), 'screenshot failed');
    assert((await request('reload')).ok, 'reload failed');
    assert((await request('close')).closed, 'close failed');
    bridge.stdin.end();
    await new Promise((resolve, reject) => bridge.once('exit', code => code === 0 ? resolve() : reject(new Error(`preview bridge exited ${code}: ${stderr}`))));
    process.stdout.write('preview-bridge-smoke-ok');
  } finally {
    if (!bridge.killed) bridge.kill();
    server.close();
  }
})().catch(error => { console.error(error); process.exit(1); });
'@ | Set-Content -LiteralPath $smokeScript -Encoding ascii
    $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $releaseScripts 'playwright-browsers'
    $playwrightHelper = Join-Path $releaseScripts 'preview_playwright.mjs'
    $smokeOutput = & $previewNode $smokeScript $playwrightHelper
    Assert-Condition ($LASTEXITCODE -eq 0) "Packaged preview bridge smoke failed: $smokeOutput"
    Assert-Condition (($smokeOutput -join '') -eq 'preview-bridge-smoke-ok') 'Packaged preview bridge smoke returned unexpected output'
} finally {
    $env:PLAYWRIGHT_BROWSERS_PATH = $originalPlaywrightBrowsersPath
    Remove-Item -LiteralPath $smokeScript -Force -ErrorAction SilentlyContinue
}

$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
Assert-Condition ($metadata.profile -eq 'desktop') 'Package profile must be desktop'
Assert-Condition ($metadata.repo_adapter -eq 'sqlite') 'Package repository adapter must be sqlite'
Assert-Condition ($metadata.target -eq 'windows-x86_64') 'Package target must be windows-x86_64'

$originalLocalAppData = $env:LOCALAPPDATA
$testLocalAppData = Join-Path ([IO.Path]::GetTempPath()) ("casein-package-smoke-" + [guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = $testLocalAppData
$startupLink = Join-Path $testLocalAppData 'Startup\Casein.lnk'

try {
    . $trayHost -ReleaseRoot $packageRoot -LibraryOnly
    . $trustedLan -ReleaseRoot $packageRoot -LibraryOnly
    . $backupLibrary -LibraryOnly
    . $updateLibrary -LibraryOnly
    Initialize-CaseinJobObjectSupport
    Assert-Condition (($null -ne ('Casein.Windows.JobObject' -as [type]))) 'Windows Job Object support did not load'

    New-Item -ItemType Directory -Force -Path $script:Paths.DataRoot | Out-Null
    Set-Content -LiteralPath $script:Paths.RuntimePid -Value '2147483647' -Encoding ascii
    Set-Content -LiteralPath $script:Paths.RuntimeStatus -Value '{"schema":1,"status":"ready"}' -Encoding ascii
    Clear-CaseinStaleRuntimeState 65534 | Out-Null
    Assert-Condition (-not (Test-Path -LiteralPath $script:Paths.RuntimePid)) 'Stale runtime PID was not cleared'
    Assert-Condition (-not (Test-Path -LiteralPath $script:Paths.RuntimeStatus)) 'Stale runtime status was not cleared'

    $desktopEnvironment = Get-CaseinEnvironment 54321
    Assert-Condition ($desktopEnvironment.CASEIN_RELEASE_ROOT -eq $packageRoot) 'Release root was not injected into the desktop runtime'
    Assert-Condition ($desktopEnvironment.CASEIN_PREVIEW_CONTROL_ADAPTER -eq 'playwright') 'Packaged desktop did not enable Playwright preview control'
    Assert-Condition ($desktopEnvironment.CASEIN_PREVIEW_PLAYWRIGHT_SCRIPT -eq 'scripts/preview_playwright.mjs') 'Packaged desktop did not select the release-local Playwright helper'
    Assert-Condition ($desktopEnvironment.CASEIN_WINDOWS_PREVIEW_CONTROL_ONLY -eq 'true') 'Packaged desktop did not enable tmux-free Preview MCP opening'
    Assert-Condition ($desktopEnvironment.CASEIN_ORIGIN_ID.StartsWith('windows-')) 'Windows origin id was not generated'
    Assert-Condition ($desktopEnvironment.CASEIN_ORIGIN_DISPLAY_NAME.EndsWith(' (Windows)')) 'Windows origin name is not platform-distinct'
    $firstOriginId = $desktopEnvironment.CASEIN_ORIGIN_ID
    $secondDesktopEnvironment = Get-CaseinEnvironment 54322
    Assert-Condition ($secondDesktopEnvironment.CASEIN_ORIGIN_ID -eq $firstOriginId) 'Windows origin id changed across host restarts'
    $vector = New-CaseinLaunchClaim -Secret 'fixed-desktop-launch-secret-0123456789' -Timestamp 1700000000 -Nonce 'AAECAwQFBgcICQoLDA0ODw'
    Assert-Condition ($vector -eq 'desktop_nonce=AAECAwQFBgcICQoLDA0ODw&desktop_timestamp=1700000000&desktop_proof=VqZtkYtl09-mO3ZBFxIqlavgcmz21EOxoMMqIwYpyg4') 'Windows HMAC claim differs from the shared vector'

    $legacySecretPath = Join-Path $testLocalAppData 'legacy-secret.txt'
    New-Item -ItemType Directory -Force -Path $testLocalAppData | Out-Null
    Set-Content -NoNewline -LiteralPath $legacySecretPath -Value 'legacy-secret-value'
    Assert-Condition ((Get-OrCreateCaseinSecret $legacySecretPath 32) -eq 'legacy-secret-value') 'Legacy secret migration changed the value'
    $protectedSecret = Get-Content -Raw -LiteralPath $legacySecretPath
    Assert-Condition ($protectedSecret.StartsWith('dpapi:')) 'Secret was not protected with DPAPI'
    Assert-Condition (-not $protectedSecret.Contains('legacy-secret-value')) 'Protected secret file contains plaintext'
    Assert-Condition ((Get-OrCreateCaseinSecret $legacySecretPath 32) -eq 'legacy-secret-value') 'DPAPI secret did not round trip'

    $rotationApiPath = Join-Path $testLocalAppData 'api-token.txt'
    $rotationLaunchPath = Join-Path $testLocalAppData 'desktop-launch-token.txt'
    $oldApiToken = Get-OrCreateCaseinSecret $rotationApiPath 48
    $oldLaunchToken = Get-OrCreateCaseinSecret $rotationLaunchPath 48
    Invoke-CaseinAccessTokenRotation -DataRoot $testLocalAppData -Validate { $true }
    $rotatedApiToken = Get-OrCreateCaseinSecret $rotationApiPath 48
    $rotatedLaunchToken = Get-OrCreateCaseinSecret $rotationLaunchPath 48
    Assert-Condition ($rotatedApiToken -ne $oldApiToken) 'API token did not rotate'
    Assert-Condition ($rotatedLaunchToken -ne $oldLaunchToken) 'Desktop launch token did not rotate'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $testLocalAppData 'credential-state.json')) 'Token rotation state is missing'
    $recovered = $false
    try {
        Invoke-CaseinAccessTokenRotation -DataRoot $testLocalAppData -Validate { $false } -Recover { $script:recovered = $true }
        throw 'Failed token rotation was accepted'
    } catch {
        Assert-Condition ($_.Exception.Message.Contains('did not become healthy')) 'Failed token rotation failed for the wrong reason'
    }
    Assert-Condition $recovered 'Failed token rotation did not invoke recovery'
    Assert-Condition ((Get-OrCreateCaseinSecret $rotationApiPath 48) -eq $rotatedApiToken) 'Failed rotation did not restore the API token'
    Assert-Condition ((Get-OrCreateCaseinSecret $rotationLaunchPath 48) -eq $rotatedLaunchToken) 'Failed rotation did not restore the desktop launch token'

    $credentialStatePath = Join-Path $testLocalAppData 'credential-state.json'
    $tamperedState = Get-Content -Raw -LiteralPath $credentialStatePath | ConvertFrom-Json
    $tamperedState | Add-Member -NotePropertyName injected_secret -NotePropertyValue 'must-not-ship'
    $tamperedState | ConvertTo-Json | Set-Content -LiteralPath $credentialStatePath -Encoding UTF8
    $crashStatePath = Join-Path $testLocalAppData 'crash-state.json'
    [ordered]@{
        schema = 1
        detected_at_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
        runtime_pid = 4242
        exit_code = 23
        recovery_attempts = 2
        recovery_status = 'recovered'
        recovered_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $crashStatePath -Encoding UTF8
    $tamperedCrashState = Get-Content -Raw -LiteralPath $crashStatePath | ConvertFrom-Json
    $tamperedCrashState | Add-Member -NotePropertyName injected_secret -NotePropertyValue 'must-not-ship'
    $tamperedCrashState | ConvertTo-Json | Set-Content -LiteralPath $crashStatePath -Encoding UTF8
    [ordered]@{ port = 4567; launchAtSignIn = $true; injected_secret = 'must-not-ship' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testLocalAppData 'desktop-host.json') -Encoding UTF8
    [ordered]@{
        schema = 1; status = 'ready'; port = 4567; base_url = 'http://127.0.0.1:4567'; pid = 4242
        version = '0.1.0'; revision = 'abcdef1234567890'; started_at = [DateTime]::UtcNow.ToString('o')
        injected_secret = 'must-not-ship'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testLocalAppData 'runtime.json') -Encoding UTF8
    [ordered]@{
        schema = 1; enabled = $true; address = '192.168.1.20'; interface_alias = 'Ethernet'
        interface_index = 3; port = 4567; program = 'C:\must-not-ship\erl.exe'
        url = 'http://must-not-ship'; enabled_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testLocalAppData 'trusted-lan.json') -Encoding UTF8
    $supportInstallRoot = Join-Path $testLocalAppData 'support-install'
    New-Item -ItemType Directory -Path $supportInstallRoot | Out-Null
    [ordered]@{
        schema = 1; version = '0.1.0'; revision = 'abcdef1234567890'
        release_root = 'C:\must-not-ship\release'; previous_release_root = 'C:\previous\release'
        previous_data_backup = 'C:\backup\snapshot.json'
        signer_thumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'
        installed_at_utc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $supportInstallRoot 'current.json') -Encoding UTF8
    $supportArchive = Join-Path $testLocalAppData 'support.zip'
    $supportExpanded = Join-Path $testLocalAppData 'support-expanded'
    & $supportBundleScript -DataRoot $testLocalAppData -InstallRoot $supportInstallRoot -Destination $supportArchive | Out-Null
    Expand-Archive -LiteralPath $supportArchive -DestinationPath $supportExpanded
    $bundledCredentialState = Get-Content -Raw -LiteralPath (Join-Path $supportExpanded 'credential-state.json')
    $bundledCrashState = Get-Content -Raw -LiteralPath (Join-Path $supportExpanded 'crash-state.json')
    Assert-Condition (-not $bundledCredentialState.Contains('must-not-ship')) 'Support bundle copied untrusted credential-state fields'
    Assert-Condition (-not $bundledCrashState.Contains('must-not-ship')) 'Support bundle copied untrusted crash-state fields'
    Assert-Condition ($bundledCrashState.Contains('recovered')) 'Support bundle omitted crash recovery outcome'
    foreach ($name in @('desktop-host.json', 'runtime.json', 'trusted-lan.json', 'current.json')) {
        $bundledState = Get-Content -Raw -LiteralPath (Join-Path $supportExpanded $name)
        Assert-Condition (-not $bundledState.Contains('must-not-ship')) "Support bundle copied untrusted fields from $name"
    }
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $supportExpanded 'api-token.txt'))) 'Support bundle copied the API token file'
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $supportExpanded 'desktop-launch-token.txt'))) 'Support bundle copied the desktop launch token file'

    $backupSource = Join-Path $testLocalAppData 'backup-source.sqlite3'
    $backupCiphertext = Join-Path $testLocalAppData 'backup.sqlite3.dpapi'
    $backupManifest = Join-Path $testLocalAppData 'backup.json'
    $backupRestored = Join-Path $testLocalAppData 'backup-restored.sqlite3'
    Set-Content -NoNewline -LiteralPath $backupSource -Value 'SQLite format 3 package-smoke'
    $backupMetadata = Protect-CaseinBackupFile -Source $backupSource -Destination $backupCiphertext
    $backupMetadata | ConvertTo-Json | Set-Content -LiteralPath $backupManifest -Encoding UTF8
    Assert-Condition (-not ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($backupCiphertext)).Contains('package-smoke'))) 'Encrypted backup leaked plaintext'
    Restore-CaseinBackupFile -Source $backupCiphertext -Manifest $backupManifest -Destination $backupRestored
    Assert-Condition ((Get-Content -Raw -LiteralPath $backupRestored) -eq 'SQLite format 3 package-smoke') 'Encrypted backup did not round trip'

    $updateManifest = Join-Path $testLocalAppData 'update-channel.json'
    [ordered]@{
        manifest_version = 1
        channel = 'stable'
        artifacts = @([ordered]@{
            app = 'casein'; profile = 'desktop'; target = 'windows-x86_64'; repo_adapter = 'sqlite'
            revision = ('a' * 40); url = 'https://updates.example.invalid/casein.zip'
            sha256 = ('b' * 64); size = 123
        })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $updateManifest -Encoding UTF8
    $updateCurrent = [pscustomobject]@{ app = 'casein'; profile = 'desktop'; target = 'windows-x86_64'; repo_adapter = 'sqlite'; channel = 'stable' }
    $updatePlan = Read-CaseinUpdatePlan -ManifestPath $updateManifest -Current $updateCurrent
    Assert-Condition ($updatePlan.Artifact.revision -eq ('a' * 40)) 'Signed channel plan selected the wrong artifact'
    $updateCurrent.channel = 'canary'
    try {
        Read-CaseinUpdatePlan -ManifestPath $updateManifest -Current $updateCurrent | Out-Null
        throw 'Channel mismatch was accepted'
    } catch {
        Assert-Condition ($_.Exception.Message.Contains('Refusing update channel change')) 'Channel mismatch failed for the wrong reason'
    }

    $selectedAddress = Select-CaseinLanAddress @(
        [pscustomobject]@{ Address = '192.168.50.7'; InterfaceAlias = 'vEthernet (WSL)'; InterfaceIndex = 2; InterfaceMetric = 1; HasDefaultGateway = $true; VirtualOrTunnel = $true },
        [pscustomobject]@{ Address = '10.0.0.20'; InterfaceAlias = 'Ethernet'; InterfaceIndex = 8; InterfaceMetric = 15; HasDefaultGateway = $false; VirtualOrTunnel = $false },
        [pscustomobject]@{ Address = '192.168.50.8'; InterfaceAlias = 'Wi-Fi'; InterfaceIndex = 7; InterfaceMetric = 25; HasDefaultGateway = $true; VirtualOrTunnel = $false }
    )
    Assert-Condition ($selectedAddress.Address -eq '192.168.50.8') 'Trusted LAN selection did not prefer the physical default route'

    $releaseTrustManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $packageRoot 'windows\Casein.Release.psd1')
    Assert-Condition ($releaseTrustManifest.Schema -eq 2) 'Release trust manifest schema was not upgraded'
    $filesManifestPath = Join-Path $packageRoot ([string]$releaseTrustManifest.FilesManifest)
    Assert-Condition (Test-Path -LiteralPath $filesManifestPath -PathType Leaf) 'Release file manifest is missing'
    $filesManifestBytes = [IO.File]::ReadAllBytes($filesManifestPath)
    try {
        Add-Content -LiteralPath $filesManifestPath -Value 'tampered'
        $tamperedOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot -AllowUnsignedDevelopment 2>&1
        Assert-Condition ($LASTEXITCODE -ne 0) 'Tampered release file manifest was accepted'
        Assert-Condition (($tamperedOutput -join "`n").Contains('Release file manifest integrity check failed')) 'Tampered release file manifest failed for the wrong reason'
    } finally {
        [IO.File]::WriteAllBytes($filesManifestPath, $filesManifestBytes)
    }

    $unsignedOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot 2>&1
    Assert-Condition ($LASTEXITCODE -ne 0) 'Unsigned package installation was accepted by default'
    Assert-Condition (($unsignedOutput -join "`n").Contains('trusted Authenticode release signature is required')) 'Unsigned package failed for the wrong reason'

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot -AllowUnsignedDevelopment
    if ($LASTEXITCODE -ne 0) { throw "Installer exited with $LASTEXITCODE" }

    $installRoot = Join-Path $testLocalAppData 'Programs\Casein'
    $currentPath = Join-Path $installRoot 'current.json'
    Assert-Condition (Test-Path -LiteralPath $currentPath) 'Installer did not write current.json'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $installRoot 'Casein.cmd')) 'Installer did not write the stable launcher'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $installRoot 'Update-Casein.ps1')) 'Installer did not write the signed-channel updater'
    Assert-Condition (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Casein') 'Installer did not register Apps & Features metadata'

    $current = Get-Content -Raw -LiteralPath $currentPath | ConvertFrom-Json
    Assert-Condition ($null -ne $current.PSObject.Properties['signer_thumbprint']) 'Installer did not persist the release signer field'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $current.release_root 'bin\casein.bat')) 'Installed release is missing casein.bat'
    Assert-Condition ($current.revision -eq $metadata.revision) 'Installed release revision differs from package metadata'

    . $trayHost -ReleaseRoot ([string]$current.release_root) -LibraryOnly

    $stateDataRoot = $script:Paths.DataRoot
    New-Item -ItemType Directory -Force -Path $stateDataRoot | Out-Null
    $settingsPath = Join-Path $stateDataRoot 'desktop-host.json'
    Set-Content -LiteralPath $settingsPath -Value '{malformed-settings' -Encoding UTF8
    $recoveredSettings = Read-CaseinSettings
    Assert-Condition ($recoveredSettings.port -eq 0) 'Malformed settings did not fall back to an automatically selected port'
    Assert-Condition (-not $recoveredSettings.launchAtSignIn) 'Malformed settings unexpectedly enabled launch at sign-in'

    $runtimePidPath = Join-Path $stateDataRoot 'runtime.pid'
    $runtimeStatusPath = Join-Path $stateDataRoot 'runtime.json'
    Set-Content -LiteralPath $runtimePidPath -Value 'not-a-process-id' -Encoding ascii
    Set-Content -LiteralPath $runtimeStatusPath -Value '{malformed-runtime-state' -Encoding UTF8
    $recoveryProbePort = Get-FreeLoopbackPort
    Assert-Condition (-not (Clear-CaseinStaleRuntimeState $recoveryProbePort)) 'Malformed runtime state unexpectedly reported a ready runtime'
    Assert-Condition (-not (Test-Path -LiteralPath $runtimePidPath)) 'Malformed runtime PID marker was not removed'
    Assert-Condition (-not (Test-Path -LiteralPath $runtimeStatusPath)) 'Malformed runtime status marker was not removed'

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $startupLink) | Out-Null
    $script:Paths.StartupLink = $startupLink
    Set-CaseinStartup $true
    Assert-Condition (Test-Path -LiteralPath $startupLink) 'Launch at sign-in did not create its shortcut'
    $startupShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startupLink)
    $stableLauncher = Join-Path $installRoot 'Casein.Launcher.ps1'
    Assert-Condition ($startupShortcut.Arguments.Contains($stableLauncher)) 'Launch at sign-in did not target the stable launcher'
    Assert-Condition (-not $startupShortcut.Arguments.Contains([string]$current.release_root)) 'Launch at sign-in pinned a release-specific path'
    Set-CaseinStartup $false
    Assert-Condition (-not (Test-Path -LiteralPath $startupLink)) 'Disabling launch at sign-in left its shortcut behind'

    $repairProbe = Join-Path $current.release_root 'windows\New-CaseinSupportBundle.ps1'
    Remove-Item -LiteralPath $repairProbe -Force
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot -AllowUnsignedDevelopment
    if ($LASTEXITCODE -ne 0) { throw "Repair reinstall exited with $LASTEXITCODE" }
    Assert-Condition (Test-Path -LiteralPath $repairProbe) 'Repair reinstall did not restore a damaged release file'

    $dataRoot = Join-Path $testLocalAppData 'Casein'
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $dataRoot 'casein.sqlite3') -Value 'desktop-package-smoke' -Encoding ascii
    foreach ($name in @('secret-key-base.txt', 'api-token.txt', 'desktop-launch-token.txt')) {
        Set-Content -LiteralPath (Join-Path $dataRoot $name) -Value 'dpapi:package-smoke-placeholder' -Encoding ascii
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -PackageRoot $packageRoot -AllowUnsignedDevelopment
    if ($LASTEXITCODE -ne 0) { throw "Upgrade installer exited with $LASTEXITCODE" }

    $backup = Get-ChildItem -LiteralPath (Join-Path $dataRoot 'backups') -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    Assert-Condition ($null -ne $backup) 'Upgrade did not create a data backup'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $backup.FullName 'casein.sqlite3.dpapi')) 'Upgrade backup was not DPAPI encrypted'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $backup.FullName 'casein.sqlite3.backup.json')) 'Upgrade backup metadata is missing'
    foreach ($name in @('secret-key-base.txt', 'api-token.txt', 'desktop-launch-token.txt')) {
        Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $backup.FullName $name))) "Upgrade backup copied credential $name"
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $uninstaller -RemoveUserData
    if ($LASTEXITCODE -ne 0) { throw "Uninstaller exited with $LASTEXITCODE" }
    Assert-Condition (-not (Test-Path -LiteralPath $installRoot)) 'Uninstaller left the installation root behind'
    Assert-Condition (-not (Test-Path -LiteralPath $dataRoot)) 'Uninstaller left user data behind after -RemoveUserData'
    Assert-Condition (-not (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Casein')) 'Uninstaller left Apps & Features metadata behind'
    Write-Host "Windows desktop package smoke passed: $packageRoot"
} finally {
    Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocalAppData
    if (-not $KeepTestData) { Remove-Item -LiteralPath $testLocalAppData -Recurse -Force -ErrorAction SilentlyContinue }
}
