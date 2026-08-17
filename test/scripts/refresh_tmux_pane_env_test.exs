defmodule Scripts.RefreshTmuxPaneEnvTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/refresh-tmux-pane-env.sh", __DIR__)
  @repair Path.expand("../../scripts/lib/repair-tmux-env.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "continues after an actionable skip and still exits non-zero" do
    ctx = fixture!()

    {out, 1} = refresh(ctx, ["casein_nosuchws_foo", "__casein_keepalive"])

    assert out =~ "unknown workspace nosuchws"
    assert out =~ "not a casein workspace session"
    assert out =~ "unrepaired casein_nosuchws_foo (skipped:unknown_workspace)"
    assert out =~ "done (1 session(s) unrepaired)"
  end

  test "all-benign explicit sessions stay exit 0" do
    ctx = fixture!()

    {out, 0} = refresh(ctx, ["__casein_keepalive", "not-a-casein-session"])

    assert out =~ "not a casein workspace session"
    refute out =~ "unrepaired"
    assert out =~ ~r/^>>> done$/m
  end

  test "listing failure on a casein session fails the refresh" do
    ctx = fixture!(curl_fail: true)

    {out, 1} = refresh(ctx, ["casein_knownws_sess"])

    assert out =~ "failed:workspace_listing"
    assert out =~ "unrepaired casein_knownws_sess"
  end

  test "refresh script does not invoke repair as a bare set -e command" do
    source = File.read!(@script)
    refute source =~ ~r/^\s+bash "\$REPAIR" "\$session"$/m
  end

  test "repair script is the one refresh wraps" do
    assert File.exists?(@repair)
    assert File.read!(@script) =~ ~s[REPAIR="${ROOT}/scripts/lib/repair-tmux-env.sh"]
  end

  defp fixture!(opts \\ []) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "refresh-tmux-pane-#{System.unique_integer([:positive, :monotonic])}"
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
      bin: bin,
      home: home,
      env_file: env_file,
      token_store: token_store,
      curl_fail: Keyword.get(opts, :curl_fail, false)
    }
  end

  defp refresh(ctx, args) do
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
end
