defmodule DevIDE.NotificationsTest do
  use DevIde.DataCase, async: true

  alias DevIDE.Audit.Event
  alias DevIDE.Notifications
  alias DevIDE.Notifications.Notification

  @now ~U[2026-07-04 20:30:00.000000Z]
  @later ~U[2026-07-04 20:35:00.000000Z]

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
    refute_receive {:notification_created, _}, 100
    assert Repo.aggregate(Notification, :count) == 1
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
    assert attrs.source_type == "audit_event"
    assert attrs.source_id == event.id
    assert attrs.deep_link == "devide://session/ws-1"
    assert attrs.dedupe_key == "dev:policy_blocked:ws-1:lib/auth.ex"
    assert attrs.metadata["action"] == "policy.blocked"
    assert attrs.metadata["audit_metadata"] == %{session_id: "run-1"}
  end
end
