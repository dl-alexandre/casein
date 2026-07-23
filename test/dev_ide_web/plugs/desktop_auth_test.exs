defmodule DevIdeWeb.Plugs.DesktopAuthTest do
  use DevIDE.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias DevIdeWeb.Plugs.DesktopAuth
  alias DevIDE.Desktop.{LaunchClaim, LaunchReplayStore}

  @launch_secret String.duplicate("a", 48)

  setup do
    previous_mode = Application.get_env(:dev_ide, :desktop_mode)
    previous_token = Application.get_env(:dev_ide, :desktop_launch_token)
    previous_lan = Application.get_env(:dev_ide, :desktop_lan)
    previous_lan_hosts = Application.get_env(:dev_ide, :desktop_lan_hosts)

    Application.put_env(:dev_ide, :desktop_mode, true)
    Application.put_env(:dev_ide, :desktop_launch_token, @launch_secret)
    LaunchReplayStore.reset()

    on_exit(fn ->
      restore(:desktop_mode, previous_mode)
      restore(:desktop_launch_token, previous_token)
      restore(:desktop_lan, previous_lan)
      restore(:desktop_lan_hosts, previous_lan_hosts)
    end)

    :ok
  end

  test "exchanges a valid launch token for a signed browser session" do
    conn =
      :get
      |> desktop_conn("/?#{claim_query()}")
      |> DesktopAuth.call([])

    assert conn.halted
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/"]
    assert get_session(conn, "current_user").id == "desktop"
  end

  test "rejects replay of an otherwise valid launch claim" do
    query = claim_query()

    first = :get |> desktop_conn("/?#{query}") |> DesktopAuth.call([])
    second = :get |> desktop_conn("/?#{query}") |> DesktopAuth.call([])

    assert first.status == 302
    assert second.status == 401
  end

  test "only one concurrent exchange can consume a launch claim" do
    params = claim_params()

    results =
      1..8
      |> Task.async_stream(fn _ -> LaunchClaim.verify_and_consume(params, @launch_secret) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed})) == 7
  end

  test "persists consumed claims across replay-store restarts" do
    directory =
      Path.join(System.tmp_dir!(), "launch-replays-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "claims.dets")
    name = :desktop_auth_restart_test_store
    table = :desktop_auth_restart_test_table
    nonce = :crypto.strong_rand_bytes(16)
    now = System.system_time(:second)

    on_exit(fn -> File.rm_rf(directory) end)
    {:ok, pid} = LaunchReplayStore.start_link(name: name, table: table, path: path)
    assert :ok = LaunchReplayStore.consume(nonce, now + 120, now, name)
    GenServer.stop(pid)

    {:ok, pid} = LaunchReplayStore.start_link(name: name, table: table, path: path)
    assert {:error, :replayed} = LaunchReplayStore.consume(nonce, now + 120, now, name)
    GenServer.stop(pid)
  end

  test "rejects expired and future launch claims" do
    now = System.system_time(:second)

    for timestamp <- [now - 121, now + 11] do
      conn = :get |> desktop_conn("/?#{claim_query(timestamp)}") |> DesktopAuth.call([])
      assert conn.status == 401
    end
  end

  test "rejects malformed and incorrectly signed launch claims" do
    malformed = :get |> desktop_conn("/?desktop_nonce=x&desktop_timestamp=nope&desktop_proof=y")
    invalid = :get |> desktop_conn("/?#{claim_query()}x")

    assert DesktopAuth.call(malformed, []).status == 401
    assert DesktopAuth.call(invalid, []).status == 401
  end

  test "rejects a request with no launch token or desktop session" do
    conn = :get |> desktop_conn("/") |> DesktopAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "allows the loopback health probe without granting cockpit access" do
    conn = :get |> desktop_conn("/healthz") |> DesktopAuth.call([])

    refute conn.halted
    refute Map.has_key?(conn.assigns, :current_user)
  end

  test "rejects non-local host headers before checking credentials" do
    conn =
      :get
      |> desktop_conn("/?#{claim_query()}")
      |> Map.put(:host, "rebinding.invalid")
      |> DesktopAuth.call([])

    assert conn.halted
    assert conn.status == 421
  end

  test "accepts only explicitly configured LAN host headers when LAN mode is enabled" do
    Application.put_env(:dev_ide, :desktop_lan, true)
    Application.put_env(:dev_ide, :desktop_lan_hosts, ["DairyBookPro.local", "192.168.1.72"])

    accepted =
      :get
      |> desktop_conn("/?#{claim_query()}")
      |> Map.put(:host, "dairybookpro.local")
      |> DesktopAuth.call([])

    rejected =
      :get
      |> desktop_conn("/?#{claim_query()}")
      |> Map.put(:host, "attacker.local")
      |> DesktopAuth.call([])

    assert accepted.status == 302
    assert rejected.status == 421
  end

  test "accepts a previously issued desktop session without a token" do
    conn =
      :get
      |> desktop_conn("/", %{"current_user" => %{id: "desktop"}})
      |> DesktopAuth.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == "desktop"
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp claim_query(timestamp \\ System.system_time(:second)) do
    URI.encode_query(claim_params(timestamp))
  end

  defp claim_params(timestamp \\ System.system_time(:second)) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    proof =
      LaunchClaim.proof(@launch_secret, timestamp, nonce) |> Base.url_encode64(padding: false)

    %{
      "desktop_nonce" => nonce,
      "desktop_timestamp" => Integer.to_string(timestamp),
      "desktop_proof" => proof
    }
  end

  defp desktop_conn(method, path, session \\ %{}) do
    method
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> init_test_session(session)
  end
end
