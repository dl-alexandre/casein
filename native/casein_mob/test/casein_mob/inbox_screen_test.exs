defmodule CaseinMob.InboxScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.InboxScreen
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig

  setup do
    SessionConfig.clear_all()
    :ok
  end

  test "renders inbox chrome and empty not-paired state" do
    view = mount_screen(InboxScreen)

    assert_renderable(view)
    assert text(view) =~ "Inbox"
    assert find(view, :button, text: "Back")
    assert text(view) =~ "Not paired yet"
    assert find(view, :button, text: "Pair workspace")
  end

  test "honest empty state when paired with no cards" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, %{"cards" => []}})

    assert_renderable(view)
    assert text(view) =~ "Inbox is empty"
    refute text(view) =~ "could not load"
  end

  test "failed load is distinct from empty inbox" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, {:error, :network_unavailable}})

    assert text(view) =~ "Inbox could not load"
    assert text(view) =~ "Network unavailable"
    refute text(view) =~ "Inbox is empty"
  end

  test "hydrating never presents an authoritative empty inbox" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      InboxScreen
      |> mount_screen()
      |> render_info(
        {:mobile_cards_snapshot, %{"cards" => [], "live_work" => %{"status" => "hydrating"}}}
      )

    assert text(view) =~ "Syncing live work"
    refute text(view) =~ "Inbox is empty"
  end

  test "preserves server snapshot order within Needs Me" do
    SessionConfig.put_pairing("https://casein.test", "token")

    older = attention_card("older-open", "Older open clarification", 100, "2026-07-28T08:00:00Z")
    newer = attention_card("newer-open", "Newer open clarification", 200, "2026-07-28T09:00:00Z")

    # Server already ranked: newer first. Client must not re-sort.
    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, %{"cards" => [newer, older]}})

    rendered = text(view)
    {newer_offset, _} = :binary.match(rendered, "Newer open clarification")
    {older_offset, _} = :binary.match(rendered, "Older open clarification")
    assert newer_offset < older_offset
  end

  test "older open request remains reachable when a newer card exists for the same pane" do
    SessionConfig.put_pairing("https://casein.test", "token")

    # Regression for DISTINCT ON-before-filter: both open cards must stay listed.
    older =
      attention_card(
        "clarification:ws-1:pane-%3:rev-1",
        "Older open request",
        680,
        "2026-07-28T08:00:00Z"
      )

    newer =
      attention_card(
        "clarification:ws-1:pane-%3:rev-2",
        "Newer open request",
        700,
        "2026-07-28T09:00:00Z"
      )

    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, %{"cards" => [newer, older]}})

    assert text(view) =~ "Older open request"
    assert text(view) =~ "Newer open request"

    view = render_info(view, {:tap, {:open_card, older["id"]}})
    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen
  end

  test "opening a review card marks attention viewed and routes to ReviewDecisionScreen" do
    origin_id = "origin-devbox"

    SessionConfig.put_pairing(%{
      origin_id: origin_id,
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })

    start_session_client_probe()

    card =
      attention_card("needs_review:ws-1:run-1", "Agent needs review", 680, "2026-07-28T09:00:00Z")
      |> Map.merge(%{
        "origin" => %{"id" => origin_id, "display_name" => "Devbox"},
        "attention" => %{
          "identity" => "#{origin_id}:ws-1:session:run-1",
          "key" => "ws-1:session:run-1",
          "priority" => "critical",
          "rank" => 680,
          "explanation" => "A review decision is waiting",
          "required_decision" => "Review",
          "unresolved?" => true,
          "pin" => "needs_me",
          "since_viewed" => %{
            "count" => 2,
            "through_marker" => 42,
            "changes" => [%{"label" => "Decision requested"}]
          }
        }
      })

    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, %{"cards" => [card]}})

    assert text(view) =~ "Why now: A review decision is waiting"
    assert text(view) =~ "2 changes since you looked · Decision requested"

    view = render_info(view, {:tap, {:open_card, card["id"]}})
    assert navigated_to(view) == CaseinMob.ReviewDecisionScreen

    assert_receive {:session_client_cast,
                    {:attention_viewed,
                     %{
                       "origin_id" => ^origin_id,
                       "card_id" => "needs_review:ws-1:run-1",
                       "attention_key" => "ws-1:session:run-1",
                       "through_marker" => 42
                     }}}
  end

  test "non-review cards route into session detail" do
    SessionConfig.put_pairing("https://casein.test", "token")

    card = %{
      "id" => "in_progress:ws-1:run-2",
      "type" => "in_progress",
      "kind" => "in_progress",
      "status" => "running",
      "workspace_id" => "ws-1",
      "session_id" => "run-2",
      "title" => "Running mix test",
      "resume" => %{"state" => "working"},
      "action" => %{
        "label" => "Open",
        "route" => %{
          "type" => "session_detail",
          "workspace_id" => "ws-1",
          "session_id" => "run-2"
        }
      },
      "attention" => %{
        "identity" => "origin-local:in_progress:ws-1:run-2",
        "priority" => "normal",
        "rank" => 120
      }
    }

    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info({:mobile_cards_snapshot, %{"cards" => [card]}})
      |> render_info({:tap, {:filter, :running}})
      |> render_info({:tap, {:open_card, card["id"]}})

    assert navigated_to(view) == CaseinMob.SessionDetailScreen

    assert view.socket.__mob__.nav_action ==
             {:push, CaseinMob.SessionDetailScreen,
              %{workspace_id: "ws-1", session_id: "run-2", source: :inbox}}
  end

  test "segment filters switch which cards are shown" do
    SessionConfig.put_pairing("https://casein.test", "token")

    view =
      InboxScreen
      |> mount_screen()
      |> render_info({:mobile_cards_status, :joined})
      |> render_info(
        {:mobile_cards_snapshot,
         %{
           "cards" => [
             %{
               "id" => "needs_review:ws-1:run-1",
               "type" => "needs_review",
               "kind" => "approval_required",
               "workspace_id" => "ws-1",
               "title" => "Needs review now"
             },
             %{
               "id" => "in_progress:ws-1:run-2",
               "type" => "in_progress",
               "kind" => "in_progress",
               "workspace_id" => "ws-1",
               "title" => "Running mix test",
               "resume" => %{"state" => "working"}
             }
           ]
         }}
      )

    assert text(view) =~ "Needs review now"
    refute text(view) =~ "Running mix test"

    view = render_info(view, {:tap, {:filter, :running}})
    assert text(view) =~ "Running mix test"
    refute text(view) =~ "Needs review now"
  end

  test "back pops the screen" do
    view = InboxScreen |> mount_screen() |> render_info({:tap, :back})
    assert view.socket.__mob__.nav_action == {:pop}
  end

  defp attention_card(id, title, rank, occurred_at) do
    %{
      "id" => id,
      "type" => "needs_review",
      "kind" => "approval_required",
      "status" => "waiting",
      "workspace_id" => "ws-1",
      "session_id" => "run-1",
      "title" => title,
      "attention" => %{
        "identity" => "origin-local:#{id}",
        "key" => id,
        "priority" => "critical",
        "rank" => rank,
        "required_decision" => "Review",
        "unresolved?" => true,
        "pin" => "needs_me",
        "since_viewed" => %{
          "count" => 1,
          "through_marker" => rank,
          "changes" => [%{"label" => "Decision requested", "occurred_at" => occurred_at}]
        }
      }
    }
  end

  defp start_session_client_probe do
    test_pid = self()
    probe = spawn(fn -> session_client_probe(test_pid) end)
    true = Process.register(probe, SessionClient)
    on_exit(fn -> send(probe, :stop) end)
    probe
  end

  defp session_client_probe(test_pid) do
    receive do
      {:"$gen_cast", message} ->
        send(test_pid, {:session_client_cast, message})
        session_client_probe(test_pid)

      :stop ->
        :ok
    end
  end
end
