defmodule DevIdeWeb.WorkspaceLive.Show.RunEventsTest do
  use DevIDE.TestCase, async: false

  alias DevIdeWeb.WorkspaceLive.Show.RunEvents

  setup do
    root = Path.join(System.tmp_dir!(), "run-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: DevIdeWeb.Endpoint,
      view: DevIdeWeb.WorkspaceLive.Show,
      root_pid: self(),
      private: %{live_temp: %{}},
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: "ws-events"},
            palette_open: true,
            tab: "files",
            audit_drawer_open: true,
            selected_run_id: nil,
            run_ledger: [],
            selected_run_timeline: [],
            selected_run_summary: nil,
            selected_run_artifacts: [],
            selected_run_failure_reason: nil,
            selected_run_can_retry: false,
            terminal_context: %{},
            host_path: {:error, :not_set},
            host_loc: {:error, :not_set},
            current_user: %{id: "u1", username: "u1"},
            db_isolation: %{},
            flash: %{}
          },
          assigns
        )
    }
  end

  defp flash_info(socket), do: socket.assigns.flash["info"]

  describe "handle_event/3" do
    test "run:start shows flash for non-interactive commands" do
      {:noreply, socket} = RunEvents.handle_event("run:start", %{"id" => "compile"}, socket())

      refute socket.assigns.palette_open
      assert flash_info(socket) =~ "Batch command runs were retired"
    end

    test "workflow:hint closes palette and shows guidance flash" do
      {:noreply, socket} = RunEvents.handle_event("workflow:hint", %{}, socket())

      refute socket.assigns.palette_open
      assert flash_info(socket) =~ "needs a bit more detail"
    end

    test "workflow:run closes palette and shows retired flash" do
      {:noreply, socket} = RunEvents.handle_event("workflow:run", %{}, socket())

      refute socket.assigns.palette_open
      assert flash_info(socket) =~ "Workflow runs were retired"
    end

    test "run_ledger:select refreshes ledger assigns" do
      {:noreply, socket} =
        RunEvents.handle_event("run_ledger:select", %{"id" => "run-selected"}, socket())

      assert socket.assigns.selected_run_id == "run-selected"
      assert is_list(socket.assigns.run_ledger)
      assert is_list(socket.assigns.selected_run_timeline)
    end

    test "run_ledger:open switches tab and refreshes ledger" do
      {:noreply, socket} =
        RunEvents.handle_event("run_ledger:open", %{"id" => "run-open"}, socket())

      assert socket.assigns.tab == "run"
      refute socket.assigns.audit_drawer_open
      assert socket.assigns.selected_run_id == "run-open"
    end

    test "run:cancel is a no-op" do
      sock = socket(%{active_run: %{status: :running}})
      assert {:noreply, ^sock} = RunEvents.handle_event("run:cancel", %{}, sock)
    end
  end
end
