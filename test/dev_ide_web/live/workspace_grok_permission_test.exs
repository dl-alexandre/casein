defmodule CaseinWeb.WorkspaceGrokPermissionTest do
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.AgentSessions.GrokACP
  alias Casein.AgentSessions.GrokACP.Attachments
  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Labels
  alias Casein.Test.GrokACPFakeTransport
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-1"
  @workspace_name "alpha"

  setup do
    tmux_prefix = Casein.Terminals.Tmux.workspace_session_prefix(@workspace_name)

    kill_tmux_sessions_with_prefix(tmux_prefix)
    Attachments.clear()
    MemoryAdapter.clear()
    Audit.clear()
    Activity.clear()
    Labels.clear()

    on_exit(fn ->
      Attachments.clear()
      MemoryAdapter.clear()
      Audit.clear()
      Activity.clear()
      Labels.clear()
      kill_tmux_sessions_with_prefix(tmux_prefix)
    end)

    :ok
  end

  test "approves and denies structured Grok requests from every cockpit tab", %{conn: conn} do
    mount_env!("devide-workspace-grok-permission")

    attachment_key = "grok-ui-#{System.unique_integer([:positive])}"
    session_id = "session-with-a-long-stable-identifier-1234567890"
    :ok = Attachments.subscribe(@workspace_id)
    pid = start_ready_attachment!(attachment_key, session_id)

    send_permission(pid, 77, [
      %{optionId: "allow-once", name: "Allow once", kind: "allow_once"},
      %{optionId: "reject-once", name: "Reject once", kind: "reject_once"}
    ])

    inject_attachment!(pid, attachment_key)

    {:ok, view, html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")

    assert html =~ ~s(id="agent-terminal-approval-banner-#{@workspace_id}")
    assert html =~ ~s(id="header-agent-approval-count-#{@workspace_id}")
    refute html =~ ~s(id="agent-approval-center")

    html = view |> element("#notifications-open-#{@workspace_id}") |> render_click()

    assert html =~ ~s(id="agent-approval-center")
    assert html =~ "Agent approvals"
    assert html =~ "Execute test suite"
    assert html =~ "Allow once"
    assert html =~ "Reject once"
    refute html =~ "Deny request"
    refute html =~ "mix test --include private_token"
    assert has_element?(view, "button[phx-value-option-id='reject-once']")

    # The surface is global, not coupled to History or another cockpit tab.
    html = render_click(view, "switch_tab", %{"tab" => "files"})
    assert html =~ ~s(id="agent-approval-center")

    # Client-supplied attachment keys cannot escape the mounted workspace's
    # manager projection or reach an unrelated ACP process.
    html =
      render_click(view, "grok_permission:respond", %{
        "attachment-key" => "another-attachment",
        "request-id" => "77",
        "option-id" => "allow-once"
      })

    assert html =~ "Grok could not accept that response."
    refute_receive {:grok_acp_transport_write, ^pid, _line}, 30
    assert has_element?(view, "#agent-approval-center")

    dom_id = Base.url_encode64(attachment_key <> ":77", padding: false)

    view
    |> element("#grok-permission-#{dom_id} button[phx-value-option-id='allow-once']")
    |> render_click()

    assert_receive {:grok_acp_transport_write, ^pid, line}
    response = Jason.decode!(line)
    assert response["id"] == 77

    assert response["result"]["outcome"] == %{
             "outcome" => "selected",
             "optionId" => "allow-once"
           }

    assert Enum.any?(Audit.list(), fn event ->
             event.action == "agent.permission_decided" and
               event.workspace_id == @workspace_id and
               event.actor_id == "dev" and
               event.metadata[:outcome] == "selected" and
               event.metadata[:option_id] == "allow-once"
           end)

    refute has_element?(view, "#agent-approval-center")

    send_permission(pid, "permission-78", [
      %{optionId: "allow-once", name: "Allow once", kind: "allow_once"}
    ])

    assert [%{request_id: "permission-78"}] = GrokACP.status(pid).pending_permissions

    assert_receive {:grok_acp_attachments_updated, @workspace_id,
                    [%{pending_permissions: [%{request_id: "permission-78"}]}]}

    assert render(view) =~ "Deny request"

    view
    |> element("#agent-approval-center button[phx-click='grok_permission:cancel']")
    |> render_click()

    assert_receive {:grok_acp_transport_write, ^pid, cancel_line}
    cancel_response = Jason.decode!(cancel_line)
    assert cancel_response["id"] == "permission-78"
    assert cancel_response["result"]["outcome"] == %{"outcome" => "cancelled"}

    assert Enum.any?(Audit.list(), fn event ->
             event.action == "agent.permission_decided" and
               event.metadata[:outcome] == "cancelled" and
               not Map.has_key?(event.metadata, :option_id)
           end)

    refute has_element?(view, "#agent-approval-center")
  end

  defp start_ready_attachment!(attachment_key, session_id) do
    pid =
      start_supervised!(
        {GrokACP,
         {@workspace_id, File.cwd!(),
          transport: GrokACPFakeTransport,
          test_pid: self(),
          attachment_key: attachment_key,
          session_id: session_id,
          status_listener: Process.whereis(Attachments)}}
      )

    assert_receive {:grok_acp_transport_started, ^pid}
    initialize = assert_request(pid, "initialize")

    send_json(pid, %{
      jsonrpc: "2.0",
      id: initialize["id"],
      result: %{protocolVersion: 1, agentCapabilities: %{loadSession: true}}
    })

    load = assert_request(pid, "session/load")
    send_json(pid, %{jsonrpc: "2.0", id: load["id"], result: %{sessionId: session_id}})
    assert %{status: :ready, session_id: ^session_id} = GrokACP.status(pid)
    pid
  end

  defp send_permission(pid, request_id, options) do
    send_json(pid, %{
      jsonrpc: "2.0",
      id: request_id,
      method: "session/request_permission",
      params: %{
        sessionId: "grok-session",
        toolCall: %{
          toolCallId: "tool-#{request_id}",
          title: "Execute test suite",
          rawInput: "mix test --include private_token"
        },
        options: options
      }
    })

    _ = :sys.get_state(pid)
  end

  # Attachments.observe/1 owns production discovery and validation. This test
  # seeds an already-validated live attachment so it can focus on the operator
  # surface and its public decision API without creating host Grok sockets.
  defp inject_attachment!(pid, attachment_key) do
    snapshot = GrokACP.status(pid)

    observation = %{
      workspace_id: @workspace_id,
      attachment_key: attachment_key,
      session_id: snapshot.session_id,
      tmux_session_id: "devide_alpha_ui",
      pane_id: "%9",
      cwd: File.cwd!(),
      transcript_path: "/not-rendered/updates.jsonl",
      leader_socket: "/not-rendered/leader.sock",
      bundle_dir: "/not-rendered/bundle",
      bundle_digest: String.duplicate("a", 64)
    }

    entry = %{pid: pid, monitor_ref: nil, observation: observation, snapshot: snapshot}

    :sys.replace_state(Attachments, fn state ->
      %{state | attachments: Map.put(state.attachments, {@workspace_id, attachment_key}, entry)}
    end)
  end

  defp assert_request(pid, method) do
    assert_receive {:grok_acp_transport_write, ^pid, line}
    request = Jason.decode!(line)
    assert request["method"] == method
    request
  end

  defp send_json(pid, message) do
    send(pid, {:grok_acp_transport, :stdout, Jason.encode!(message) <> "\n"})
  end

  defp mount_env!(root_basename) do
    workspace_root = Path.join(System.tmp_dir!(), root_basename)
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.mkdir_p!(workspace_path)

    previous_root = Application.get_env(:dev_ide, :workspaces_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      restore(:workspaces_root, previous_root)
    end)

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", @workspace_id, "status"]} =
          conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => @workspace_id,
            "name" => @workspace_name,
            "user" => "dev",
            "status" => "running",
            "type" => "v3",
            "branch" => "main",
            "path" => workspace_path
          })
        )

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp kill_tmux_sessions_with_prefix(prefix) when is_binary(prefix) do
    with executable when is_binary(executable) <- System.find_executable("tmux"),
         {sessions, 0} <-
           System.cmd(
             executable,
             Casein.Terminals.TmuxServer.args() ++ ["list-sessions", "-F", "\#{session_name}"],
             stderr_to_stdout: true
           ) do
      sessions
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.each(fn session ->
        _ =
          System.cmd(
            executable,
            Casein.Terminals.TmuxServer.args() ++ ["kill-session", "-t", session],
            stderr_to_stdout: true
          )
      end)
    else
      _ -> :ok
    end

    :ok
  end
end
