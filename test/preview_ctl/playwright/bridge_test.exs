defmodule PreviewCtl.Playwright.BridgeTest do
  use Casein.TestCase, async: false

  alias PreviewCtl.Playwright.Bridge

  @fake_script "test/support/preview_playwright_fake_daemon.cjs"

  setup do
    previous = Application.get_env(:preview_ctl, :playwright_script)
    previous_timeout = Application.get_env(:preview_ctl, :playwright_command_timeout_ms)

    on_exit(fn ->
      put_or_delete_env(previous)
      put_or_delete_timeout(previous_timeout)
      restart_bridge!()
    end)

    :ok
  end

  test "returns nil when no helper script is configured" do
    Application.delete_env(:preview_ctl, :playwright_script)

    assert Bridge.script_path() == nil
  end

  test "resolves repo-style helper paths from the current working directory" do
    Application.put_env(
      :preview_ctl,
      :playwright_script,
      "priv/scripts/preview_playwright.mjs"
    )

    assert Bridge.script_path() ==
             Path.expand("priv/scripts/preview_playwright.mjs", File.cwd!())
  end

  test "resolves release-style helper paths from the app priv directory" do
    Application.put_env(:preview_ctl, :playwright_script, "scripts/preview_playwright.mjs")

    assert Bridge.script_path() ==
             :casein
             |> :code.priv_dir()
             |> List.to_string()
             |> Path.join("scripts/preview_playwright.mjs")
  end

  test "prefers a release-local Node runtime over PATH" do
    root = Path.join(System.tmp_dir!(), "pw-node-#{System.unique_integer([:positive])}")
    script = Path.join(root, "preview_playwright.mjs")
    node_name = if match?({:win32, _}, :os.type()), do: "node.exe", else: "node"
    node = Path.join([root, "runtime", node_name])
    File.mkdir_p!(Path.dirname(node))
    File.write!(script, "")
    File.write!(node, "")

    assert Path.expand(Bridge.node_executable(script)) == Path.expand(node)

    File.rm_rf!(root)
  end

  test "command/1 returns playwright_unavailable when the helper is not configured" do
    Application.delete_env(:preview_ctl, :playwright_script)
    restart_bridge!()

    assert {:error, :playwright_unavailable} =
             Bridge.command(%{action: "observe_live", url: "http://example.test/"})
  end

  test "command/1 exchanges JSON with the helper daemon" do
    Application.put_env(:preview_ctl, :playwright_script, @fake_script)
    restart_bridge!()

    assert {:ok, %{"ok" => true, "observation" => %{"title" => "Fake Page"}}} =
             Bridge.command(%{
               action: "observe_live",
               url: "http://example.test/",
               browser_id: "pw-test",
               default_headers: %{},
               params: %{}
             })
  end

  test "command/1 rejects concurrent requests while one is in flight" do
    Application.put_env(:preview_ctl, :playwright_script, @fake_script)
    restart_bridge!()

    # The daemon parks the first request until we touch this sentinel, so the
    # in-flight window is held open deterministically rather than racing the
    # daemon's reply. Without it, the fake daemon answers instantly and the
    # second command can arrive after `pending` has already cleared.
    release =
      Path.join(System.tmp_dir!(), "pw-bridge-release-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(release) end)

    task =
      Task.async(fn ->
        Bridge.command(%{action: "block", url: "http://example.test/one", release_path: release})
      end)

    # Wait until the first command actually owns the Bridge's pending slot —
    # only then is a second command guaranteed to see it as busy. This replaces
    # the previous send-before-call handshake, which signalled "task started"
    # rather than "request in flight".
    wait_until(fn -> match?(%{pending: pending} when not is_nil(pending), bridge_state()) end)

    assert {:error, :playwright_busy} =
             Bridge.command(%{action: "click", url: "http://example.test/two"})

    File.touch!(release)

    assert {:ok, _} = Task.await(task, 5_000)
  end

  test "command/1 surfaces invalid helper responses" do
    script_dir =
      Path.join(System.tmp_dir!(), "pw-bridge-invalid-#{System.unique_integer([:positive])}")

    File.mkdir_p!(script_dir)

    script = Path.join(script_dir, "invalid_daemon.cjs")

    File.write!(script, """
    #!/usr/bin/env node
    console.log(JSON.stringify({unexpected: true}));
    """)

    File.chmod!(script, 0o755)

    Application.put_env(:preview_ctl, :playwright_script, script)
    restart_bridge!()

    assert {:error, :invalid_playwright_response} =
             Bridge.command(%{action: "observe_live", url: "http://example.test/"})
  end

  test "command/1 times out a stuck helper and restarts cleanly" do
    Application.put_env(:preview_ctl, :playwright_script, @fake_script)
    Application.put_env(:preview_ctl, :playwright_command_timeout_ms, 50)
    restart_bridge!()

    release =
      Path.join(System.tmp_dir!(), "pw-bridge-timeout-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(release) end)

    assert {:error, {:playwright_timeout, 50}} =
             Bridge.command(%{
               action: "block",
               url: "http://example.test/timeout",
               release_path: release
             })

    assert {:ok, %{"ok" => true}} =
             Bridge.command(%{action: "observe_live", url: "http://example.test/restarted"})
  end

  defp restart_bridge! do
    _ = Supervisor.terminate_child(Casein.Supervisor, Bridge)
    {:ok, _} = Supervisor.restart_child(Casein.Supervisor, Bridge)
  end

  defp bridge_state, do: :sys.get_state(Bridge)

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("condition not met in time")

      true ->
        receive do
        after
          10 -> wait_until(fun, attempts - 1)
        end
    end
  end

  defp put_or_delete_env(nil), do: Application.delete_env(:preview_ctl, :playwright_script)

  defp put_or_delete_env(value),
    do: Application.put_env(:preview_ctl, :playwright_script, value)

  defp put_or_delete_timeout(nil),
    do: Application.delete_env(:preview_ctl, :playwright_command_timeout_ms)

  defp put_or_delete_timeout(value),
    do: Application.put_env(:preview_ctl, :playwright_command_timeout_ms, value)
end
