defmodule DevIdeWeb.TerminalChannelRemoteTest do
  @moduledoc """
  End-to-end acceptance tests for the remote-attachment path.

  Exercises the full stack:

      LocalRunnerAdapter broadcast / Fleet.Registry broadcast
        → PubSub
        → RemoteOutputStreamer (gap detection, runner-unreachable)
        → TerminalChannel
        → client push ("data" / "exit")

  These complement the unit tests in
  `test/dev_ide/terminals/remote_output_streamer_test.exs`, which validate the
  streamer in isolation. Together they prove the wiring works end-to-end.
  """

  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Fleet.{ExecutionProjection, ExecutionProjectionStore, Notification}

  @endpoint DevIdeWeb.Endpoint
  @pubsub DevIde.PubSub

  setup do
    bypass = Bypass.open()
    workspace_root = Path.join(System.tmp_dir!(), "devide-terminal-channel-remote")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "ws-1",
          "name" => "alpha",
          "user" => "alice",
          "status" => "running",
          "type" => "v3",
          "branch" => "main",
          "path" => workspace_path
        })
      )
    end)

    # Seed a projection so RemoteOutputStreamer.init can resolve the
    # assignment_id and subscribe to fleet:assignments:<aid> (the topic
    # Fleet.Registry uses for lease lifecycle events).
    execution_id = "exec-acc-#{System.unique_integer([:positive])}"
    assignment_id = "asg-acc-#{System.unique_integer([:positive])}"

    projection = %ExecutionProjection{
      id: execution_id,
      assignment_id: assignment_id,
      runner_id: "remote-runner",
      lease_id: "lease-#{System.unique_integer([:positive])}",
      workspace_id: "ws-1",
      tmux_session: "devide_#{execution_id}",
      state: :started,
      started_at: DateTime.utc_now()
    }

    :ok = ExecutionProjectionStore.create(projection)

    on_exit(fn ->
      ExecutionProjectionStore.clear()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
    end)

    {:ok, execution_id: execution_id, assignment_id: assignment_id}
  end

  describe "remote attachment (TerminalChannel + RemoteOutputStreamer)" do
    test "gap in OutputChunk seq surfaces as a 'data' push containing the gap marker",
         %{execution_id: eid} do
      sid = "exec_" <> eid
      {:ok, _reply, _socket} = join_remote(sid)

      # First two chunks land normally.
      broadcast_chunk(eid, "stdout", "alpha", 1)
      broadcast_chunk(eid, "stdout", "beta", 2)
      assert_data_received("alpha")
      assert_data_received("beta")

      # Skip seqs 3 and 4. The streamer should emit a gap marker, then the chunk.
      broadcast_chunk(eid, "stdout", "epsilon", 5)

      gap_push = receive_data_matching(&String.contains?(&1, "output gap"))
      assert gap_push =~ "2 chunk(s) lost"
      assert gap_push =~ "between seq 3 and 4"
      assert gap_push =~ "stdout"

      assert_data_received("epsilon")
    end

    test "lease expiry on the assignment topic pushes 'exit' with runner_unreachable reason",
         %{execution_id: eid, assignment_id: aid} do
      sid = "exec_" <> eid
      {:ok, _reply, _socket} = join_remote(sid)

      # Broadcast a lease_expired notification on the assignment topic — this
      # is what Fleet.Registry does when a lease misses its renewal window.
      # The notification carries no execution_id and is tagged Fleet.Registry
      # (not LocalRunnerAdapter), so it specifically tests the wiring fixes
      # made in Track B.
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:assignments:#{aid}",
        {DevIDE.Fleet.Registry,
         %Notification{
           kind: :lease_expired,
           assignment_id: aid,
           lease_id: "lease-acc",
           runner_id: "remote-runner",
           payload: %{},
           occurred_at: DateTime.utc_now()
         }}
      )

      assert_push("exit", %{reason: reason}, 1_000)
      assert reason =~ "runner_unreachable"
    end
  end

  # ---------- helpers ----------

  defp join_remote(sid) do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
      "mode" => "governed",
      "host_id" => "local"
    })
  end

  defp broadcast_chunk(execution_id, stream, chunk, seq) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "fleet:executions:#{execution_id}",
      {DevIDE.Fleet.LocalRunnerAdapter,
       %Notification{
         kind: :output_chunk,
         execution_id: execution_id,
         payload: %{stream: stream, chunk: chunk, seq: seq, byte_size: byte_size(chunk)},
         occurred_at: DateTime.utc_now()
       }}
    )
  end

  defp assert_data_received(needle) do
    assert_push("data", %{data: data}, 500)

    assert data =~ needle,
           "expected data push containing #{inspect(needle)}, got #{inspect(data)}"
  end

  defp receive_data_matching(pred, attempts \\ 5)

  defp receive_data_matching(_pred, 0), do: flunk("no matching 'data' push received")

  defp receive_data_matching(pred, attempts) do
    assert_push("data", %{data: data}, 500)

    if pred.(data) do
      data
    else
      receive_data_matching(pred, attempts - 1)
    end
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
