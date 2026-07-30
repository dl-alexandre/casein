defmodule Casein.NotificationsTest do
  use Casein.DataCase, async: true

  alias Casein.Audit.Event
  alias Casein.Mobile.Card
  alias Casein.Notifications
  alias Casein.Notifications.Notification

  @now ~U[2026-07-04 20:30:00.000000Z]
  @later ~U[2026-07-04 20:35:00.000000Z]

  test "mobile attention policy ignores churn and dedupes origin-qualified outcomes" do
    working =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert :ignored = Notifications.deliver_mobile_card(working, now: @now)

    outcome =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          outcome: :failed
        },
        @now
      )

    assert {:ok, first, :created} = Notifications.deliver_mobile_card(outcome, now: @now)
    assert first.type == "mobile_attention"
    assert first.metadata["reason_code"] == "failure"
    assert first.metadata["required_decision"] == "Inspect failure"
    assert first.metadata["origin_id"] == Casein.Origin.id()
    refute Map.has_key?(first.metadata, "body")
    refute Map.has_key?(first.metadata, "output")

    assert {:ok, duplicate, :deduped} =
             Notifications.deliver_mobile_card(outcome, now: DateTime.add(@now, 1, :second))

    assert duplicate.id == first.id
    assert duplicate.occurrence_count == 2
  end

  test "clarification notification is actionable but never persists the question" do
    card =
      Card.clarification(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "Devbox",
          session_id: "agent-task-1",
          question: "Deploy with token=do-not-leak?",
          task_ref: %{type: "agent_task", id: "agent-task-1"},
          locator: %{tmux_session: "casein_ws-1_agent", pane: "%2", tab: "terminal"},
          clarification_event_id: Ecto.UUID.generate(),
          clarification_request_id: "clarification-request-1"
        },
        @now
      )

    assert {:ok, notification, :created} =
             Notifications.deliver_mobile_card(card, now: @now)

    assert notification.title == "Casein needs your attention"
    assert notification.body == "An agent is waiting for your response"
    assert notification.metadata["reason_code"] == "human_blocked"
    assert notification.metadata["required_decision"] == "Respond"
    refute inspect(notification) =~ "Deploy with"
    refute inspect(notification) =~ "do-not-leak"
  end

  test "deliver persists and broadcasts a durable notification" do
    :ok = Notifications.subscribe("dev")

    assert {:ok, %Notification{} = notification, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 session_id: "run-1",
                 type: :needs_review,
                 severity: :warning,
                 title: "Approval requested",
                 body: "Review required before work continues",
                 metadata: %{review_count: 2},
                 dedupe_key: "dev:needs_review:ws-1:run-1",
                 ttl_seconds: 3_600,
                 channels: [:in_app, :push],
                 default_delivery: %{push: true}
               },
               now: @now
             )

    assert notification.expires_at == DateTime.add(@now, 3_600, :second)
    assert notification.channels == ["in_app", "push"]
    assert notification.occurrence_count == 1
    assert notification.last_seen_at == @now
    assert notification.metadata == %{"review_count" => 2}
    assert notification.default_delivery == %{"push" => true}
    assert_receive {:notification_created, ^notification}, 1_000

    assert [%Notification{id: id}] = Notifications.list_for_user("dev")
    assert id == notification.id
    assert Notifications.unread_count("dev") == 1
  end

  test "deliver dedupes by user and dedupe key inside the configured window" do
    :ok = Notifications.subscribe("dev")

    attrs = %{
      user_id: "dev",
      workspace_id: "ws-1",
      type: "policy_blocked",
      severity: "warning",
      title: "Blocked by policy",
      dedupe_key: "dev:policy_blocked:ws-1:file",
      channels: ["in_app"]
    }

    assert {:ok, first, :created} =
             Notifications.deliver(attrs, dedupe_window_seconds: 60, now: @now)

    assert_receive {:notification_created, ^first}, 1_000

    assert {:ok, deduped, :deduped} =
             Notifications.deliver(attrs, dedupe_window_seconds: 60, now: @now)

    assert deduped.id == first.id
    assert deduped.occurrence_count == 2
    assert deduped.metadata["occurrence_count"] == 2
    assert_receive {:notification_updated, ^deduped}, 1_000
    refute_receive {:notification_created, _}, 100
    assert Repo.aggregate(Notification, :count) == 1
  end

  test "preferences filter channels and quiet hours suppress noisy delivery" do
    assert {:ok, _prefs} =
             Notifications.put_preferences("dev", %{
               settings: %{
                 "types" => %{
                   "policy_blocked" => %{"channels" => %{"push" => false, "in_app" => true}}
                 }
               },
               quiet_hours: %{"enabled" => true, "start" => "22:00", "end" => "08:00"}
             })

    attrs = %{
      user_id: "dev",
      workspace_id: "ws-1",
      type: "policy_blocked",
      severity: "warning",
      title: "Blocked by policy",
      channels: ["in_app", "push", "mobile"],
      default_delivery: %{"in_app" => true, "push" => true, "mobile" => true}
    }

    assert Notifications.effective_channels(attrs, now: ~U[2026-07-04 12:00:00.000000Z]) ==
             ["in_app", "mobile"]

    assert Notifications.effective_channels(attrs, now: ~U[2026-07-04 23:00:00.000000Z]) ==
             ["in_app"]
  end

  test "read and resolve lifecycle updates are scoped to the notification user" do
    :ok = Notifications.subscribe("dev")

    assert {:ok, notification, :created} =
             Notifications.deliver(%{
               user_id: "dev",
               workspace_id: "ws-1",
               type: "run_timed_out",
               severity: "warning",
               title: "Run timed out"
             })

    assert_receive {:notification_created, ^notification}, 1_000
    assert {:error, :not_found} = Notifications.mark_read(notification.id, "other", now: @later)

    assert {:ok, read} = Notifications.mark_read(notification.id, "dev", now: @later)
    assert read.read_at == @later
    assert_receive {:notification_updated, ^read}, 1_000
    assert Notifications.unread_count("dev") == 0

    assert {:ok, resolved} = Notifications.resolve(notification.id, "dev", now: @later)
    assert resolved.resolved_at == @later
  end

  test "mark_all_read/1 sets read_at only on unread+unresolved rows and returns the count" do
    :ok = Notifications.subscribe("dev")

    assert {:ok, unread_a, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 type: "needs_review",
                 severity: "warning",
                 title: "Unread A",
                 dedupe_key: "mark-all:a"
               },
               now: @now
             )

    assert {:ok, unread_b, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 type: "needs_review",
                 severity: "warning",
                 title: "Unread B",
                 dedupe_key: "mark-all:b"
               },
               now: @now
             )

    assert {:ok, already_read, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 type: "needs_review",
                 severity: "info",
                 title: "Already read",
                 dedupe_key: "mark-all:read"
               },
               now: @now
             )

    assert {:ok, already_read} =
             Notifications.mark_read(already_read.id, "dev", now: @now)

    assert {:ok, resolved, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 type: "needs_review",
                 severity: "warning",
                 title: "Resolved unread",
                 dedupe_key: "mark-all:resolved"
               },
               now: @now
             )

    assert {:ok, resolved} = Notifications.resolve(resolved.id, "dev", now: @now)
    refute is_nil(resolved.resolved_at)
    assert is_nil(resolved.read_at)

    assert {:ok, _other_user, :created} =
             Notifications.deliver(
               %{
                 user_id: "other",
                 workspace_id: "ws-1",
                 type: "needs_review",
                 severity: "warning",
                 title: "Other user",
                 dedupe_key: "mark-all:other"
               },
               now: @now
             )

    assert 2 = Notifications.mark_all_read("dev", now: @later)
    assert_receive {:notification_updated, :mark_all_read}, 1_000

    reloaded_a = Repo.get!(Notification, unread_a.id)
    reloaded_b = Repo.get!(Notification, unread_b.id)
    reloaded_read = Repo.get!(Notification, already_read.id)
    reloaded_resolved = Repo.get!(Notification, resolved.id)

    assert reloaded_a.read_at == @later
    assert reloaded_b.read_at == @later
    assert reloaded_read.read_at == @now
    assert is_nil(reloaded_resolved.read_at)
    assert reloaded_resolved.resolved_at == @now
    assert Notifications.unread_count("dev") == 0
    assert 0 = Notifications.mark_all_read("dev", now: @later)
  end

  test "alert audit events can be shaped into durable notification attrs" do
    event =
      Event.new(%{
        workspace_id: "ws-1",
        actor_id: "agent-7",
        action: "policy.blocked",
        target_type: "file",
        target_ref: "lib/auth.ex",
        decision: :deny,
        reason: :not_allowlisted,
        metadata: %{session_id: "run-1"}
      })

    attrs = Notifications.attrs_from_alert_event(event, "dev")

    assert attrs.user_id == "dev"
    assert attrs.workspace_id == "ws-1"
    assert attrs.session_id == "run-1"
    assert attrs.type == "policy_blocked"
    assert attrs.severity == "warning"
    assert attrs.title == "Blocked by policy"
    assert attrs.body == "not_allowlisted"
    assert attrs.channels == ["in_app", "push"]
    assert attrs.dedupe_window_seconds == 300
    assert attrs.source_type == "audit_event"
    assert attrs.source_id == event.id
    assert attrs.deep_link == "casein://session/ws-1"
    assert attrs.dedupe_key == "dev:policy_blocked:ws-1:lib/auth.ex"
    assert attrs.metadata["action"] == "policy.blocked"
    assert attrs.metadata["audit_metadata"] == %{session_id: "run-1"}
  end
end
