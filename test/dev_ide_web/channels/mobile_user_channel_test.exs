defmodule DevIdeWeb.MobileUserChannelTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Audit
  alias DevIDE.Mobile.ActionOutcome
  alias DevIDE.Mobile.UserObserver
  alias DevIDE.Push
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIde.Repo
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

    # A non-review card simply does not declare the `approve` action, so the
    # generic dispatcher reports it as unsupported rather than a special-cased
    # card-type error.
    assert_reply ref, :error, %{reason: "unsupported_action"}, 1_000

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

  test "card_action rejects request_changes without a required note", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)
    card_id = seed_review_card(user_id, workspace_id, run_id)

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "request_changes"
      })

    assert_reply ref, :error, %{reason: "note_required"}, 1_000
    assert [%{id: ^card_id}] = UserObserver.snapshot(user_id).cards
    assert Ledger.timeline_for(workspace_id, run_id) == []
  end

  test "card_action replays the recorded outcome for a repeated request_id", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)
    card_id = seed_review_card(user_id, workspace_id, run_id)

    action = %{"card_id" => card_id, "action" => "approve", "request_id" => "req-1"}

    ref = Phoenix.ChannelTest.push(socket, "card_action", action)
    assert_reply ref, :ok, %{status: "accepted", idempotent: false}, 1_000

    # The card is now cleared; a retried submission still replays cleanly.
    ref = Phoenix.ChannelTest.push(socket, "card_action", action)
    assert_reply ref, :ok, %{status: "accepted", idempotent: true}, 1_000

    assert [%{action: "run.approval_granted"}] = Ledger.timeline_for(workspace_id, run_id)
  end

  test "card_action stamps device provenance into audit and the outcome row", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} =
             join_mobile(user_id,
               role: :admin,
               assigns: %{device_link_id: "dl-42", mobile_platform: "ios"}
             )

    card_id = seed_review_card(user_id, workspace_id, run_id)

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "approve"
      })

    assert_reply ref, :ok, %{status: "accepted"}, 1_000

    granted = workspace_id |> Ledger.timeline_for(run_id) |> List.last()
    assert granted.metadata["source"] == "mobile"
    assert granted.metadata["device_link_id"] == "dl-42"
    assert granted.metadata["platform"] == "ios"
    assert granted.metadata["action_id"] == "approve"

    outcome = Repo.get_by(ActionOutcome, card_id: card_id, status: "accepted")
    assert outcome.device_link_id == "dl-42"
    assert outcome.platform == "ios"
    assert outcome.action_id == "approve"
  end

  test "card_action allows a peer on another user's workspace (flat peer model)", %{
    workspace_root: workspace_root
  } do
    owner_id = unique_id("owner")
    viewer_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(viewer_id)
    # Workspace owned by a different user — flat model still authorizes peers.
    create_workspace(workspace_root, workspace_id, owner_id)

    assert {:ok, _reply, socket} = join_mobile(viewer_id, role: :member)
    card_id = seed_review_card(viewer_id, workspace_id, run_id)

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "approve"
      })

    assert_reply ref, :ok, %{}, 1_000
    assert Ledger.timeline_for(workspace_id, run_id) != []
  end

  test "card_action rejects a second device racing on an already-resolved card", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)
    card_id = seed_review_card(user_id, workspace_id, run_id)

    # Device A already recorded an accepted outcome for this card; its clear has
    # not yet reached this observer, so the card is still open here.
    {:ok, _} =
      %ActionOutcome{}
      |> ActionOutcome.changeset(%{
        request_id: "device-a",
        user_id: user_id,
        card_id: card_id,
        action_id: "approve",
        status: "accepted",
        result: %{}
      })
      |> Repo.insert()

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "approve",
        "request_id" => "device-b"
      })

    assert_reply ref, :error, %{reason: "card_already_resolved"}, 1_000
  end

  test "workspace_idle card renders a resume action and resumes without mutation", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    UserObserver.workspace_idle_changed(user_id, %{workspace_id: workspace_id, session_id: run_id})

    assert_push "cards_snapshot", payload, 1_000
    assert Jason.encode!(payload)
    assert [card] = payload.cards
    assert card.kind == "workspace_idle"
    assert card.status == "idle"
    assert [%{"id" => "resume", "route" => route}] = card.actions
    assert route.type == "session_detail"
    assert route.session_id == run_id

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card.id,
        "action" => "resume",
        "request_id" => "nav-1"
      })

    assert_reply ref, :ok, %{status: "accepted", idempotent: false, result: result}, 1_000
    assert result["session_id"] == run_id

    # Navigation performs no run mutation and does not resolve the idle card.
    assert Ledger.timeline_for(workspace_id, run_id) == []
    assert [%{type: :workspace_idle}] = UserObserver.snapshot(user_id).cards

    # A durable, non-locking navigation outcome was recorded for audit.
    outcome = Repo.get_by(ActionOutcome, card_id: card.id)
    assert outcome.status == "navigated"
    assert outcome.action_id == "resume"
    assert outcome.resource_id == workspace_id

    # Retried navigation with the same request_id replays idempotently.
    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card.id,
        "action" => "resume",
        "request_id" => "nav-1"
      })

    assert_reply ref, :ok, %{status: "accepted", idempotent: true}, 1_000
  end

  test "a recorded rejection does not block a corrected retry", %{workspace_root: workspace_root} do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)
    card_id = seed_review_card(user_id, workspace_id, run_id)

    # First attempt fails validation → a rejected outcome is recorded.
    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "request_changes"
      })

    assert_reply ref, :error, %{reason: "note_required"}, 1_000
    assert Repo.get_by(ActionOutcome, card_id: card_id, status: "rejected")

    # The corrected retry uses the SAME derived request_id and must NOT replay
    # the rejection — it re-evaluates and succeeds.
    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "request_changes",
        "payload" => %{"note" => "add the missing test"}
      })

    assert_reply ref, :ok, %{status: "accepted", idempotent: false}, 1_000
    assert [%{action: "run.approval_denied"}] = Ledger.timeline_for(workspace_id, run_id)
  end

  test "action outcomes are isolated per user (no cross-user replay)", %{
    workspace_root: workspace_root
  } do
    user_a = unique_id("a")
    user_b = unique_id("b")
    ws_a = unique_id("ws")
    ws_b = unique_id("ws")
    run = unique_id("run")
    prepare_user(user_a)
    prepare_user(user_b)
    create_workspace(workspace_root, ws_a, user_a)
    create_workspace(workspace_root, ws_b, user_b)

    assert {:ok, _r, socket_a} = join_mobile(user_a, role: :admin)
    assert {:ok, _r, socket_b} = join_mobile(user_b, role: :admin)

    card_a = seed_review_card(user_a, ws_a, run)
    card_b = seed_review_card(user_b, ws_b, run)
    shared = "shared-request-id"

    ref_a =
      Phoenix.ChannelTest.push(socket_a, "card_action", %{
        "card_id" => card_a,
        "action" => "approve",
        "request_id" => shared
      })

    assert_reply ref_a, :ok, %{status: "accepted", idempotent: false}, 1_000

    # User B reuses A's request_id on B's own card. It must be evaluated fresh,
    # never replayed from A's outcome.
    ref_b =
      Phoenix.ChannelTest.push(socket_b, "card_action", %{
        "card_id" => card_b,
        "action" => "approve",
        "request_id" => shared
      })

    assert_reply ref_b, :ok, %{status: "accepted", idempotent: false}, 1_000

    # Two independent outcomes for the same request_id, one per user.
    outcomes = Repo.all(ActionOutcome)
    assert length(outcomes) == 2
    assert Enum.all?(outcomes, &(&1.status == "accepted"))
    assert outcomes |> Enum.map(& &1.user_id) |> Enum.sort() == Enum.sort([user_a, user_b])
  end

  test "card_action rejects an action on a card the user no longer holds", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "needs_review:#{workspace_id}:already-gone",
        "action" => "approve"
      })

    assert_reply ref, :error, %{reason: "card_not_found"}, 1_000
  end

  test "agent_instruction refuses a workspace this device is not scoped to", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    other_workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    create_workspace(workspace_root, other_workspace_id, user_id)

    assert {:ok, _reply, socket} =
             join_mobile(user_id,
               role: :admin,
               assigns: %{pairing_workspace_id: workspace_id}
             )

    ref =
      Phoenix.ChannelTest.push(socket, "agent_instruction", %{
        "workspace_id" => other_workspace_id,
        "text" => "do something"
      })

    assert_reply ref, :error, %{reason: "workspace_scope_mismatch"}, 1_000
  end

  test "agent_instruction rejects an empty instruction", %{workspace_root: workspace_root} do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    ref =
      Phoenix.ChannelTest.push(socket, "agent_instruction", %{
        "workspace_id" => workspace_id,
        "text" => "   "
      })

    assert_reply ref, :error, %{reason: "empty_instruction"}, 1_000
  end

  test "agent_targets reports the addressable panes and the size limit", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    ref = Phoenix.ChannelTest.push(socket, "agent_targets", %{"workspace_id" => workspace_id})

    # No tmux session exists for this workspace in the test environment, so the
    # list is empty — the contract under test is the gate and the envelope.
    assert_reply ref, :ok, %{targets: [], max_bytes: max_bytes}, 1_000
    assert max_bytes > 0
  end

  test "request_changes hands the note to the agent pane; deny does not", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    deny_run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    session = seed_agent_pane(workspace_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      command_id: "mix deploy --prod"
    })

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "needs_review:#{workspace_id}:#{run_id}",
        "action" => "request_changes",
        "payload" => %{"note" => "Use a narrower scope."}
      })

    assert_reply ref, :ok, %{status: "accepted", result: result}, 1_000
    assert result["note_delivered"] == true

    assert_receive {:fake_tmux_paste_text, ^session, _pane, pasted, _opts}, 1_000
    assert pasted =~ "Use a narrower scope."
    # Server-authored framing tells the agent this was a rejection, not an
    # approval with commentary.
    assert pasted =~ "Changes requested from mobile"
    assert pasted =~ "mix deploy --prod"

    # The decision itself is still a denial in the ledger.
    assert [%{action: "run.approval_denied"} | _] = Ledger.timeline_for(workspace_id, run_id)

    # Deny is a full stop: its note (if any) is audit-only.
    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: deny_run_id,
      review_count: 1,
      command_id: "mix deploy --prod"
    })

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "needs_review:#{workspace_id}:#{deny_run_id}",
        "action" => "deny",
        "payload" => %{"note" => "No."}
      })

    assert_reply ref, :ok, %{status: "accepted", result: deny_result}, 1_000
    refute Map.has_key?(deny_result, "note_delivered")
    refute_receive {:fake_tmux_paste_text, _session, _pane, _text, _opts}, 200
  end

  test "a change request stands even when the agent pane is gone", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} = join_mobile(user_id, role: :admin)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      command_id: "compile"
    })

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => "needs_review:#{workspace_id}:#{run_id}",
        "action" => "request_changes",
        "payload" => %{"note" => "Please add the missing test."}
      })

    # Delivery is best effort; the decision is authoritative and must not fail
    # with it. The outcome records that the note did not land.
    assert_reply ref, :ok, %{status: "accepted", result: result}, 1_000
    assert result["note_delivered"] == false
    assert result["note_undelivered_reason"] == "agent_pane_not_found"

    assert [%{action: "run.approval_denied"} = denied] = Ledger.timeline_for(workspace_id, run_id)
    assert denied.metadata["note"] == "Please add the missing test."
  end

  # A role-marked agent pane in a tmux session named for this workspace, so
  # `AgentInstructions` can resolve a delivery target.
  defp seed_agent_pane(workspace_id) do
    session = DevIDE.Terminals.tmux_session_name(workspace_id, "agent")

    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    Application.put_env(:dev_ide, :tmux_adapter, TmuxCtl.Test.FakeAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "work",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%2",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: "/workspace",
          role: "agent"
        }
      ]
    })

    on_exit(fn ->
      restore_env(:tmux_adapter, prev_adapter)
      restore_fake(:fake_tmux_test_pid, prev_pid)
      restore_fake(:fake_tmux_windows, prev_windows)
      restore_fake(:fake_tmux_panes, prev_panes)
    end)

    session
  end

  defp restore_fake(key, nil), do: TmuxCtl.Test.FakeState.delete(key)
  defp restore_fake(key, value), do: TmuxCtl.Test.FakeState.put(key, value)

  defp prepare_user(user_id) do
    on_exit(fn -> UserObserver.stop(user_id) end)
    {:ok, _pid} = UserObserver.ensure_started(user_id)
    :ok = UserObserver.clear(user_id)
  end

  defp join_mobile(user_id, opts) do
    role = Keyword.get(opts, :role)
    user = %{id: user_id, email: "#{user_id}@local", role: role}

    DevIdeWeb.UserSocket
    |> socket("users_socket:#{user_id}", %{current_user: user})
    |> Phoenix.Socket.assign(:current_user, user)
    |> apply_test_assigns(Keyword.get(opts, :assigns, %{}))
    |> subscribe_and_join(DevIdeWeb.MobileUserChannel, "mobile:user:me")
  end

  defp apply_test_assigns(socket, assigns) do
    Enum.reduce(assigns, socket, fn {key, value}, acc ->
      Phoenix.Socket.assign(acc, key, value)
    end)
  end

  defp seed_review_card(user_id, workspace_id, run_id) do
    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      command_id: "compile"
    })

    "needs_review:#{workspace_id}:#{run_id}"
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
