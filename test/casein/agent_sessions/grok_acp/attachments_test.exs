defmodule Casein.AgentSessions.GrokACP.AttachmentsTest do
  use Casein.TestCase, async: false

  alias Casein.AgentSessions.GrokACP.Attachments
  alias Casein.Test.GrokACPAttachmentFakeTransport

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "devide-grok-attachments-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    leader_root = Path.join(home, ".casein/grok-leaders")
    transcript_dir = Path.join(home, ".grok/sessions/2026/07/session")
    digest = String.duplicate("a", 64)
    bundle_dir = Path.join(home, ".casein/grok-bundles/sha256-#{digest}")

    File.mkdir_p!(leader_root)
    File.chmod!(leader_root, 0o700)
    File.mkdir_p!(transcript_dir)
    File.mkdir_p!(bundle_dir)

    transcript_path = Path.join(transcript_dir, "updates.jsonl")
    File.write!(transcript_path, "")

    previous = %{
      home: System.get_env("HOME"),
      enabled: Application.get_env(:casein, :grok_acp_auto_attach),
      leader_root: Application.get_env(:casein, :grok_leader_root),
      transport: Application.get_env(:casein, :grok_acp_transport),
      transport_opts: Application.get_env(:casein, :grok_acp_transport_opts),
      validator: Application.get_env(:casein, :grok_acp_bundle_validator)
    }

    System.put_env("HOME", home)
    Application.put_env(:casein, :grok_acp_auto_attach, true)
    Application.put_env(:casein, :grok_leader_root, leader_root)
    Application.put_env(:casein, :grok_acp_transport, GrokACPAttachmentFakeTransport)
    Application.put_env(:casein, :grok_acp_transport_opts, test_pid: self())
    Application.put_env(:casein, :grok_acp_bundle_validator, &File.dir?/1)
    Attachments.clear()

    on_exit(fn ->
      Attachments.clear()
      restore_env("HOME", previous.home)
      restore_app_env(:grok_acp_auto_attach, previous.enabled)
      restore_app_env(:grok_leader_root, previous.leader_root)
      restore_app_env(:grok_acp_transport, previous.transport)
      restore_app_env(:grok_acp_transport_opts, previous.transport_opts)
      restore_app_env(:grok_acp_bundle_validator, previous.validator)
      File.rm_rf!(root)
    end)

    %{
      root: root,
      leader_root: leader_root,
      transcript_path: transcript_path,
      bundle_dir: bundle_dir,
      digest: digest
    }
  end

  test "attaches to a validated private leader and provides workspace permission APIs", ctx do
    workspace_id = "workspace-#{System.unique_integer([:positive])}"
    session_id = "grok-session-1"
    leader_socket = leader_socket(ctx, "0123456789abcdef01234567")

    :ok = Attachments.subscribe(workspace_id)

    assert :ok =
             Attachments.observe(
               observation(ctx,
                 workspace_id: workspace_id,
                 session_id: session_id,
                 leader_socket: leader_socket
               )
             )

    assert_receive {:grok_acp_attachment_transport_started, pid, opts}
    assert opts[:leader_socket] == leader_socket
    assert opts[:leader_mode] == :attach
    assert opts[:plugin_dirs] == [ctx.bundle_dir]
    assert opts[:session_id] == session_id

    initialize = assert_request(pid, "initialize")

    send_json(pid, %{
      jsonrpc: "2.0",
      id: initialize["id"],
      result: %{
        protocolVersion: 1,
        agentCapabilities: %{loadSession: true},
        _meta: %{"x.ai/pluginDirs": true}
      }
    })

    load = assert_request(pid, "session/load")
    assert load["params"]["sessionId"] == session_id
    assert load["params"]["_meta"]["pluginDirs"] == [ctx.bundle_dir]
    send_json(pid, %{jsonrpc: "2.0", id: load["id"], result: %{sessionId: session_id}})
    sync(pid)

    assert [snapshot] = Attachments.list(workspace_id)
    assert snapshot.attachment_key == session_id
    assert snapshot.session_id == session_id
    assert snapshot.status == :ready
    assert snapshot.bundle_digest == ctx.digest
    refute Map.has_key?(snapshot, :leader_socket)
    refute Map.has_key?(snapshot, :bundle_dir)

    send_json(pid, %{
      jsonrpc: "2.0",
      id: 42,
      method: "session/request_permission",
      params: %{
        sessionId: session_id,
        toolCall: %{toolCallId: "tc-42", title: "Run tests"},
        options: [%{optionId: "allow-once", name: "Allow once", kind: "allow_once"}]
      }
    })

    sync(pid)

    assert [snapshot] = Attachments.list(workspace_id)
    assert [%{request_id: 42, tool_call_id: "tc-42"}] = snapshot.pending_permissions

    assert {:error, :invalid_option} =
             Attachments.respond_permission(workspace_id, session_id, "42", "stale-option")

    assert :ok = Attachments.respond_permission(workspace_id, session_id, "42", "allow-once")
    response = assert_response(pid, 42)
    assert response["result"]["outcome"]["optionId"] == "allow-once"
    assert [snapshot] = Attachments.list(workspace_id)
    assert snapshot.pending_permissions == []

    assert_receive {:grok_acp_attachments_updated, ^workspace_id, snapshots}
    assert Enum.any?(snapshots, &(&1.attachment_key == session_id))
  end

  test "deduplicates unchanged observations and restarts when connection inputs change", ctx do
    workspace_id = "workspace-restart-#{System.unique_integer([:positive])}"
    leader_socket = leader_socket(ctx, "abcdef0123456789abcdef01")

    attrs =
      observation(ctx,
        workspace_id: workspace_id,
        session_id: "grok-session-restart",
        leader_socket: leader_socket
      )

    assert :ok = Attachments.observe(attrs)
    assert_receive {:grok_acp_attachment_transport_started, first, _opts}
    _initialize = assert_request(first, "initialize")

    assert :ok = Attachments.observe(attrs)
    refute_receive {:grok_acp_attachment_transport_started, _pid, _opts}, 50

    next_digest = String.duplicate("b", 64)
    next_bundle = Path.join(Path.dirname(ctx.bundle_dir), "sha256-#{next_digest}")
    File.mkdir_p!(next_bundle)

    assert :ok =
             Attachments.observe(%{
               attrs
               | grok_bundle_dir: next_bundle,
                 grok_bundle_digest: next_digest
             })

    assert_receive {:grok_acp_attachment_transport_stopped, ^first}
    assert_receive {:grok_acp_attachment_transport_started, second, opts}
    refute second == first
    assert opts[:plugin_dirs] == [next_bundle]

    assert [snapshot] = Attachments.list(workspace_id)
    assert snapshot.bundle_digest == next_digest
  end

  test "accepts a session-start observation before updates.jsonl is created", ctx do
    workspace_id = "workspace-pending-transcript-#{System.unique_integer([:positive])}"
    leader_socket = leader_socket(ctx, "1234567890abcdef12345678")
    File.rm!(ctx.transcript_path)

    assert :ok =
             Attachments.observe(
               observation(ctx,
                 workspace_id: workspace_id,
                 session_id: "grok-session-pending-transcript",
                 leader_socket: leader_socket
               )
             )

    assert_receive {:grok_acp_attachment_transport_started, _pid, opts}
    assert opts[:session_id] == "grok-session-pending-transcript"
  end

  test "rejects global sockets and incomplete metadata without spawning Grok", ctx do
    attrs =
      observation(ctx,
        workspace_id: "workspace-invalid",
        session_id: "grok-session-invalid",
        leader_socket: Path.join(System.get_env("HOME"), ".grok/leader.sock")
      )

    assert {:error, :invalid_grok_attachment_metadata} = Attachments.observe(attrs)
    refute_receive {:grok_acp_attachment_transport_started, _pid, _opts}, 50
    assert Attachments.list("workspace-invalid") == []
  end

  defp observation(ctx, opts) do
    %{
      workspace_id: Keyword.fetch!(opts, :workspace_id),
      tmux_session_id: "devide_workspace_session",
      pane_id: "%7",
      cwd: ctx.root,
      transcript_path: ctx.transcript_path,
      agent_session_id: Keyword.fetch!(opts, :session_id),
      agent_runtime: "grok",
      source: :hook,
      grok_leader_socket: Keyword.fetch!(opts, :leader_socket),
      grok_bundle_dir: ctx.bundle_dir,
      grok_bundle_digest: ctx.digest
    }
  end

  defp leader_socket(ctx, leader_id) do
    leader_dir = Path.join(ctx.leader_root, leader_id)
    File.mkdir_p!(leader_dir)
    File.chmod!(leader_dir, 0o700)
    Path.join(leader_dir, "leader.sock")
  end

  defp assert_request(pid, method) do
    assert_receive {:grok_acp_attachment_transport_write, ^pid, line}
    request = Jason.decode!(line)
    assert request["method"] == method
    request
  end

  defp assert_response(pid, id) do
    assert_receive {:grok_acp_attachment_transport_write, ^pid, line}
    response = Jason.decode!(line)
    assert response["id"] == id
    response
  end

  defp send_json(pid, message) do
    send(pid, {:grok_acp_transport, :stdout, Jason.encode!(message) <> "\n"})
  end

  defp sync(pid) do
    _ = :sys.get_state(pid)
    _ = :sys.get_state(Attachments)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)
end
