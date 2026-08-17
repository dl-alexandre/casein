defmodule Scripts.RepairTmuxEnvTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/repair-tmux-env.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "not a casein session is a benign skip (exit 0)" do
    ctx = fixture!()

    {out, 0} = repair(ctx, ["__casein_keepalive"])

    assert outcome(out) == "skipped:not_casein_session"
    assert out =~ "not a casein workspace session"
  end

  test "not a casein session stays 0 even when workspace listing would fail" do
    ctx = fixture!(curl_fail: true)

    {out, 0} = repair(ctx, ["not-a-casein-session"])

    assert outcome(out) == "skipped:not_casein_session"
    refute out =~ "failed:workspace_listing"
  end

  test "unknown workspace is an actionable skip (exit 2), not success" do
    ctx = fixture!()

    {out, 2} = repair(ctx, ["casein_nosuchws_foo"])

    assert outcome(out) == "skipped:unknown_workspace"
    assert out =~ "unknown workspace nosuchws"
    refute out =~ ~r/^repaired$/m
  end

  test "missing scoped token is an actionable skip (exit 3), not success" do
    ctx = fixture!()

    {out, 3} = repair(ctx, ["casein_knownws_sess"])

    assert outcome(out) == "skipped:no_scoped_token"
    assert out =~ "no workspace-scoped token for knownws"
  end

  test "workspace listing failure is a hard error (exit 1), not per-session unknown" do
    ctx = fixture!(curl_fail: true)

    {out, 1} = repair(ctx, ["casein_knownws_sess"])

    assert outcome(out) == "failed:workspace_listing"
    assert out =~ "failed to list workspaces"
    refute out =~ "unknown workspace"
  end

  test "actionable skip paths must not return 0" do
    source = File.read!(@script)

    refute source =~ ~r/unknown workspace \$\{workspace_name\}\)"\n\s+return 0/,
           "unknown-workspace skip restored return 0"

    refute source =~ ~r/no workspace-scoped token.*\n(?:.*\n){0,2}\s+return 0/,
           "no-scoped-token skip restored return 0"
  end

  defp fixture!(opts \\ []) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "repair-tmux-env-#{System.unique_integer([:positive, :monotonic])}"
      )

    bin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    File.mkdir_p!(bin)
    File.mkdir_p!(home)

    env_file = Path.join(tmp, "casein.env")
    File.write!(env_file, "CASEIN_API_TOKEN=unused-admin\n")

    token_store = Path.join(tmp, "workspace-api-tokens.json")
    File.write!(token_store, "{}")

    curl = Path.join(bin, "curl")

    File.write!(curl, """
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${FAKE_CURL_FAIL:-}" == "1" ]]; then
      echo "curl: (22) The requested URL returned error: 403" >&2
      exit 22
    fi
    printf '%s\\n' '[{"name":"knownws","id":"ws-known"}]'
    """)

    File.chmod!(curl, 0o755)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{
      tmp: tmp,
      bin: bin,
      home: home,
      env_file: env_file,
      token_store: token_store,
      curl_fail: Keyword.get(opts, :curl_fail, false)
    }
  end

  defp repair(ctx, args) do
    env = [
      {"HOME", ctx.home},
      {"PATH", "#{ctx.bin}:/usr/bin:/bin"},
      {"CASEIN_API_TOKEN", "test-token"},
      {"CASEIN_ENV_FILE", ctx.env_file},
      {"CASEIN_WORKSPACE_TOKENS_STORE", ctx.token_store},
      {"CASEIN_URL", "http://127.0.0.1:1"},
      {"FAKE_CURL_FAIL", if(ctx.curl_fail, do: "1", else: "0")}
    ]

    System.cmd("bash", [@script | args], env: env, stderr_to_stdout: true)
  end

  defp outcome(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find("", &(&1 =~ ~r/^(repaired|skipped:|failed:)/))
  end
end
