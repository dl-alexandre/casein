defmodule Casein.Scripts.GrokAuthRefreshTest do
  @moduledoc """
  The persistent Grok OAuth store must survive a failed refresh.

  `~/.grok/auth.json` is host-global and its refresh token rotates on use. When
  several workers spawned together each ran the launcher's `grok models` refresh
  probe, they raced one token: the losers presented an already-rotated
  credential, and Grok answered the failed refresh by deleting the store.

  That is not a recoverable state for an unattended launch. It demotes "expired,
  refresh it" — which the probe handles — into "signed out", which only an
  interactive operator login fixes, and every spawn until then dies with
  `persistent Grok auth.json is missing`. Observed on 2026-07-30, 2026-08-03
  02:08, and 2026-08-03 21:18, each needing a manual re-login.

  So: one refresh at a time, and the store is put back if a refresh destroys it.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-casein-agent.sh", __DIR__)
  @root Path.expand("../..", __DIR__)

  describe "a refresh that deletes the credential store" do
    test "restores the snapshot instead of leaving the box signed out" do
      home = home_with_auth(expires_in: -3600)
      original = File.read!(auth_path(home))

      grok = fake_grok(home, ~S(rm -f "${HOME}/.grok/auth.json"))

      {output, status} = refresh(home, grok)

      assert status != 0,
             "an expired credential that could not be refreshed is still a failure"

      assert File.exists?(auth_path(home)),
             "the store was left deleted — this is the exact state that needs an operator login"

      assert File.read!(auth_path(home)) == original,
             "the restored store must be byte-identical to the pre-refresh snapshot"

      assert output =~ "restored the pre-refresh snapshot",
             "a destroyed-and-restored store must be announced, not silently papered over"
    end

    test "names the real binary in the sign-in hint, not the shim" do
      home = home_with_auth(expires_in: -3600)
      grok = fake_grok(home, ~S(rm -f "${HOME}/.grok/auth.json"))

      {output, status} = refresh(home, grok)

      assert status != 0
      assert output =~ "login --device-auth", "the headless recovery command must be named"

      assert output =~ grok,
             """
             The hint must name the resolved binary. Bare `grok` resolves through the
             shim back into this launcher, which would sign in against the managed
             home and leave the persistent store just as empty.
             """
    end
  end

  describe "serialization" do
    test "concurrent launches never probe the shared store at the same time" do
      home = home_with_auth(expires_in: -3600)
      marks = Path.join(home, "probe-marks")

      # Leaves the credential expired, so both callers reach the probe.
      grok =
        fake_grok(home, ~s(printf 'IN\\n' >>"#{marks}"; sleep 0.6; printf 'OUT\\n' >>"#{marks}"))

      [a, b] =
        [grok, grok]
        |> Enum.map(fn bin -> Task.async(fn -> refresh(home, bin) end) end)
        |> Task.await_many(60_000)

      assert elem(a, 1) != 0 and elem(b, 1) != 0

      assert File.read!(marks) |> String.split("\n", trim: true) == ~w(IN OUT IN OUT),
             """
             Overlapping probes are the race that wipes the store: two `grok models`
             runs rotating one refresh token, the loser's failure taken as "signed out".
             """
    end

    test "a launch queued behind a successful refresh skips the probe entirely" do
      home = home_with_auth(expires_in: 3600)
      marks = Path.join(home, "probe-marks")
      grok = fake_grok(home, ~s(printf 'PROBED\\n' >>"#{marks}"))

      {output, 0} = refresh(home, grok)

      refute File.exists?(marks),
             "the store was already current; re-probing it only re-enters the rotation race"

      assert output =~ ~s("auth_mode":"oidc"),
             "the current credential must still be printed for GROK_AUTH"
    end
  end

  describe "wiring" do
    test "the launcher refreshes through the guarded path, not an inline probe" do
      body = function_source("grok_prepare_managed_home")

      assert body =~ "grok_refresh_persistent_auth",
             "the refresh must go through the serialized, snapshot-guarded helper"

      refute body =~ "--no-auto-update models",
             """
             An inline probe in the per-launch path is the original bug: every
             concurrent spawn rotates the same refresh token.
             """
    end

    test "the snapshot is kernel-denied to the sandbox like the store it copies" do
      source = File.read!(@script)

      assert source =~ "CASEIN_GROK_AUTH_BACKUP_DIR:-${HOME}/.casein/grok-auth-backups}\" \\",
             """
             The snapshot holds the same refresh token as ~/.grok/auth.json. If it is
             not in the deny set, the backup becomes the readable copy of the
             credential the deny set exists to hide.
             """
    end
  end

  defp refresh(home, grok_bin) do
    extracted = Path.join(home, "refresh.sh")
    File.write!(extracted, function_source("grok_refresh_persistent_auth"))

    System.cmd(
      "bash",
      [
        "-c",
        """
        set -euo pipefail
        ROOT="#{@root}"
        source "#{extracted}"
        grok_refresh_persistent_auth "#{grok_bin}"
        """
      ],
      env: [{"HOME", home}, {"CASEIN_GROK_AUTH_BACKUP_DIR", nil}],
      stderr_to_stdout: true
    )
  end

  # The launcher runs on source, so the unit under test is lifted out by name.
  # Only a genuinely self-contained function (ROOT and HOME aside) survives this.
  defp function_source(name) do
    [_, rest] = String.split(File.read!(@script), "#{name}() {", parts: 2)
    [body, _] = String.split(rest, "\n}\n", parts: 2)
    "#{name}() {#{body}\n}\n"
  end

  defp home_with_auth(expires_in: seconds) do
    home = Path.join(System.tmp_dir!(), "grok-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".grok"))
    on_exit(fn -> File.rm_rf(home) end)
    File.write!(auth_path(home), auth_document(seconds))
    home
  end

  defp auth_path(home), do: Path.join([home, ".grok", "auth.json"])

  defp auth_document(expires_in) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    Jason.encode!(%{
      "https://auth.x.ai::test-client" => %{
        "auth_mode" => "oidc",
        "key" => "test-access-key",
        "refresh_token" => "test-refresh-token",
        "oidc_issuer" => "https://auth.x.ai",
        "oidc_client_id" => "test-client",
        "create_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "expires_at" => expires_at
      }
    })
  end

  defp fake_grok(home, body) do
    path = Path.join(home, "fake-grok")

    File.write!(path, """
    #!/usr/bin/env bash
    #{body}
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
