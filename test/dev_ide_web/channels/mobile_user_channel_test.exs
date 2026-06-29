defmodule DevIdeWeb.MobileUserChannelTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Audit
  alias DevIDE.Mobile.UserObserver
  alias DevIDE.Push
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIdeWeb.ChannelAuth

  @endpoint DevIdeWeb.Endpoint

  setup do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "devide-mobile-user-channel-#{System.unique_integer([:positive])}"
      )

    prev_workspace_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_workspace_source = Application.get_env(:dev_ide, :workspace_source)
    prev_push_provider = Application.get_env(:dev_ide, :push_provider)
    prev_apns_config = Application.get_env(:dev_ide, DevIDE.Push.APNSProvider)
    File.mkdir_p!(workspace_root)
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)

    Audit.clear()
    MemoryAdapter.clear()
    Push.Registry.clear()

    on_exit(fn ->
      Audit.clear()
      MemoryAdapter.clear()
      Push.Registry.clear()
      File.rm_rf(workspace_root)
      restore_env(:workspaces_root, prev_workspace_root)
      restore_env(:workspace_source, prev_workspace_source)
      restore_env(:push_provider, prev_push_provider)
      restore_module_env(DevIDE.Push.APNSProvider, prev_apns_config)
    end)

    {:ok, workspace_root: workspace_root}
  end

  test "joins only the authenticated user's mobile topic" do
    user_id = unique_id("dev")
    prepare_user(user_id)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:#{user_id}", %{
        current_user: %{id: user_id, email: "#{user_id}@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: user_id, email: "#{user_id}@local"})

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.MobileUserChannel, "mobile:user:me")

    assert reply.user_id == user_id
    assert Jason.encode!(reply)
    assert reply.cards == []

    other_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:#{user_id}", %{
        current_user: %{id: user_id, email: "#{user_id}@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: user_id, email: "#{user_id}@local"})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(
               other_socket,
               DevIdeWeb.MobileUserChannel,
               "mobile:user:someone-else"
             )
  end

  test "mobile user me topic resolves to the authenticated socket user" do
    user_id = unique_id("dev")
    prepare_user(user_id)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:#{user_id}", %{
        current_user: %{id: user_id, email: "#{user_id}@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: user_id, email: "#{user_id}@local"})

    assert {:ok, reply, joined_socket} =
             subscribe_and_join(socket, DevIdeWeb.MobileUserChannel, "mobile:user:me")

    assert reply.user_id == user_id
    assert joined_socket.assigns.mobile_user_id == user_id
  end

  test "mobile user topic registers a user-scoped push token" do
    user_id = unique_id("dev")
    prepare_user(user_id)
    configure_ready_push_provider()

    assert {:ok, _reply, socket} = join_mobile(user_id, [])

    ref =
      Phoenix.ChannelTest.push(socket, "register_push", %{
        "token" => "fcm-user-token",
        "platform" => "android"
      })

    assert_reply ref, :ok, %{}, 1_000

    assert [
             %{token: "fcm-user-token", platform: "android", user_id: ^user_id}
           ] = Push.tokens_for_user(user_id)
  end

  test "mobile user topic rejects push registration when provider is not deliverable" do
    user_id = unique_id("dev")
    prepare_user(user_id)
    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.LogProvider)

    assert {:ok, _reply, socket} = join_mobile(user_id, [])

    ref =
      Phoenix.ChannelTest.push(socket, "register_push", %{
        "token" => "fcm-user-token",
        "platform" => "android"
      })

    assert_reply ref, :error, %{reason: "push_provider_unconfigured"}, 1_000
    assert Push.tokens_for_user(user_id) == []
  end

  test "workspace-scoped pairing token watches its paired workspace" do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)

    State.sync(%Workspace{
      id: workspace_id,
      name: "alpha",
      user: user_id,
      path: System.tmp_dir!()
    })

    UserObserver.connection_issue_changed(user_id, %{workspace_id: workspace_id, reason: :offline})

    assert [%{type: :connection_issue}] = UserObserver.snapshot(user_id).cards

    token =
      ChannelAuth.sign_pairing_token(
        %{id: user_id, email: "#{user_id}@local", role: :owner},
        workspace_id
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.MobileUserChannel, "mobile:user:me")

    assert reply.user_id == user_id
    assert reply.cards == []
    assert_push "cards_snapshot", %{cards: []}, 1_000

    Ledger.approval_requested(%{
      workspace_id: workspace_id,
      actor_id: "agent",
      run_id: "run-1",
      command_id: "compile"
    })

    assert_push "cards_snapshot", payload, 1_000
    assert Jason.encode!(payload)
    assert [card] = payload.cards
    assert card.type == "needs_review"
    assert card.workspace_id == workspace_id
    assert card.workspace_name == "alpha"

    assert card.action.route == %{
             type: "session_detail",
             workspace_id: workspace_id,
             session_id: "run-1"
           }
  end

  test "workspace-scoped pairing token cannot ask to watch another workspace" do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)

    token =
      ChannelAuth.sign_pairing_token(
        %{id: user_id, email: "#{user_id}@local", role: :owner},
        workspace_id
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.MobileUserChannel, "mobile:user:#{user_id}")

    ref =
      Phoenix.ChannelTest.push(socket, "watch_workspace", %{"workspace_id" => "other-workspace"})

    assert_reply ref, :error, %{reason: "workspace_scope_mismatch"}, 1_000

    assert_push "cards_snapshot", payload, 1_000
    assert [card] = payload.cards
    assert card.type == "connection_issue"
    assert card.workspace_id == "other-workspace"
    assert card.priority == "high"
    assert card.meta["reason"] == "token_revoked"
  end

  test "card_action approves a needs_review card through the run ledger", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    ref = Phoenix.ChannelTest.push(socket, "watch_workspace", %{"workspace_id" => workspace_id})
    assert_reply ref, :ok, _payload, 1_000

    Ledger.approval_requested(%{
      workspace_id: workspace_id,
      actor_id: "agent",
      run_id: run_id,
      command_id: "compile",
      metadata: %{approval_id: "approval-1"}
    })

    assert_push "cards_snapshot", %{cards: [card]}, 1_000
    assert card.type == "needs_review"
    assert card.meta["approval_id"] == "approval-1"
    assert card.meta["command_id"] == "compile"

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card.id,
        "action" => "approve"
      })

    assert_reply ref, :ok, %{status: "accepted", snapshot: %{cards: []}}, 1_000
    assert_push "cards_snapshot", %{cards: []}, 1_000

    assert ["run.approval_requested", "run.approval_granted"] =
             workspace_id
             |> Ledger.timeline_for(run_id)
             |> Enum.map(& &1.action)

    granted = workspace_id |> Ledger.timeline_for(run_id) |> List.last()
    assert granted.actor_id == user_id
    assert granted.metadata["approval_id"] == "approval-1"
    assert granted.metadata["card_id"] == card.id
    assert granted.metadata["mobile_action"] == "approve"
    assert granted.metadata["source"] == "mobile"
  end

  test "register_push stores a user-scoped token after workspace authorization", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    configure_ready_push_provider()

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    ref =
      Phoenix.ChannelTest.push(socket, "register_push", %{
        "workspace_id" => workspace_id,
        "token" => "device-token",
        "platform" => "ios"
      })

    assert_reply ref, :ok, %{}, 1_000

    assert [
             %{token: "device-token", platform: "ios", user_id: ^user_id}
           ] = Push.tokens_for(workspace_id)
  end

  test "register_push rejects workspace token when native platform config is missing", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.NativeProvider)
    Application.delete_env(:dev_ide, DevIDE.Push.APNSProvider)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    ref =
      Phoenix.ChannelTest.push(socket, "register_push", %{
        "workspace_id" => workspace_id,
        "token" => "device-token",
        "platform" => "ios"
      })

    assert_reply ref, :error, %{reason: "no_team_id"}, 1_000
    assert Push.tokens_for(workspace_id) == []
  end

  test "register_push respects pairing workspace scope", %{workspace_root: workspace_root} do
    user_id = unique_id("dev")
    paired_workspace_id = unique_id("ws")
    other_workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, paired_workspace_id, user_id)
    create_workspace(workspace_root, other_workspace_id, user_id)

    token =
      ChannelAuth.sign_pairing_token(
        %{id: user_id, email: "#{user_id}@local", role: :admin},
        paired_workspace_id
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.MobileUserChannel, "mobile:user:me")

    ref =
      Phoenix.ChannelTest.push(socket, "register_push", %{
        "workspace_id" => other_workspace_id,
        "token" => "device-token",
        "platform" => "ios"
      })

    assert_reply ref, :error, %{reason: "workspace_scope_mismatch"}, 1_000
    assert Push.tokens_for(other_workspace_id) == []
  end

  test "card_action request_changes denies with a bounded note", %{workspace_root: workspace_root} do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    deny_run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      command_id: "compile"
    })

    card_id = "needs_review:#{workspace_id}:#{run_id}"
    assert [%{id: ^card_id, type: :needs_review}] = UserObserver.snapshot(user_id).cards

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "request_changes",
        "payload" => %{"note" => "Please add the missing test."}
      })

    assert_reply ref, :ok, %{status: "accepted", snapshot: %{cards: []}}, 1_000

    assert [%{action: "run.approval_denied"} = denied] = Ledger.timeline_for(workspace_id, run_id)
    assert denied.metadata["mobile_action"] == "request_changes"
    assert denied.metadata["note"] == "Please add the missing test."

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: deny_run_id,
      review_count: 1,
      command_id: "compile"
    })

    deny_card_id = "needs_review:#{workspace_id}:#{deny_run_id}"
    assert [%{id: ^deny_card_id, type: :needs_review}] = UserObserver.snapshot(user_id).cards

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => deny_card_id,
        "action" => "deny"
      })

    assert_reply ref, :ok, %{status: "accepted", snapshot: %{cards: []}}, 1_000

    assert [%{action: "run.approval_denied"} = denied] =
             Ledger.timeline_for(workspace_id, deny_run_id)

    assert denied.metadata["mobile_action"] == "deny"
  end

  test "card_action rejects non-review cards and unsupported actions", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    UserObserver.in_progress_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: "run-1",
      command: "mix test"
    })

    assert [%{type: :in_progress}] = UserObserver.snapshot(user_id).cards

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "in_progress:#{workspace_id}:run-1",
        "action" => "approve"
      })

    assert_reply ref, :error, %{reason: "unsupported_card_type"}, 1_000

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "in_progress:#{workspace_id}:run-1",
        "action" => "archive"
      })

    assert_reply ref, :error, %{reason: "unsupported_action"}, 1_000
  end

  test "card_action re-authorizes the card workspace against pairing scope", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    paired_workspace_id = unique_id("ws")
    other_workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, paired_workspace_id, user_id)
    create_workspace(workspace_root, other_workspace_id, user_id)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: other_workspace_id,
      session_id: "run-1",
      review_count: 1
    })

    assert [%{type: :needs_review}] = UserObserver.snapshot(user_id).cards

    token =
      ChannelAuth.sign_pairing_token(
        %{id: user_id, email: "#{user_id}@local", role: :admin},
        paired_workspace_id
      )

    assert {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.UserSocket, %{"token" => token})

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.MobileUserChannel, "mobile:user:me")

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "needs_review:#{other_workspace_id}:run-1",
        "action" => "approve"
      })

    assert_reply ref, :error, %{reason: "workspace_scope_mismatch"}, 1_000
  end

  defp prepare_user(user_id) do
    {:ok, _pid} = UserObserver.ensure_started(user_id)
    :ok = UserObserver.clear(user_id)
  end

  defp join_mobile(user_id, opts) do
    role = Keyword.get(opts, :role)
    user = %{id: user_id, email: "#{user_id}@local", role: role}

    DevIdeWeb.UserSocket
    |> socket("users_socket:#{user_id}", %{current_user: user})
    |> Phoenix.Socket.assign(:current_user, user)
    |> subscribe_and_join(DevIdeWeb.MobileUserChannel, "mobile:user:me")
  end

  defp create_workspace(workspace_root, workspace_id, user_id) do
    path = Path.join(workspace_root, workspace_id)
    File.mkdir_p!(path)

    State.sync(%Workspace{
      id: workspace_id,
      name: workspace_id,
      user: user_id,
      path: path
    })
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp configure_ready_push_provider do
    Application.put_env(:dev_ide, :push_provider, DevIDE.Push.TestProvider)
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp restore_module_env(module, nil), do: Application.delete_env(:dev_ide, module)
  defp restore_module_env(module, value), do: Application.put_env(:dev_ide, module, value)
end
