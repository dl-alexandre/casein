defmodule Casein.Desktop.WindowsTrayHostTest do
  use ExUnit.Case, async: true

  @tray_script Path.expand("../../../windows/Casein.Tray.ps1", __DIR__)
  @package_script Path.expand("../../../scripts/package-windows-desktop.ps1", __DIR__)
  @package_smoke Path.expand("../../../scripts/test-windows-desktop-package.ps1", __DIR__)
  @preview_prepare Path.expand(
                     "../../../scripts/prepare-windows-preview-runtime.ps1",
                     __DIR__
                   )
  @installer Path.expand("../../../windows/Install-Casein.ps1", __DIR__)
  @launcher Path.expand("../../../windows/Casein.Launcher.ps1", __DIR__)
  @uninstaller Path.expand("../../../windows/Uninstall-Casein.ps1", __DIR__)
  @repair Path.expand("../../../windows/Repair-Casein.ps1", __DIR__)
  @support Path.expand("../../../windows/New-CaseinSupportBundle.ps1", __DIR__)
  @rollback Path.expand("../../../windows/Rollback-Casein.ps1", __DIR__)
  @trusted_lan Path.expand("../../../windows/Casein.TrustedLan.ps1", __DIR__)
  @development_bootstrap Path.expand(
                           "../../../windows/bootstrap/Casein.DevelopmentBootstrap.cs",
                           __DIR__
                         )
  @bootstrap_builder Path.expand(
                       "../../../scripts/build-windows-development-bootstrap.ps1",
                       __DIR__
                     )
  @manifest_signer Path.expand(
                     "../../../scripts/sign-windows-development-manifest.ps1",
                     __DIR__
                   )
  @development_packager Path.expand(
                          "../../../scripts/package-windows-development-release.ps1",
                          __DIR__
                        )

  test "tray host supervises the loopback desktop release" do
    script = File.read!(@tray_script)

    assert script =~ "System.Windows.Forms"
    assert script =~ "Add-Type -AssemblyName System.Security"
    assert script =~ "Windows.Forms.NotifyIcon"
    assert script =~ "http://127.0.0.1:$Port/healthz"
    assert script =~ "function New-CaseinLaunchClaim"
    assert script =~ "[Security.Cryptography.HMACSHA256]"
    assert script =~ "desktop_nonce={0}&desktop_timestamp={1}&desktop_proof={2}"
    refute script =~ "?desktop_token="
    assert script =~ "[System.Security.Cryptography.ProtectedData]::Protect"
    assert script =~ "[System.Security.Cryptography.ProtectedData]::Unprotect"
    assert script =~ "dpapi:"
    assert script =~ "'CASEIN_PROFILE' = 'desktop'"
    assert script =~ "'CASEIN_REPO_ADAPTER' = 'sqlite'"
    assert script =~ "'CASEIN_RELEASE_ROOT' = $script:Paths.ReleaseRoot"
    assert script =~ "'CASEIN_PREVIEW_CONTROL_ADAPTER' = 'playwright'"
    assert script =~ "'CASEIN_PREVIEW_PLAYWRIGHT_SCRIPT' = 'scripts/preview_playwright.mjs'"
    assert script =~ "'CASEIN_WINDOWS_PREVIEW_CONTROL_ONLY' = 'true'"
    assert script =~ "'CASEIN_API_TOKEN' = $apiToken"
    assert script =~ "'CASEIN_DESKTOP_LAUNCH_TOKEN' = $launchToken"
    assert script =~ "'RELEASE_DISTRIBUTION' = 'none'"
    assert script =~ "'RELEASE_NODE' = 'casein_desktop'"
    assert script =~ "'RELEASE_TMP' = $script:Paths.RuntimeTemp"
    assert script =~ "$runtime = Invoke-CaseinRelease -Arguments @('start') -Port $Port"
    assert script =~ "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE"
    assert script =~ "AssignProcessToJobObject"
    assert script =~ "function Clear-CaseinStaleRuntimeState"
    assert script =~ "Remove-Item -LiteralPath $script:Paths.RuntimeStatus"
    assert script =~ "Attempting automatic runtime recovery"
    assert script =~ "function Observe-CaseinRuntimeFailure"
    assert script =~ "function Update-CaseinRecoveryState"
    assert script =~ "Automatic runtime recovery exhausted after 3 attempts"
    assert script =~ "$script:LifecycleMutation = $true"
    assert script =~ "if (-not $script:LifecycleMutation)"
    assert script =~ "if (-not $script:LifecycleMutation -and $script:RecoveryAttempts -lt 3"
    assert script =~ "# must rebuild its environment and bind the requested LAN address."
    refute script =~ "Invoke-CaseinRelease -Arguments @('start') -Port $Port -Wait"
    assert script =~ "taskkill.exe /PID $runtimePid /T /F"
    assert script =~ "Local\\Casein.Desktop.Tray"
    assert script =~ "function Open-CaseinCockpit"
    assert script =~ "Opened the already-running Casein cockpit from a second launch"
    assert script =~ "$maxBytes = 2MB"
  end

  test "tray menu exposes the required lifecycle controls" do
    script = File.read!(@tray_script)

    for label <- [
          "Open Casein",
          "Restart",
          "Repair installation",
          "Roll back last update",
          "Open logs",
          "Create support bundle",
          "Rotate local access tokens",
          "Trusted LAN access",
          "Copy Trusted LAN URL",
          "Launch at Windows sign-in",
          "Quit Casein"
        ] do
      assert script =~ label
    end
  end

  test "launch at sign-in follows the stable launcher and uninstall removes it" do
    tray = File.read!(@tray_script)
    uninstaller = File.read!(@uninstaller)

    assert tray =~ "Programs\\Casein\\Casein.Launcher.ps1"
    assert tray =~ "The stable Casein launcher is missing"
    assert tray =~ "-ExecutionPolicy Bypass"
    refute tray =~ "$escapedRoot = $script:Paths.ReleaseRoot"
    assert uninstaller =~ "GetFolderPath('Startup')"
    assert uninstaller =~ "Remove-Item -LiteralPath $startupLink"
  end

  test "clean-machine acceptance can require space, long, and UNC package roots" do
    script = File.read!(Path.expand("../../../windows/Test-CaseinCleanMachine.ps1", __DIR__))

    assert script =~ "RequirePackageRootWithSpace"
    assert script =~ "RequireLongPackageRoot"
    assert script =~ "RequireUncPackageRoot"
    assert script =~ "MinimumLongPathLength = 180"
    assert script =~ "package_root_kind"
    assert script =~ "package_root_length"
    assert script =~ "package_root_has_space"
    assert script =~ "path_prerequisites"
    assert script =~ "schema = 3"
    assert script =~ "New-CaseinPhaseRecord"
    assert script =~ "started_at_utc"
    assert script =~ "completed_at_utc"
    assert script =~ "outcome = $Outcome"
    assert script =~ "Test-CaseinRebootPersistence.ps1"
    assert script =~ "real_reboot = $false"
    assert script =~ "clean_machine_no_tooling"
    assert script =~ "not prove reboot persistence"
    refute script =~ "package_root = $packageRoot"
  end

  test "reboot-persistence acceptance is two-stage with a bounded continuation marker" do
    script =
      File.read!(Path.expand("../../../windows/Test-CaseinRebootPersistence.ps1", __DIR__))

    package = File.read!(@package_script)
    smoke = File.read!(@package_smoke)

    assert script =~ "ValidateSet('prepare', 'continue', 'auto')"
    assert script =~ "awaiting_reboot"
    assert script =~ "prepare_boot_last_boot_up_time_utc"
    assert script =~ "continue_boot_last_boot_up_time_utc"
    assert script =~ "Host boot stamp is unchanged"
    assert script =~ "casein_reboot_continuation"
    assert script =~ "origin_id_prefix"
    assert script =~ "path_prerequisites"
    assert script =~ "New-CaseinPhaseRecord"
    assert script =~ "SelfTestContinuation"
    assert script =~ "$evidence.claims.real_reboot = $true"
    assert script =~ "not reboot or clean-machine evidence"
    refute script =~ "package_root = $packageRoot"
    refute script =~ "api-token"
    refute script =~ "desktop-launch-token"
    assert package =~ "Test-CaseinRebootPersistence.ps1"
    assert smoke =~ "Test-CaseinRebootPersistence.ps1"
    assert smoke =~ "SelfTestContinuation"
    assert smoke =~ "not reboot or clean-machine evidence"
  end

  test "destructive consent is enforced in the body, never at parameter binding" do
    script =
      File.read!(Path.expand("../../../windows/Test-CaseinRebootPersistence.ps1", __DIR__))

    smoke = File.read!(@package_smoke)

    # The package smoke invokes this harness non-interactively with only the
    # non-destructive switch. A [Parameter(Mandatory)] on the consent switch
    # binds BEFORE the -LibraryOnly / -SelfTestContinuation short-circuits, and
    # under -NonInteractive it cannot prompt — so it aborts with
    # MissingMandatoryParameter and takes the whole Windows package smoke red
    # before it ever reaches the packaged preview bridge walk.
    assert smoke =~ "-File $rebootHarness -SelfTestContinuation"

    refute script =~
             ~r/\[Parameter\(Mandatory[^\]]*\)\]\s*\r?\n\s*\[switch\]\$AcceptDestructiveCleanMachineTest/,
           "consent switch must not be binding-time mandatory — it blocks the " <>
             "non-destructive self-test the package smoke runs"

    # The safety property still has to hold, just where it belongs: on the
    # destructive path only, after the short-circuits.
    assert script =~ "if (-not $AcceptDestructiveCleanMachineTest) {"
    assert script =~ "only on a disposable clean Windows test account"

    guard_at = :binary.match(script, "if (-not $AcceptDestructiveCleanMachineTest) {") |> elem(0)
    self_test_at = :binary.match(script, "if ($SelfTestContinuation) {") |> elem(0)
    library_only_at = :binary.match(script, "if ($LibraryOnly) { return }") |> elem(0)

    assert self_test_at < guard_at,
           "-SelfTestContinuation must return before the destructive consent guard"

    assert library_only_at < guard_at,
           "-LibraryOnly must return before the destructive consent guard"
  end

  test "Trusted LAN selects a private physical interface and scopes its firewall rule" do
    script = File.read!(@trusted_lan)
    tray = File.read!(@tray_script)
    uninstaller = File.read!(@uninstaller)

    assert script =~ "Get-NetIPConfiguration -Detailed"
    assert script =~ "Get-NetIPInterface -AddressFamily IPv4"
    assert script =~ "NetworkCategory -ne 'Private'"
    assert script =~ "vpn|wireguard|tailscale|tunnel|tap|tun|hyper-v|vethernet|wsl"
    assert script =~ "Sort-Object"
    assert script =~ "-Profile Private"
    assert script =~ "-LocalAddress $selected.Address"
    assert script =~ "-LocalPort $ListenPort"
    assert script =~ "-Program $program"
    assert script =~ "-RemoteAddress LocalSubnet"
    assert script =~ "Remove-CaseinTrustedLanFirewallRules"
    assert tray =~ "'CASEIN_DESKTOP_LAN'] = 'true'"
    assert tray =~ "'CASEIN_LAN_INSECURE_HTTP'] = 'true'"
    assert tray =~ "'PHX_IP'] = '0.0.0.0'"
    assert uninstaller =~ "-Action Disable"
  end

  test "Trusted LAN remains loopback-only until an upgrade refreshes its program-scoped rule" do
    tray = File.read!(@tray_script)

    assert tray =~ "function Resolve-CaseinTrustedLanProgram"
    assert tray =~ "reconciliation_required = $true"
    assert tray =~ "previous_program = $savedProgram"
    assert tray =~ "Set-CaseinTrustedLan $true $script:Port"
    assert tray =~ "Trusted LAN firewall rule reconciled successfully"
    assert tray =~ "Read-CaseinTrustedLanState keeps the runtime loopback-only"
    assert tray =~ "'PHX_IP'] = '0.0.0.0'"
  end

  test "rollback swaps only between validated installed release roots" do
    script = File.read!(@rollback)

    assert script =~ "previous_release_root"
    assert script =~ "StartsWith($releasesRoot"
    assert script =~ "releases\\casein.relmeta.json"
    assert script =~ "rollback = $true"
  end

  test "repair validates the installed release and reruns migrations" do
    script = File.read!(@repair)

    assert script =~ "StartsWith($releasesRoot"
    assert script =~ "bin\\casein.bat"
    assert script =~ "& $release migrate"
    assert script =~ "Get-Process -Id $runtimePid"
  end

  test "support bundle includes diagnostics but excludes local credentials and data" do
    script = File.read!(@support)

    assert script =~ "desktop-host.log"
    assert script =~ "runtime.json"
    assert script =~ "trusted-lan.json"
    assert script =~ "system.json"
    assert script =~ "credential-state.json"
    assert script =~ "crash-state.json"
    assert script =~ "recovery_status = [string]$crashState.recovery_status"
    assert script =~ "allowedStatuses"
    assert script =~ "function ConvertTo-CaseinUtcTimestamp"
    assert script =~ "function Write-CaseinInvalidStateMarker"
    assert script =~ "rotated_at_utc = ConvertTo-CaseinUtcTimestamp"
    assert script =~ "has_previous_release"
    assert script =~ "has_previous_data_backup"
    refute script =~ "Copy-Item -LiteralPath $source -Destination $stage"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'api-token.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'desktop-launch-token.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'secret-key-base.txt')"
    refute script =~ "Copy-Item -LiteralPath (Join-Path $DataRoot 'casein.sqlite3')"
  end

  test "access-token rotation is DPAPI protected and rolls back failed health" do
    script = File.read!(@tray_script)

    assert script =~ "function Invoke-CaseinAccessTokenRotation"
    assert script =~ "Save-CaseinProtectedSecret $apiPath"
    assert script =~ "Save-CaseinProtectedSecret $launchPath"
    assert script =~ "rotated_at_utc"
    assert script =~ "if (-not (& $Validate))"
    assert script =~ "throw $rotationError"
    assert script =~ "Previous credentials were restored"
    refute script =~ "Write-CaseinLog $rotatedApiToken"
  end

  test "packager builds the Windows SQLite release and copies the host" do
    script = File.read!(@package_script)

    assert script =~ "$env:CASEIN_NATIVE_WINDOWS = 'true'"
    assert script =~ "$env:CASEIN_REPO_ADAPTER = 'sqlite'"
    assert script =~ "Asset dependencies are missing"
    assert script =~ "@('compile', '--force')"
    assert script =~ "'_build\\prod\\rel\\casein'"
    assert script =~ "@('release', 'casein', '--overwrite')"
    assert script =~ "app = 'casein'"
    assert script =~ "CASEIN_GIT_REVISION = $sourceRevision"
    assert script =~ "Read-DesktopReleaseMetadata"
    assert script =~ "Refusing to package a dirty source tree"
    # The refusal runs on a CI host nobody can open a shell on, after dependency
    # fetch and preview-runtime preparation. Without the paths it is unactionable.
    assert script =~ "Unexpected working-tree changes"
    assert script =~ "New-DesktopArchive"
    assert script =~ "Copy-DesktopTree"
    assert script =~ "robocopy.exe"
    assert script =~ "tar.exe"
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "Write-ReleaseTrustManifest"
    assert script =~ "Set-AuthenticodeSignature"

    assert script =~
             "Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.ps1', '.psm1') }"

    assert script =~ "Write-SignedUpdateCatalog"
    assert script =~ "New-FileCatalog"
    assert script =~ "Test-FileCatalog"
    assert script =~ "RequireSigned"
    assert script =~ "windows\\Casein.Tray.ps1"
    assert script =~ "windows\\Install-Casein.ps1"
    assert script =~ "pwa-icon-192.png"
    assert script =~ "windows\\Casein.png"
  end

  test "installer verifies signed release identity and file hashes before mutation" do
    script = File.read!(@installer)

    assert script =~ "Test-ReleaseTrust $packageRoot"
    assert script =~ "Get-AuthenticodeSignature"
    assert script =~ "CASEIN_REQUIRE_SIGNED_RELEASES"
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "Release integrity check failed"
    assert script =~ "SignedFiles"
    assert script =~ "Packaged executable is not trusted"
    assert script =~ "Copy-ReleaseTree"
    assert script =~ "robocopy.exe"
    assert script =~ "Remove-ReleaseTree"
    assert script =~ "function Remove-StaleReleaseStages"
    assert script =~ "StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)"
    assert script =~ "Get-Process -Id $ownerPid -ErrorAction SilentlyContinue"
    assert script =~ "Remove-StaleReleaseStages -ReleasesRoot $releasesRoot -ReleaseId $releaseId"
  end

  test "development bootstrap pins its channel key without weakening production trust" do
    bootstrap = File.read!(@development_bootstrap)
    builder = File.read!(@bootstrap_builder)
    signer = File.read!(@manifest_signer)
    development_packager = File.read!(@development_packager)
    tray = File.read!(@tray_script)
    installer = File.read!(@installer)
    package = File.read!(@package_script)

    assert bootstrap =~ "__CASEIN_RSA_MODULUS__"
    assert bootstrap =~ "VerifyManifestSignature"
    assert bootstrap =~ "VerifyArtifactFile"
    assert bootstrap =~ "Archive path traversal was rejected"
    assert bootstrap =~ "Development update URLs must be credential-free HTTPS URLs"
    assert bootstrap =~ "The update artifact must use the manifest origin"
    assert bootstrap =~ "-AllowUnsignedDevelopment -Launch"
    assert builder =~ "GetRSAPublicKey"
    assert signer =~ "RSASignaturePadding]::Pkcs1"
    assert signer =~ "channel -ne 'development'"
    assert development_packager =~ "CASEIN_RELEASE_CHANNEL = 'development'"
    assert development_packager =~ "DevelopmentBootstrapPath"
    assert development_packager =~ "sign-windows-development-manifest.ps1"
    assert package =~ "DevelopmentBootstrapPath"
    assert package =~ "Casein.DevelopmentBootstrap.exe"
    assert installer =~ "Casein.DevelopmentBootstrap.exe"
    assert tray =~ "(-not $signer -or -not [string]$signer.Value)"
    assert tray =~ "Start-Process -FilePath $developmentBootstrap"
    assert tray =~ "Update-Casein.ps1"
    assert installer =~ "Get-AuthenticodeSignature"
    assert package =~ "RequireSigned"
  end

  test "Windows package requires a self-contained Playwright runtime" do
    package = File.read!(@package_script)
    prepare = File.read!(@preview_prepare)

    assert package =~ "Assert-WindowsPreviewRuntime"
    assert package =~ "runtime\\node.exe"
    assert package =~ "playwright-browsers"
    assert prepare =~ "PLAYWRIGHT_BROWSERS_PATH"
    assert prepare =~ "install chromium"
  end

  test "tray uses the Casein code mark with status badges" do
    script = File.read!(@tray_script)

    assert script =~ "Join-Path $PSScriptRoot 'Casein.png'"
    assert script =~ "$graphics.DrawImage($source"
    assert script =~ "$graphics.FillEllipse($statusBrush"
    refute script =~ "$graphics.DrawString('D'"
  end

  test "per-user installer stages an update with a user-data backup" do
    installer = File.read!(@installer)
    launcher = File.read!(@launcher)
    uninstaller = File.read!(@uninstaller)

    assert installer =~ "Programs\\Casein"
    assert installer =~ "before-update-"
    assert installer =~ "previous_data_backup"
    refute installer =~ "@('casein.sqlite3', 'desktop-host.json', 'secret-key-base.txt'"

    assert installer =~
             "Move-Item -LiteralPath $temporaryCurrent -Destination $currentPath -Force"

    assert launcher =~ "current.json"
    assert launcher =~ "Casein.Tray.ps1"
    assert installer =~ "Get-Process -Id $runtimePid -ErrorAction SilentlyContinue"
    assert uninstaller =~ "Get-Process -Id $runtimePid -ErrorAction SilentlyContinue"
    assert uninstaller =~ "RemoveUserData"
  end

  test "package smoke recovers malformed settings and runtime markers" do
    smoke = File.read!(@package_smoke)

    assert smoke =~ "Set-Content -LiteralPath $settingsPath -Value '{malformed-settings'"
    assert smoke =~ "Read-CaseinSettings"
    assert smoke =~ "Malformed settings unexpectedly enabled launch at sign-in"
    assert smoke =~ "Set-Content -LiteralPath $runtimePidPath -Value 'not-a-process-id'"
    assert smoke =~ "Clear-CaseinStaleRuntimeState $recoveryProbePort"
    assert smoke =~ "Malformed runtime status marker was not removed"
  end

  test "verified installer recovers malformed installed release state" do
    installer = File.read!(@installer)
    smoke = File.read!(@package_smoke)

    assert installer =~
             "Installed release state is invalid and will be replaced from the verified package."

    refute installer =~ "Write-Warning \"Installed release state is invalid:"
    assert smoke =~ "Set-Content -LiteralPath $currentPath -Value '{malformed-current-state'"
    assert smoke =~ "Stable launcher accepted malformed installed release state"
    assert smoke =~ "Malformed-state recovery install exited with $LASTEXITCODE"
    assert smoke =~ "Recovery install did not restore current release identity"
  end

  test "package smoke reaps only interrupted installer staging" do
    smoke = File.read!(@package_smoke)

    assert smoke =~ "\"$releaseId.staging-2147483647\""
    assert smoke =~ "\"$releaseId.staging-$PID\""
    assert smoke =~ "Installer left a stale interrupted staging directory behind"
    assert smoke =~ "Installer removed staging owned by a live concurrent process"
  end
end
