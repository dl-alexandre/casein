defmodule DevIdeWeb.WorkspaceLive.Show.AgentEventsTest do
  use DevIDE.TestCase, async: false

  alias DevIdeWeb.WorkspaceLive.Show.AgentEvents

  setup do
    root = Path.join(System.tmp_dir!(), "agent-events-#{System.unique_integer([:positive])}")
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

  describe "audit_drawer events" do
    test "audit_drawer:toggle flips audit_drawer_open" do
      {:noreply, socket} = AgentEvents.handle_event("audit_drawer:toggle", %{}, socket())

      refute socket.assigns.audit_drawer_open
    end

    test "audit_drawer:close clears audit_drawer_open" do
      {:noreply, socket} = AgentEvents.handle_event("audit_drawer:close", %{}, socket())

      refute socket.assigns.audit_drawer_open
    end
  end

  describe "annotation:open" do
    test "is a no-op when the workspace root is unavailable" do
      sock = socket()

      {:noreply, socket} =
        AgentEvents.handle_event("annotation:open", %{"path" => "README.md"}, sock)

      assert socket == sock
    end
  end

  describe "agent:start_review_run" do
    test "denies an unknown command id without spawning anything", %{root: root} do
      sock = socket(%{host_path: {:ok, root}})

      {:noreply, socket} =
        AgentEvents.handle_event("agent:start_review_run", %{"id" => "nope"}, sock)

      assert flash_info(socket) == nil
      assert socket.assigns.flash["error"] =~ "Not allowed"
      assert socket.assigns.last_decision.reason == :not_allowed
    end

    test "denies a known command when required capability is missing", %{root: root} do
      sock = socket(%{host_path: {:ok, root}})

      {:noreply, socket} =
        AgentEvents.handle_event(
          "agent:start_review_run",
          %{"id" => "opencode-version"},
          sock
        )

      assert socket.assigns.flash["error"] =~ "Not allowed"
      assert socket.assigns.last_decision.reason == :requires_not_met
    end

    test "is a no-op when the workspace root is unavailable" do
      sock = socket()

      {:noreply, socket} =
        AgentEvents.handle_event("agent:start_review_run", %{"id" => "opencode-version"}, sock)

      assert socket == sock
    end
  end

  describe "load_review_commands/1" do
    test "returns every allowlisted command with its capability availability", %{root: root} do
      socket = AgentEvents.load_review_commands(socket(%{host_path: {:ok, root}}))

      assert [{%DevIDE.Agents.ReviewCommand{id: "opencode-version"}, available?}] =
               socket.assigns.review_commands

      refute available?
    end

    test "leaves review_commands untouched when the workspace root is unavailable" do
      socket = AgentEvents.load_review_commands(socket())
      refute Map.has_key?(socket.assigns, :review_commands)
    end
  end
end
