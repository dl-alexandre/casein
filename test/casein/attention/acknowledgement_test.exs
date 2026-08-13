defmodule Casein.Attention.AcknowledgementTest do
  use Casein.DataCase, async: false

  import Ecto.Query

  alias Casein.Attention.Acknowledgement
  alias Casein.Mobile.{AttentionCursor, AttentionInbox, Card}
  alias Casein.Notifications
  alias Casein.Repo

  @now ~U[2026-08-08 12:00:00.000000Z]
  @later ~U[2026-08-08 12:05:00.000000Z]
  @origin "origin-ack-test"

  setup do
    previous = Application.get_env(:casein, :mobile_attention_store_enabled)
    Application.put_env(:casein, :mobile_attention_store_enabled, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:casein, :mobile_attention_store_enabled)
      else
        Application.put_env(:casein, :mobile_attention_store_enabled, previous)
      end
    end)

    :ok
  end

  test "SEEN and RESOLVED are distinct" do
    subject = Acknowledgement.card_subject("ws-1:session:run-1", @origin)

    assert {:ok, seen} =
             Acknowledgement.mark_seen("dev", subject, now: @now, sync_notifications: false)

    assert Acknowledgement.seen?("dev", subject)
    refute Acknowledgement.resolved?("dev", subject)
    assert Acknowledgement.open?("dev", subject)
    assert seen.viewed_at == @now
    assert is_nil(seen.resolved_at)

    assert {:ok, resolved} =
             Acknowledgement.mark_resolved("dev", subject,
               now: @later,
               sync_notifications: false
             )

    assert Acknowledgement.resolved?("dev", subject)
    refute Acknowledgement.open?("dev", subject)
    assert resolved.resolved_at == @later
    assert Acknowledgement.seen?("dev", subject)
  end

  test "acknowledgement is per-user" do
    subject = Acknowledgement.card_subject("ws-1:session:run-1", @origin)

    assert {:ok, _} =
             Acknowledgement.mark_seen("alice", subject, now: @now, sync_notifications: false)

    assert Acknowledgement.seen?("alice", subject)
    refute Acknowledgement.seen?("bob", subject)
  end

  test "phone mark_viewed settles drawer notification for the same card subject" do
    origin_id = Casein.Origin.id()

    card =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          outcome: :failed
        },
        @now
      )

    assert {:ok, notification, :created} =
             Notifications.deliver_mobile_card(card, now: @now)

    assert is_nil(notification.read_at)
    assert Notifications.unread_count("dev") == 1
    assert notification.metadata["origin_id"] == origin_id

    attention_key = AttentionInbox.key(card)

    assert {:ok, transition} =
             AttentionInbox.record_card(card, "run.failed",
               origin_id: origin_id,
               event_id: "evt-fail-1",
               occurred_at: @now
             )

    assert {:ok, _cursor} =
             AttentionInbox.mark_viewed("dev", origin_id, attention_key, transition.id,
               now: @later
             )

    reloaded = Repo.get!(Casein.Notifications.Notification, notification.id)
    assert reloaded.read_at
    assert Notifications.unread_count("dev") == 0

    subject = Acknowledgement.card_subject(attention_key, origin_id)
    assert Acknowledgement.seen?("dev", subject)
    refute Acknowledgement.resolved?("dev", subject)
  end

  test "drawer mark_read settles phone since_viewed for the same card subject" do
    card =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "run-1",
          outcome: :failed
        },
        @now
      )

    assert {:ok, notification, :created} =
             Notifications.deliver_mobile_card(card, now: @now)

    attention_key = AttentionInbox.key(card)
    origin_id = notification.metadata["origin_id"] || Casein.Origin.id()

    assert {:ok, _t1} =
             AttentionInbox.record_card(card, "run.failed",
               origin_id: origin_id,
               event_id: "evt-fail-drawer",
               occurred_at: @now
             )

    before = AttentionInbox.project_many("dev", origin_id, [card])[card.id]
    assert before.since_viewed.count >= 1

    assert {:ok, read} = Notifications.mark_read(notification.id, "dev", now: @later)
    assert read.read_at == @later

    after_proj = AttentionInbox.project_many("dev", origin_id, [card])[card.id]
    assert after_proj.since_viewed.count == 0

    subject = Acknowledgement.subject_for_notification(notification)
    assert subject.kind == :card
    assert subject.id == attention_key
    assert Acknowledgement.seen?("dev", subject)
  end

  test "drawer resolve marks RESOLVED on the shared subject" do
    assert {:ok, notification, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 session_id: "run-9",
                 type: "mobile_attention",
                 severity: "warning",
                 title: "Needs you",
                 metadata: %{
                   "attention_key" => "ws-1:session:run-9",
                   "origin_id" => @origin
                 },
                 channels: ["in_app"]
               },
               now: @now
             )

    assert {:ok, resolved} = Notifications.resolve(notification.id, "dev", now: @later)
    assert resolved.resolved_at == @later
    assert resolved.read_at

    subject = Acknowledgement.card_subject("ws-1:session:run-9", @origin)
    assert Acknowledgement.resolved?("dev", subject)
    assert Acknowledgement.seen?("dev", subject)
  end

  test "session-window SEEN settles linked session card and notifications" do
    assert {:ok, notification, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 session_id: "sid-1",
                 type: "mobile_attention",
                 severity: "info",
                 title: "Agent idle",
                 metadata: %{
                   "attention_key" => "ws-1:session:sid-1",
                   "origin_id" => @origin
                 },
                 channels: ["in_app"]
               },
               now: @now
             )

    assert is_nil(notification.read_at)

    assert {:ok, _} =
             Acknowledgement.mark_session_window_seen("dev", "ws-1", "sid-1", "@1",
               now: @later,
               origin_id: @origin
             )

    window = Acknowledgement.session_window_subject("ws-1", "sid-1", "@1", @origin)
    card = Acknowledgement.card_subject("ws-1:session:sid-1", @origin)

    assert Acknowledgement.seen?("dev", window)
    assert Acknowledgement.seen?("dev", card)

    reloaded = Repo.get!(Casein.Notifications.Notification, notification.id)
    assert reloaded.read_at
  end

  test "lower concurrent SEEN marker cannot reset a higher watermark" do
    card =
      Card.in_progress(
        %{user_id: "dev", workspace_id: "ws-1", session_id: "run-1"},
        @now
      )

    assert {:ok, first} =
             AttentionInbox.record_card(card, "run.started",
               origin_id: @origin,
               event_id: "e1"
             )

    assert {:ok, second} =
             AttentionInbox.record_card(
               Card.needs_review(
                 %{
                   user_id: "dev",
                   workspace_id: "ws-1",
                   session_id: "run-1",
                   review_count: 1
                 },
                 @later
               ),
               "run.approval_requested",
               origin_id: @origin,
               event_id: "e2"
             )

    key = AttentionInbox.key(card)

    assert {:ok, high} =
             Acknowledgement.mark_card_seen_through("dev", @origin, key, second.id, now: @later)

    assert high.through_transition_id == second.id

    assert {:ok, still} =
             Acknowledgement.mark_card_seen_through("dev", @origin, key, first.id, now: @now)

    assert still.through_transition_id == second.id
  end

  test "backfill_from_notifications preserves read/resolved without mass-unread" do
    assert {:ok, read_n, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 type: "info",
                 severity: "info",
                 title: "Already read",
                 metadata: %{"attention_key" => "ws-bf:session:a", "origin_id" => @origin},
                 channels: ["in_app"]
               },
               now: @now
             )

    assert {:ok, _} = Notifications.mark_read(read_n.id, "dev", now: @now)

    assert {:ok, resolved_n, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 type: "info",
                 severity: "info",
                 title: "Already resolved",
                 metadata: %{"attention_key" => "ws-bf:session:b", "origin_id" => @origin},
                 channels: ["in_app"]
               },
               now: @now
             )

    assert {:ok, _} = Notifications.resolve(resolved_n.id, "dev", now: @later)

    # Simulate pre-ack era: wipe ack rows, leave notification lifecycle.
    Repo.delete_all(AttentionCursor)

    refute Acknowledgement.seen?(
             "dev",
             Acknowledgement.card_subject("ws-bf:session:a", @origin)
           )

    stats = Acknowledgement.backfill_from_notifications(now: @later)
    assert stats.seen >= 2
    assert stats.resolved >= 1

    assert Acknowledgement.seen?(
             "dev",
             Acknowledgement.card_subject("ws-bf:session:a", @origin)
           )

    assert Acknowledgement.resolved?(
             "dev",
             Acknowledgement.card_subject("ws-bf:session:b", @origin)
           )

    # Re-run is idempotent and does not clear SEEN.
    stats2 = Acknowledgement.backfill_from_notifications(now: @later)
    assert stats2.seen >= 2

    assert Acknowledgement.seen?(
             "dev",
             Acknowledgement.card_subject("ws-bf:session:a", @origin)
           )
  end

  test "legacy card cursor rows remain SEEN after subject_kind default" do
    # Insert as the schema does post-migration (default subject_kind card).
    {:ok, cursor} =
      %AttentionCursor{}
      |> AttentionCursor.changeset(%{
        user_id: "dev",
        origin_id: @origin,
        subject_kind: "card",
        card_id: "ws-legacy:session:x",
        through_transition_id: 42,
        viewed_at: @now
      })
      |> Repo.insert()

    subject = Acknowledgement.card_subject("ws-legacy:session:x", @origin)
    assert Acknowledgement.seen?("dev", subject)
    assert Acknowledgement.seen_through?("dev", subject, 42)
    assert cursor.subject_kind == "card"
  end

  test "seen_quiet_window_keys reports SEEN windows and session cards; missing stays unseen" do
    origin_id = Casein.Origin.id()
    keys = [{"sid-a", "@1"}, {"sid-b", "@2"}, {"sid-c", "@3"}]

    assert Acknowledgement.seen_quiet_window_keys("dev", "ws-1", keys, origin_id: origin_id) ==
             MapSet.new()

    assert {:ok, _} =
             Acknowledgement.mark_session_window_seen("dev", "ws-1", "sid-a", "@1",
               now: @now,
               origin_id: origin_id,
               sync_notifications: false
             )

    assert {:ok, _} =
             Acknowledgement.mark_seen(
               "dev",
               Acknowledgement.card_subject("ws-1:session:sid-b", origin_id),
               now: @now,
               sync_notifications: false
             )

    seen =
      Acknowledgement.seen_quiet_window_keys("dev", "ws-1", keys, origin_id: origin_id)

    assert MapSet.member?(seen, {"sid-a", "@1"})
    assert MapSet.member?(seen, {"sid-b", "@2"})
    refute MapSet.member?(seen, {"sid-c", "@3"})
  end

  test "phone mark_viewed settles session-rail quiet keys for the same session card" do
    origin_id = Casein.Origin.id()

    card =
      Card.outcome(
        %{
          user_id: "dev",
          workspace_id: "ws-1",
          session_id: "sid-rail",
          outcome: :failed
        },
        @now
      )

    assert {:ok, transition} =
             AttentionInbox.record_card(card, "run.failed",
               origin_id: origin_id,
               event_id: "evt-rail-1",
               occurred_at: @now
             )

    attention_key = AttentionInbox.key(card)

    keys_before =
      Acknowledgement.seen_quiet_window_keys(
        "dev",
        "ws-1",
        [{"sid-rail", "@1"}],
        origin_id: origin_id
      )

    refute MapSet.member?(keys_before, {"sid-rail", "@1"})

    assert {:ok, _} =
             AttentionInbox.mark_viewed("dev", origin_id, attention_key, transition.id,
               now: @later
             )

    keys_after =
      Acknowledgement.seen_quiet_window_keys(
        "dev",
        "ws-1",
        [{"sid-rail", "@1"}],
        origin_id: origin_id
      )

    assert MapSet.member?(keys_after, {"sid-rail", "@1"})
  end

  test "notification sync matches in SQL and stays O(1) updates under noise (#922)" do
    # BEFORE (#922): matching_notifications loaded every row for the user and
    # filtered metadata in Elixir, then per-row Repo.update. With N noise rows
    # that was O(N) decode + O(matches) updates on every terminal-window click.
    # AFTER: one update_all with SQL subject match + open-row filter.
    noise = 80

    for i <- 1..noise do
      assert {:ok, _n, :created} =
               Notifications.deliver(
                 %{
                   user_id: "dev",
                   workspace_id: "ws-noise-#{i}",
                   session_id: "noise-#{i}",
                   type: "mobile_attention",
                   severity: "info",
                   title: "noise #{i}",
                   metadata: %{
                     "attention_key" => "ws-noise-#{i}:session:noise-#{i}",
                     "origin_id" => @origin
                   },
                   channels: ["in_app"]
                 },
                 now: @now
               )
    end

    assert {:ok, target, :created} =
             Notifications.deliver(
               %{
                 user_id: "dev",
                 workspace_id: "ws-1",
                 session_id: "sid-hot",
                 type: "mobile_attention",
                 severity: "info",
                 title: "hot path",
                 metadata: %{
                   "attention_key" => "ws-1:session:sid-hot",
                   "origin_id" => @origin
                 },
                 channels: ["in_app"]
               },
               now: @now
             )

    assert is_nil(target.read_at)

    parent = self()
    handler_id = "ack-922-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:casein, :repo, :query],
        fn _event, measurements, meta, _ ->
          send(parent, {:repo_query, measurements, meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {usec, {:ok, _}} =
      :timer.tc(fn ->
        Acknowledgement.mark_session_window_seen("dev", "ws-1", "sid-hot", "@1",
          now: @later,
          origin_id: @origin
        )
      end)

    queries =
      Stream.repeatedly(fn ->
        receive do
          {:repo_query, measurements, meta} -> {measurements, meta}
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    # No full-table SELECT of notifications for this user — only UPDATE.
    notification_selects =
      Enum.count(queries, fn {_m, meta} ->
        source = meta[:source] || meta[:options][:source]
        query = meta[:query] || ""

        source in ["notifications", :notifications] and
          is_binary(query) and String.starts_with?(String.trim(query), "SELECT")
      end)

    notification_updates =
      Enum.count(queries, fn {_m, meta} ->
        query = meta[:query] || ""

        is_binary(query) and String.contains?(query, "UPDATE") and
          String.contains?(query, "notifications")
      end)

    reloaded = Repo.get!(Casein.Notifications.Notification, target.id)
    assert reloaded.read_at == @later

    still_unread =
      from(n in Casein.Notifications.Notification,
        where: n.user_id == "dev" and is_nil(n.read_at)
      )
      |> Repo.aggregate(:count)

    assert still_unread == noise
    assert notification_selects == 0
    # mark_session_window_seen syncs twice (window + card); both are update_all.
    assert notification_updates <= 4
    # Soft wall-clock budget — far below multi-hundred-ms full-table stall.
    assert usec < 200_000, "sync took #{usec}µs with #{noise} noise rows"
  end
end
