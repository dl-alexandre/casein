defmodule PreviewCtl.Playwright.BridgeTest do
  use ExUnit.Case, async: false

  alias PreviewCtl.Playwright.Bridge

  @fake_script "test/support/preview_playwright_fake_daemon.cjs"

  setup do
    previous = Application.get_env(:preview_ctl, :playwright_script)

    on_exit(fn ->
      put_or_delete_env(previous)
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
             :dev_ide
             |> :code.priv_dir()
             |> List.to_string()
             |> Path.join("scripts/preview_playwright.mjs")
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

    parent = self()

    task =
      Task.async(fn ->
        send(parent, :first_started)
        Bridge.command(%{action: "observe_live", url: "http://example.test/one"})
      end)

    assert_receive :first_started, 5_000

    assert {:error, :playwright_busy} =
             Bridge.command(%{action: "click", url: "http://example.test/two"})

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

  defp restart_bridge! do
    _ = Supervisor.terminate_child(DevIde.Supervisor, Bridge)
    {:ok, _} = Supervisor.restart_child(DevIde.Supervisor, Bridge)
  end

  defp put_or_delete_env(nil), do: Application.delete_env(:preview_ctl, :playwright_script)

  defp put_or_delete_env(value),
    do: Application.put_env(:preview_ctl, :playwright_script, value)
end
