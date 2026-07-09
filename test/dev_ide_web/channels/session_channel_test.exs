defmodule DevIdeWeb.SessionChannelTest do
  @moduledoc """
  Covers the mobile companion channel's two load-bearing contracts:

    1. The auth gate — any authenticated peer may observe (flat peer model;
       oauth2-proxy / pairing token is the outer identity gate).
    2. The live spine — an emitted audit event triggers a debounced snapshot
       push, proving the `Audit` → `SessionChannel` wire is connected.
  """
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Audit
  alias DevIDE.Integrations.Manager.Client
  alias DevIDE.Mobile.UserObserver
  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIdeWeb.ChannelAuth

  @endpoint DevIdeWeb.Endpoint

  setup do
    workspace_root = Path.join(System.tmp_dir!(), "devide-session-channel")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)

    MemoryAdapter.clear()
    Audit.clear()
    clear_mobile_observers()

    Req.Test.stub(Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", workspace_id, "status"]} = conn ->
        cond do
          workspace_id == "ws-1" ->
            workspace_status_payload(conn, workspace_id, workspace_path)

          workspace_id == "missing-ws" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))

          workspace_id == "unavailable-ws" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "unavailable"}))

          true ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
        end

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      clear_mobile_observers()
      File.rm_rf(workspace_root)
      restore_env(:workspaces_root, prev_root)
      restore_env(:default_workspace_mode, prev_default)
    end)

    {:ok, workspace_path: workspace_path}
  end

  test "owner join is authorized and returns the initial snapshot" do
    assert {:ok, reply, _socket} = join_as(%{id: "dev", email: "dev@local"})
    assert reply.workspace_id == "ws-1"
    assert reply.mode == :review
    # Fresh workspace: no runs yet, but the projection still hydrates cleanly.
    assert reply.current_run == nil
    assert is_list(reply.recent_audit)
    assert reply.pending_reviews == 0
  end

  test "workspace-scoped pairing token may join only its paired session topic" do
    token =
      ChannelAuth.sign_pairing_token(
        %{id: "dev", email: "dev@local", role: :owner},
        "ws-1"
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})
    assert socket.assigns.pairing_workspace_id == "ws-1"

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.SessionChannel, "session:ws-1")

    assert reply.workspace_id == "ws-1"

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})

    assert {:error, %{reason: "workspace_scope_mismatch"}} =
             subscribe_and_join(socket, DevIdeWeb.SessionChannel, "session:other-ws")
  end

  test "peer join is allowed under the flat peer model" do
    assert {:ok, _reply, _socket} =
             join_as(%{id: "peer", email: "peer@local"})
  end

  test "missing workspace join explains that the workspace was not found" do
    assert {:error, %{reason: "workspace_not_found"}} =
             join_as("missing-ws", %{id: "dev", email: "dev@local"})
  end

  test "failed session joins create connection issue cards for mobile" do
    prepare_mobile_observer("dev")

    assert {:error, %{reason: "workspace_not_found"}} =
             join_as("missing-ws", %{id: "dev", email: "dev@local"})

    assert_receive {:mobile_cards_snapshot, %{cards: [missing]}}, 1_000
    assert missing.type == :connection_issue
    assert missing.workspace_id == "missing-ws"
    assert missing.priority == :high
    assert missing.title == "Could not join session"
    assert missing.meta.reason == :join_failed

    assert {:error, %{reason: "workspace_unavailable"}} =
             join_as("unavailable-ws", %{id: "dev", email: "dev@local"})

    assert_receive {:mobile_cards_snapshot, %{cards: cards}}, 1_000
    offline = Enum.find(cards, &(&1.workspace_id == "unavailable-ws"))
    assert offline.type == :connection_issue
    assert offline.priority == :normal
    assert offline.title == "Workspace offline"
    assert offline.meta.reason == :offline
  end

  test "workspace scope failures create pairing recovery cards" do
    prepare_mobile_observer("dev")

    token =
      ChannelAuth.sign_pairing_token(
        %{id: "dev", email: "dev@local", role: :owner},
        "ws-1"
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})

    assert {:error, %{reason: "workspace_scope_mismatch"}} =
             subscribe_and_join(socket, DevIdeWeb.SessionChannel, "session:other-ws")

    assert_receive {:mobile_cards_snapshot, %{cards: [card]}}, 1_000
    assert card.type == :connection_issue
    assert card.workspace_id == "other-ws"
    assert card.priority == :high
    assert card.title == "Pairing expired"
    assert card.meta.reason == :token_revoked
  end

  test "successful session joins clear stale connection issue cards" do
    prepare_mobile_observer("dev")

    UserObserver.connection_issue_changed("dev", %{workspace_id: "ws-1", reason: :offline})

    assert_receive {:mobile_cards_snapshot, %{cards: [card]}}, 1_000
    assert card.type == :connection_issue
    assert card.workspace_id == "ws-1"

    assert {:ok, _reply, _socket} = join_as(%{id: "dev", email: "dev@local"})

    assert_receive {:mobile_cards_snapshot, %{cards: []}}, 1_000
  end

  test "an audit event for the workspace pushes a debounced snapshot" do
    assert {:ok, _reply, _socket} = join_as(%{id: "dev", email: "dev@local"})

    Audit.emit(%{
      workspace_id: "ws-1",
      action: "policy.blocked",
      decision: :deny,
      reason: :not_allowlisted
    })

    # Debounce is 150ms; allow generous slack for CI.
    assert_push "snapshot", payload, 1_000
    assert payload.workspace_id == "ws-1"
  end

  test "an alert-worthy action pushes a discrete alert" do
    assert {:ok, _reply, _socket} = join_as(%{id: "dev", email: "dev@local"})

    Audit.emit(%{
      workspace_id: "ws-1",
      action: "policy.blocked",
      decision: :deny,
      reason: :not_allowlisted
    })

    assert_push "alert", alert, 1_000
    assert alert.workspace_id == "ws-1"
    assert alert.action == "policy.blocked"
    assert alert.title == "Blocked by policy"
    assert alert.reason == "not_allowlisted"
  end

  test "a non-alert audit action pushes no alert (snapshot only)" do
    assert {:ok, _reply, _socket} = join_as(%{id: "dev", email: "dev@local"})

    Audit.emit(%{workspace_id: "ws-1", action: "run.started", decision: :allow})

    refute_push "alert", _payload, 400
  end

  test "an audit event for a *different* workspace does not push", %{
    workspace_path: workspace_path
  } do
    workspace_id = "session-channel-#{System.unique_integer([:positive])}"
    stub_workspace_status(workspace_id, workspace_path)

    assert {:ok, _reply, _socket} = join_as(workspace_id, %{id: "dev", email: "dev@local"})

    Audit.emit(%{workspace_id: "other-ws", action: "policy.blocked", decision: :deny})

    refute_push "snapshot", _payload, 400
  end

  defp join_as(current_user) do
    join_as("ws-1", current_user)
  end

  defp join_as(workspace_id, current_user) do
    DevIdeWeb.UserSocket
    |> socket("users_socket:#{current_user.id}", %{current_user: current_user})
    |> Phoenix.Socket.assign(:current_user, current_user)
    |> subscribe_and_join(DevIdeWeb.SessionChannel, "session:#{workspace_id}")
  end

  defp prepare_mobile_observer(user_id) do
    :ok = UserObserver.clear(user_id)
    :ok = UserObserver.subscribe(user_id)
    flush_messages()
  end

  defp clear_mobile_observers do
    Enum.each(["dev", "intruder"], &UserObserver.stop/1)
  end

  defp workspace_status_payload(conn, workspace_id, workspace_path) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => workspace_id,
        "name" => "alpha",
        "user" => "dev",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp stub_workspace_status(workspace_id, workspace_path) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^workspace_id, "status"]} = conn ->
        workspace_status_payload(conn, workspace_id, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
