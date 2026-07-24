defmodule CaseinWeb.WorkspaceLive.Show.LogsEventsTest do
  # Application env (:logs_adapter) is mutated in set_log_service coverage.
  use Casein.TestCase, async: false

  alias CaseinWeb.WorkspaceLive.Show.LogsEvents
  alias Phoenix.LiveView.LiveStream

  defmodule FakeLogsAdapter do
    @moduledoc false
    @behaviour Casein.Logs.Adapter

    @impl true
    def start_stream(workspace_id, service, pid) do
      ref = make_ref()
      send(pid, {:fake_logs_started, workspace_id, service, ref})
      {:ok, ref}
    end

    @impl true
    def stop_stream(_ref), do: :ok
  end

  defmodule FailingLogsAdapter do
    @moduledoc false
    @behaviour Casein.Logs.Adapter

    @impl true
    def start_stream(_workspace_id, _service, _pid), do: {:error, :backend_down}

    @impl true
    def stop_stream(_ref), do: :ok
  end

  setup do
    prev = Application.get_env(:casein, :logs_adapter)

    on_exit(fn ->
      if prev do
        Application.put_env(:casein, :logs_adapter, prev)
      else
        Application.delete_env(:casein, :logs_adapter)
      end
    end)

    :ok
  end

  defp socket(assigns) do
    ws_id = "ws-logs-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      # stream/3 attaches an after_render hook; bare sockets need a lifecycle.
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: ws_id},
            log_service: "web",
            log_ref: nil
          },
          assigns
        )
    }
  end

  defp stream_inserts(socket) do
    case socket.assigns.streams do
      %{log_lines: %LiveStream{inserts: inserts}} -> inserts
      _ -> []
    end
  end

  test "insert_log_line inserts an entry with the line text and 500-line limit" do
    s =
      socket(%{})
      |> Phoenix.LiveView.stream(:log_lines, [], reset: true)

    s2 = LogsEvents.insert_log_line(s, "hello from journal")

    inserts = stream_inserts(s2)
    assert length(inserts) == 1
    [{dom_id, at, item, limit, update_only} | _] = inserts

    assert is_binary(dom_id)
    assert String.starts_with?(dom_id, "log_lines-log-")
    assert at == -1
    assert item.text == "hello from journal"
    assert is_binary(item.id)
    assert String.starts_with?(item.id, "log-")
    # @max_log_lines is 500; negative limit keeps the tail of the stream.
    assert limit == -500
    assert update_only == false
  end

  test "insert_log_line appends multiple distinct entries" do
    s =
      socket(%{})
      |> Phoenix.LiveView.stream(:log_lines, [], reset: true)
      |> LogsEvents.insert_log_line("line-a")
      |> LogsEvents.insert_log_line("line-b")

    texts =
      s.assigns.streams.log_lines.inserts
      |> Enum.map(fn {_id, _at, item, _limit, _uo} -> item.text end)

    assert "line-a" in texts
    assert "line-b" in texts
    assert length(texts) == 2
  end

  test "set_log_service assigns the service, resets the stream, and starts a stream ref" do
    Application.put_env(:casein, :logs_adapter, FakeLogsAdapter)

    # Pre-seed so stream/4 takes the reset path (new streams never set reset?).
    s =
      socket(%{log_service: "web", log_ref: :stale})
      |> Phoenix.LiveView.stream(:log_lines, [%{id: "old", text: "stale"}], reset: true)

    assert {:noreply, s2} =
             LogsEvents.handle_event("set_log_service", %{"service" => "db"}, s)

    assert s2.assigns.log_service == "db"
    assert is_reference(s2.assigns.log_ref)
    # LiveStream.reset/1 flips reset? for the client; inserts are pruned after_render.
    assert %LiveStream{reset?: true} = s2.assigns.streams.log_lines
    assert_receive {:fake_logs_started, ws_id, "db", ref}
    assert ws_id == s.assigns.workspace.id
    assert ref == s2.assigns.log_ref
  end

  test "set_log_service stores a nil log_ref when the adapter fails" do
    Application.put_env(:casein, :logs_adapter, FailingLogsAdapter)
    s = socket(%{log_ref: make_ref()})

    assert {:noreply, s2} =
             LogsEvents.handle_event("set_log_service", %{"service" => "api"}, s)

    assert s2.assigns.log_service == "api"
    assert s2.assigns.log_ref == nil
  end

  test "start_log_stream assigns ref from a successful adapter" do
    Application.put_env(:casein, :logs_adapter, FakeLogsAdapter)
    s = socket(%{log_service: "web"})
    s2 = LogsEvents.start_log_stream(s)
    assert is_reference(s2.assigns.log_ref)
    assert_receive {:fake_logs_started, _, "web", _}
  end
end
