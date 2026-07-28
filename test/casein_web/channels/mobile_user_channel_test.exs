defmodule CaseinWeb.MobileUserChannelTest do
  use CaseinWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Casein.Audit
  alias Casein.Mobile.ActionOutcome
  alias Casein.Mobile.UserObserver
  alias Casein.Push
  alias Casein.Runs.Ledger
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter
  alias Casein.Repo
  alias CaseinWeb.ChannelAuth
  alias TmuxCtl.Test.FakeState

  @endpoint CaseinWeb.Endpoint

  setup do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "casein-mobile-user-channel-#{System.unique_integer([:positive])}"
      )

    prev_workspace_root = Application.get_env(:casein, :workspaces_root)
    prev_workspace_source = Application.get_env(:casein, :workspace_source)
    prev_push_provider = Application.get_env(:casein, :push_provider)
    prev_apns_config = Application.get_env(:casein, Casein.Push.APNSProvider)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_tmux_panes = FakeState.get(:fake_tmux_panes)
    prev_tmux_scrollback = FakeState.get(:fake_tmux_scrollback)
    prev_tmux_paste_error = FakeState.get(:fake_tmux_paste_error)
    prev_tmux_test_pid = FakeState.get(:fake_tmux_test_pid)
    File.mkdir_p!(workspace_root)
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)
    FakeState.put(:fake_tmux_panes, %{})
    FakeState.put(:fake_tmux_scrollback, %{})
    FakeState.delete(:fake_tmux_paste_error)
    FakeState.put(:fake_tmux_test_pid, self())

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
      restore_module_env(Casein.Push.APNSProvider, prev_apns_config)
      restore_env(:tmux_adapter, prev_tmux_adapter)
      restore_fake_state(:fake_tmux_panes, prev_tmux_panes)
      restore_fake_state(:fake_tmux_scrollback, prev_tmux_scrollback)
      restore_fake_state(:fake_tmux_paste_error, prev_tmux_paste_error)
      restore_fake_state(:fake_tmux_test_pid, prev_tmux_test_pid)
    end)

    {:ok, workspace_root: workspace_root}
  end

  test "joins only the authenticated user's mobile topic" do
    user_id = unique_id("dev")
    prepare_user(user_id)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:#{user_id}", %{
        current_user: %{id: user_id, email: "#{user_id}@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: user_id, email: "#{user_id}@local"})

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, CaseinWeb.MobileUserChannel, "mobile:user:me")

    assert reply.user_id == user_id
    assert Jason.encode!(reply)
    assert reply.cards == []

    other_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:#{user_id}", %{
        current_user: %{id: user_id, email: "#{user_id}@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: user_id, email: "#{user_id}@local"})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(
               other_socket,
               CaseinWeb.MobileUserChannel,
               "mobile:user:someone-else"
             )
  end

  test "mobile user me topic resolves to the authenticated socket user" do
    user_id = unique_id("dev")
    prepare_user(user_id)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:#{user_id}", %{
        current_user: %{id: user_id, email: "#{user_id}@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: user_id, email: "#{user_id}@local"})

    assert {:ok, reply, joined_socket} =
             subscribe_and_join(socket, CaseinWeb.MobileUserChannel, "mobile:user:me")

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
    Application.put_env(:casein, :push_provider, Casein.Push.LogProvider)

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

    assert {:ok, socket} = Phoenix.ChannelTest.connect(CaseinWeb.UserSocket, %{"token" => token})

    assert {:ok, reply, joined_socket} =
             subscribe_and_join(socket, CaseinWeb.MobileUserChannel, "mobile:user:me")

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
    assert card.attention["priority"] == "critical"
    assert card.attention["reason_code"] == "review_requested"
    assert card.attention["required_decision"] == "Review"
    assert card.attention["identity"] =~ reply.origin.id

    assert card.action.route == %{
             type: "session_detail",
             workspace_id: workspace_id,
             session_id: "run-1"
           }

    ref =
      Phoenix.ChannelTest.push(joined_socket, "attention_viewed", %{
        "origin_id" => "tampered-origin",
        "card_id" => card.id,
        "attention_key" => card.attention["key"],
        "through_marker" => 1
      })

    assert_reply ref, :error, %{reason: "attention_scope_mismatch"}, 1_000
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

    assert {:ok, socket} = Phoenix.ChannelTest.connect(CaseinWeb.UserSocket, %{"token" => token})

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, CaseinWeb.MobileUserChannel, "mobile:user:#{user_id}")

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

  test "authoritative card exposes a sanitized bounded intervention and exact PWA link", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    {tmux_session, pane_id} = seed_intervention_target(workspace_id)

    FakeState.put(:fake_tmux_scrollback, %{
      {tmux_session, pane_id} =>
        "starting\nTOKEN=super-secret\n\e[31mNeeds your answer\e[0m\n" <>
          String.duplicate("\n", 30)
    })

    assert {:ok, _reply, _socket} = join_mobile(user_id, role: :admin)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      locator: %{tmux_session: tmux_session, pane: pane_id, window: "@1"}
    })

    assert_push "cards_snapshot", %{cards: [card]}, 1_000
    assert card.intervention["version"] == 1
    assert card.intervention["target"] == %{"role" => "agent"}
    assert card.intervention["recent_output"] =~ "TOKEN=[REDACTED]"
    refute card.intervention["recent_output"] =~ "super-secret"
    assert card.intervention["pwa_url"] =~ "/workspaces/#{workspace_id}?"
    assert card.intervention["pwa_url"] =~ "session=#{run_id}"
    assert card.intervention["pwa_url"] =~ "tmux_session=#{tmux_session}"
    assert card.intervention["pwa_url"] =~ "pane=%252"
    assert Enum.any?(card.actions, &(&1["id"] == "follow_up"))
  end

  test "authoritative card exposes bounded evidence and omits raw evidence fields", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    file = Path.join([workspace_root, workspace_id, "lib", "safe.ex"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "defmodule Safe, do: :ok")

    assert {:ok, _reply, _socket} = join_mobile(user_id, role: :admin)

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: "run-evidence",
      review_count: 1,
      files_changed: ["lib/safe.ex", "../outside"],
      diff_preview: "- token=secret-value\n+ token=safe-value",
      locator: %{pane: "%2", tab: "diff"}
    })

    assert_push "cards_snapshot", %{cards: [card]}, 1_000
    assert card.evidence["version"] == 1
    assert card.evidence["changed_files"]["files"] == ["lib/safe.ex"]
    assert card.evidence["diff"]["excerpt"] =~ "token=[REDACTED]"
    assert [%{"kind" => "diff", "url" => diff_url}] = card.evidence["links"]
    assert diff_url =~ "/workspaces/#{workspace_id}?"
    assert diff_url =~ "tab=diff"
    assert diff_url =~ "pane=%252"
    refute Map.has_key?(card.meta, "diff_preview")
    refute Map.has_key?(card.meta, "files_changed")
    refute Map.has_key?(card.context, "diff_preview")
    refute Map.has_key?(card.context, "files_changed")
    refute Jason.encode!(card) =~ "secret-value"
  end

  test "follow-up revalidates the exact agent pane and duplicate request ids paste once", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    {tmux_session, pane_id} = seed_intervention_target(workspace_id)
    FakeState.put(:fake_tmux_scrollback, %{{tmux_session, pane_id} => "Waiting for guidance"})

    assert {:ok, _reply, socket} =
             join_mobile(user_id,
               role: :admin,
               assigns: %{mobile_origin_id: "origin-local", mobile_platform: "ios"}
             )

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      locator: %{tmux_session: tmux_session, pane: pane_id}
    })

    assert_push "cards_snapshot", %{cards: [card]}, 1_000

    payload = %{
      "card_id" => card.id,
      "action" => "follow_up",
      "origin_id" => "origin-local",
      "request_id" => "follow-up-once",
      "payload" => %{"message" => "Please run the focused test."}
    }

    ref = Phoenix.ChannelTest.push(socket, "card_action", payload)
    assert_reply ref, :ok, %{status: "accepted", idempotent: false}, 1_000

    assert_receive {:fake_tmux_paste_text, ^tmux_session, ^pane_id,
                    "Please run the focused test.", [target: ^pane_id, submit: true]}

    ref = Phoenix.ChannelTest.push(socket, "card_action", payload)
    assert_reply ref, :ok, %{status: "accepted", idempotent: true}, 1_000
    refute_receive {:fake_tmux_paste_text, ^tmux_session, ^pane_id, _, _}, 100

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        payload
        | "request_id" => "follow-up-twice",
          "payload" => %{"message" => "This second message must not be sent."}
      })

    assert_reply ref, :error, %{reason: "card_already_intervened"}, 1_000
    refute_receive {:fake_tmux_paste_text, ^tmux_session, ^pane_id, _, _}, 100

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card.id,
        "action" => "approve",
        "origin_id" => "origin-local",
        "request_id" => "approve-after-follow-up",
        "payload" => %{}
      })

    assert_reply ref, :ok, %{status: "accepted", idempotent: false}, 1_000

    assert %{status: "accepted", result: result} =
             Repo.get_by!(ActionOutcome, user_id: user_id, request_id: "follow-up-once")

    refute Map.has_key?(result, "message")
    refute Map.has_key?(result, "output")

    audit =
      workspace_id
      |> Audit.recent_for(20)
      |> Enum.find(&(&1.action == "mobile.intervention"))

    assert audit.metadata["outcome"] == "succeeded"
    refute Map.has_key?(audit.metadata, "message")
    refute Map.has_key?(audit.metadata, "output")
  end

  test "tampered origin and replaced or non-agent pane cannot mutate", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    run_id = unique_id("run")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    {tmux_session, pane_id} = seed_intervention_target(workspace_id)
    FakeState.put(:fake_tmux_scrollback, %{{tmux_session, pane_id} => "Need input"})

    assert {:ok, _reply, socket} =
             join_mobile(user_id,
               role: :admin,
               assigns: %{mobile_origin_id: "trusted-origin"}
             )

    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: run_id,
      review_count: 1,
      locator: %{tmux_session: tmux_session, pane: pane_id}
    })

    assert_push "cards_snapshot", %{cards: [card]}, 1_000

    tampered = %{
      "card_id" => card.id,
      "action" => "follow_up",
      "origin_id" => "unknown-origin",
      "request_id" => "tampered-origin",
      "payload" => %{"message" => "Do not send"}
    }

    ref = Phoenix.ChannelTest.push(socket, "card_action", tampered)
    assert_reply ref, :error, %{reason: "origin_mismatch"}, 1_000
    refute_receive {:fake_tmux_paste_text, _, _, _, _}, 100

    FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{id: pane_id, window_id: "@1", active: true, role: "operator"},
        %{id: "%3", window_id: "@1", active: false, role: "agent"}
      ]
    })

    replaced = %{tampered | "origin_id" => "trusted-origin", "request_id" => "replaced-pane"}
    ref = Phoenix.ChannelTest.push(socket, "card_action", replaced)
    assert_reply ref, :error, %{reason: "intervention_unavailable"}, 1_000
    refute_receive {:fake_tmux_paste_text, _, _, _, _}, 100

    FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{id: "%3", window_id: "@1", active: true, role: "agent"}
      ]
    })

    stale = %{replaced | "request_id" => "stale-pane"}
    ref = Phoenix.ChannelTest.push(socket, "card_action", stale)
    assert_reply ref, :error, %{reason: "intervention_unavailable"}, 1_000
    refute_receive {:fake_tmux_paste_text, _, _, _, _}, 100
  end

  test "failed delivery is fail-closed and a new request can retry after reconnect", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    {tmux_session, pane_id} = seed_intervention_target(workspace_id)
    FakeState.put(:fake_tmux_scrollback, %{{tmux_session, pane_id} => "Need input"})

    assert {:ok, _reply, socket} =
             join_mobile(user_id,
               role: :admin,
               assigns: %{mobile_origin_id: "origin-local"}
             )

    card_id = seed_intervention_card(user_id, workspace_id, tmux_session, pane_id)
    assert_push "cards_snapshot", %{cards: [_card]}, 1_000
    FakeState.put(:fake_tmux_paste_error, :disconnected)

    failed = %{
      "card_id" => card_id,
      "action" => "follow_up",
      "origin_id" => "origin-local",
      "request_id" => "failed-delivery",
      "payload" => %{"message" => "Please continue."}
    }

    ref = Phoenix.ChannelTest.push(socket, "card_action", failed)
    assert_reply ref, :error, %{reason: "intervention_delivery_failed"}, 1_000

    ref = Phoenix.ChannelTest.push(socket, "card_action", failed)
    assert_reply ref, :error, %{reason: "intervention_failed"}, 1_000

    FakeState.delete(:fake_tmux_paste_error)
    retry = %{failed | "request_id" => "retry-after-reconnect"}
    ref = Phoenix.ChannelTest.push(socket, "card_action", retry)
    assert_reply ref, :ok, %{status: "accepted", idempotent: false}, 1_000
  end

  test "follow-up rejects oversized input before terminal mutation", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)
    {tmux_session, pane_id} = seed_intervention_target(workspace_id)
    FakeState.put(:fake_tmux_scrollback, %{{tmux_session, pane_id} => "Need input"})

    assert {:ok, _reply, socket} =
             join_mobile(user_id, role: :admin, assigns: %{mobile_origin_id: "origin-local"})

    card_id = seed_intervention_card(user_id, workspace_id, tmux_session, pane_id)
    assert_push "cards_snapshot", %{cards: [_card]}, 1_000

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "follow_up",
        "origin_id" => "origin-local",
        "request_id" => "too-long",
        "payload" => %{"message" => String.duplicate("x", 281)}
      })

    assert_reply ref, :error, %{reason: "message_too_long"}, 1_000
    refute_receive {:fake_tmux_paste_text, _, _, _, _}, 100

    ref =
      Phoenix.ChannelTest.push(socket, "card_action", %{
        "card_id" => card_id,
        "action" => "follow_up",
        "origin_id" => "origin-local",
        "request_id" => "terminal-control",
        "payload" => %{"message" => "continue\e[31m"}
      })

    assert_reply ref, :error, %{reason: "message_invalid_characters"}, 1_000
    refute_receive {:fake_tmux_paste_text, _, _, _, _}, 100
  end

  test "mobile observation accepts only bounded metadata and trusted workspace", %{
    workspace_root: workspace_root
  } do
    user_id = unique_id("dev")
    workspace_id = unique_id("ws")
    prepare_user(user_id)
    create_workspace(workspace_root, workspace_id, user_id)

    assert {:ok, _reply, socket} =
             join_mobile(user_id,
               role: :admin,
               assigns: %{mobile_origin_id: "origin-local", mobile_platform: "android"}
             )

    ref =
      Phoenix.ChannelTest.push(socket, "mobile_observation", %{
        "event" => "locator_fallback",
        "outcome" => "succeeded",
        "fallback_level" => "workspace",
        "stale_age_bucket" => "under_1h",
        "workspace_id" => workspace_id,
        "card_id" => "card-1",
        "message" => "must be discarded",
        "output" => "must be discarded"
      })

    assert_reply ref, :ok, %{}, 1_000

    event =
      workspace_id
      |> Audit.recent_for(10)
      |> Enum.find(&(&1.action == "mobile.locator_fallback"))

    assert event.metadata["origin_id"] == "origin-local"
    assert event.metadata["fallback_level"] == "workspace"
    refute Map.has_key?(event.metadata, "message")
    refute Map.has_key?(event.metadata, "output")

    ref =
      Phoenix.ChannelTest.push(socket, "mobile_observation", %{
        "event" => "attention_action",
        "outcome" => "desktop_required",
        "awareness_latency_bucket" => "under_1m",
        "time_to_action_bucket" => "under_5m",
        "action_kind" => "pwa",
        "stale_age_bucket" => "under_1h",
        "workspace_id" => workspace_id,
        "card_id" => "card-1",
        "message" => "must also be discarded",
        "terminal_output" => "must also be discarded"
      })

    assert_reply ref, :ok, %{}, 1_000

    event =
      workspace_id
      |> Audit.recent_for(10)
      |> Enum.find(&(&1.action == "mobile.attention_action"))

    assert event.metadata["awareness_latency_bucket"] == "under_1m"
    assert event.metadata["time_to_action_bucket"] == "under_5m"
    assert event.metadata["action_kind"] == "pwa"
    refute Map.has_key?(event.metadata, "message")
    refute Map.has_key?(event.metadata, "terminal_output")

    ref =
      Phoenix.ChannelTest.push(socket, "mobile_observation", %{
        "event" => "raw_terminal_output",
        "outcome" => "succeeded"
      })

    assert_reply ref, :error, %{reason: "invalid_observation"}, 1_000
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

    Application.put_env(:casein, :push_provider, Casein.Push.NativeProvider)
    Application.delete_env(:casein, Casein.Push.APNSProvider)

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

    assert {:ok, socket} = Phoenix.ChannelTest.connect(CaseinWeb.UserSocket, %{"token" => token})

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, CaseinWeb.MobileUserChannel, "mobile:user:me")

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

    assert {:ok, socket} = Phoenix.ChannelTest.connect(CaseinWeb.UserSocket, %{"token" => token})

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, CaseinWeb.MobileUserChannel, "mobile:user:me")

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

    observation =
      workspace_id
      |> Audit.recent_for(20)
      |> Enum.find(&(&1.action == "mobile.attention_action"))

    assert observation.metadata["outcome"] == "succeeded"
    assert observation.metadata["action_kind"] == "review"

    assert observation.metadata["time_to_action_bucket"] in ~w(under_10s under_1m under_5m under_1h over_1h)

    refute Map.has_key?(observation.metadata, "note")
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

  defp prepare_user(user_id) do
    on_exit(fn -> UserObserver.stop(user_id) end)
    {:ok, _pid} = UserObserver.ensure_started(user_id)
    :ok = UserObserver.clear(user_id)
  end

  defp join_mobile(user_id, opts) do
    role = Keyword.get(opts, :role)
    user = %{id: user_id, email: "#{user_id}@local", role: role}

    CaseinWeb.UserSocket
    |> socket("users_socket:#{user_id}", %{current_user: user})
    |> Phoenix.Socket.assign(:current_user, user)
    |> apply_test_assigns(Keyword.get(opts, :assigns, %{}))
    |> subscribe_and_join(CaseinWeb.MobileUserChannel, "mobile:user:me")
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

  defp seed_intervention_card(user_id, workspace_id, tmux_session, pane_id) do
    UserObserver.needs_review_changed(user_id, %{
      workspace_id: workspace_id,
      session_id: "run-intervene",
      review_count: 1,
      locator: %{tmux_session: tmux_session, pane: pane_id}
    })

    "needs_review:#{workspace_id}:run-intervene"
  end

  defp seed_intervention_target(workspace_id) do
    tmux_session = Casein.Terminals.tmux_session_name(workspace_id, "agent")
    pane_id = "%2"

    FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{id: "%1", window_id: "@1", active: true, role: "operator"},
        %{id: pane_id, window_id: "@1", active: false, role: "agent"},
        %{id: "%3", window_id: "@1", active: false, role: "verify"}
      ]
    })

    {tmux_session, pane_id}
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
    Application.put_env(:casein, :push_provider, Casein.Push.TestProvider)
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)

  defp restore_module_env(module, nil), do: Application.delete_env(:casein, module)
  defp restore_module_env(module, value), do: Application.put_env(:casein, module, value)

  defp restore_fake_state(key, nil), do: FakeState.delete(key)
  defp restore_fake_state(key, value), do: FakeState.put(key, value)
end
