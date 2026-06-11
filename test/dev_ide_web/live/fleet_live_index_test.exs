defmodule DevIdeWeb.FleetLiveIndexTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Fleet

  setup do
    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
    end)

    :ok
  end

  test "debounced fleet refresh coalesces rapid registry notifications", %{conn: conn} do
    Application.put_env(:dev_ide, :fleet_live_refresh_debounce_ms, 50)

    on_exit(fn ->
      Application.delete_env(:dev_ide, :fleet_live_refresh_debounce_ms)
    end)

    {:ok, runner} =
      Fleet.register(%{
        hostname: "debounce-runner",
        capabilities: ["workspace-command:v1"]
      })

    {:ok, view, _html} = live(conn, ~p"/fleet")

    for _ <- 1..5, do: assert({:ok, _} = Fleet.heartbeat(runner.id))

    Process.sleep(80)

    html = render(view)
    assert html =~ "debounce-runner"
    assert html =~ "online"
  end
end
