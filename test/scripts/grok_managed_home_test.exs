defmodule Scripts.GrokManagedHomeTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/grok-managed-home.py", __DIR__)
  @leader_id "0123456789abcdef01234567"
  @scrubbed_env ~w(
    XAI_API_KEY
    GROK_CODE_XAI_API_KEY
    GROK_AUTH
    GROK_AUTH_PATH
    GROK_AUTH_PROVIDER_COMMAND
    CASEIN_API_TOKEN
    CASEIN_ADMIN_API_TOKEN
    CASEIN_WORKSPACE_API_TOKENS
    CASEIN_GROK_XAI_API_KEY
  )

  setup do
    base = Path.join(System.tmp_dir!(), "grok-managed-home-#{System.unique_integer([:positive])}")
    home = Path.join(base, "user-home")
    root = Path.join(base, "managed")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, home: home, root: root}
  end

  test "prepares and resets a private per-leader home with isolated durable sessions", %{
    home: home,
    root: root
  } do
    managed_home = Path.join(root, @leader_id)
    private_sessions = Path.join(managed_home, "sessions")

    assert {^managed_home <> "\n", 0} = prepare(home, root, @leader_id)

    assert File.dir?(private_sessions)
    refute match?({:ok, _target}, File.read_link(private_sessions))

    config = File.read!(Path.join(managed_home, "config.toml"))
    assert config =~ "[toolset.bash]"

    for name <- @scrubbed_env do
      assert config =~ name
    end

    assert config =~ ~s(cmd_prefix = "unset )
    refute config =~ ";\""
    assert File.read!(Path.join(managed_home, "sandbox.toml")) =~ "rewrites this file"
    assert File.read!(Path.join(managed_home, "auth.json")) == "{}\n"
    assert mode(Path.join(managed_home, "config.toml")) == 0o600
    assert mode(Path.join(managed_home, "sandbox.toml")) == 0o600
    assert mode(Path.join(managed_home, "auth.json")) == 0o600
    assert mode(managed_home) == 0o700
    assert mode(private_sessions) == 0o700

    File.write!(Path.join(managed_home, "config.toml"), "model-mutated")
    File.write!(Path.join(managed_home, "sandbox.toml"), "model-mutated")

    assert {^managed_home <> "\n", 0} = command(home, ["resolve", root, @leader_id])
    assert File.read!(Path.join(managed_home, "config.toml")) == "model-mutated"

    assert {^managed_home <> "\n", 0} = prepare(home, root, @leader_id)
    refute File.read!(Path.join(managed_home, "config.toml")) =~ "model-mutated"
    refute File.read!(Path.join(managed_home, "sandbox.toml")) =~ "model-mutated"
  end

  test "rejects unsafe ids, paths, and substitutions", %{base: base, home: home, root: root} do
    assert {output, 2} = prepare(home, root, "../../unsafe")
    assert output =~ "invalid managed Grok leader id"

    assert {output, 2} = prepare(home, "relative/root", @leader_id)
    assert output =~ "must be absolute"

    target = Path.join(base, "target")
    symlink_root = Path.join(base, "symlink-root")
    File.mkdir_p!(target)
    File.ln_s!(target, symlink_root)
    assert {output, 2} = prepare(home, symlink_root, @leader_id)
    assert output =~ "contains a symlink"

    managed_home = Path.join(root, @leader_id)
    File.mkdir_p!(managed_home)
    File.write!(Path.join(managed_home, "not-sessions"), "")
    File.ln_s!(Path.join(managed_home, "not-sessions"), Path.join(managed_home, "sessions"))
    assert {output, 2} = prepare(home, root, @leader_id)
    assert output =~ "unexpected target"
  end

  test "migrates only the former canonical global sessions link", %{home: home, root: root} do
    managed_home = Path.join(root, @leader_id)
    global_sessions = Path.join([home, ".grok", "sessions"])
    File.mkdir_p!(managed_home)
    File.mkdir_p!(global_sessions)
    File.ln_s!(global_sessions, Path.join(managed_home, "sessions"))

    assert {_, 0} = prepare(home, root, @leader_id)
    assert File.dir?(Path.join(managed_home, "sessions"))
    refute match?({:ok, _target}, File.read_link(Path.join(managed_home, "sessions")))
    assert File.dir?(global_sessions)
  end

  test "rejects managed config symlink replacement", %{base: base, home: home, root: root} do
    managed_home = Path.join(root, @leader_id)
    assert {_, 0} = prepare(home, root, @leader_id)

    File.rm!(Path.join(managed_home, "config.toml"))
    outside = Path.join(base, "outside-config")
    File.write!(outside, "leave-me")
    File.ln_s!(outside, Path.join(managed_home, "config.toml"))

    assert {output, 2} = prepare(home, root, @leader_id)
    assert output =~ "managed file was replaced: config.toml"
    assert File.read!(outside) == "leave-me"
  end

  test "emits only the current provider access key", %{home: home} do
    auth_path = Path.join([home, ".grok", "auth.json"])
    File.mkdir_p!(Path.dirname(auth_path))

    File.write!(
      auth_path,
      Jason.encode!(%{
        "old-scope" => %{
          "key" => "old-access",
          "refresh_token" => "do-not-emit-old-refresh",
          "create_time" => "2025-01-01T00:00:00Z",
          "expires_at" => "2035-01-01T00:00:00Z"
        },
        "current-scope" => %{
          "key" => "current-access",
          "refresh_token" => "do-not-emit-current-refresh",
          "auth_mode" => "oidc",
          "oidc_issuer" => "https://auth.example",
          "oidc_client_id" => "client-id",
          "create_time" => "2026-01-01T00:00:00Z",
          "expires_at" => "2035-01-01T00:00:00Z"
        },
        "xai::api_key" => %{"key" => "unrelated-api-key"}
      })
    )

    assert {"current-access\n", 0} = command(home, ["access-key"])
    assert {"old-access\n", 0} = command(home, ["access-key", "old-scope"])

    assert {inline_json, 0} = command(home, ["auth-json"])
    inline = Jason.decode!(inline_json)
    assert inline["key"] == "current-access"
    assert inline["refresh_token"] == "do-not-emit-current-refresh"
    assert inline["auth_mode"] == "oidc"
  end

  test "refreshable inline auth fails closed for access-token-only entries", %{home: home} do
    auth_path = Path.join([home, ".grok", "auth.json"])
    File.mkdir_p!(Path.dirname(auth_path))

    File.write!(
      auth_path,
      Jason.encode!(%{
        "scope" => %{
          "key" => "access-only",
          "auth_mode" => "oidc",
          "expires_at" => "2035-01-01T00:00:00Z"
        }
      })
    )

    assert {output, 2} = command(home, ["auth-json"])
    assert output =~ "not refreshable OIDC"
    refute output =~ "access-only"
  end

  test "fails closed without exposing refresh credentials", %{home: home} do
    auth_path = Path.join([home, ".grok", "auth.json"])
    File.mkdir_p!(Path.dirname(auth_path))

    File.write!(
      auth_path,
      Jason.encode!(%{
        "one" => %{
          "key" => "access-one",
          "refresh_token" => "secret-refresh-one",
          "expires_at" => "2035-01-01T00:00:00Z"
        },
        "two" => %{
          "key" => "access-two",
          "refresh_token" => "secret-refresh-two",
          "expires_at" => "2035-01-01T00:00:00Z"
        }
      })
    )

    assert {output, 2} = command(home, ["access-key"])
    assert output =~ "ambiguous"
    refute output =~ "secret-refresh"
    refute output =~ "access-one"
    refute output =~ "access-two"
  end

  defp prepare(home, root, leader_id) do
    command(home, ["prepare", root, leader_id])
  end

  defp command(home, args) do
    System.cmd("python3", [@script | args],
      env: [{"HOME", home}],
      stderr_to_stdout: true
    )
  end

  defp mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end
end
