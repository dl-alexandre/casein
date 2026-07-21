defmodule DevIdeWeb.WorkspaceLive.Show.HistoryEventsTest do
  # Workspaces.State.MemoryAdapter + Export.previous_sessions on search/refresh.
  use DevIDE.TestCase, async: false

  alias DevIdeWeb.WorkspaceLive.Show.HistoryEvents

  # Pure: assign_defaults, open (not connected), refresh_if_open no-ops.
  # history:search / clear / refresh call Export.previous_sessions — with an
  # unknown workspace id the MemoryAdapter returns :error, so we assert the
  # pure error-assign branch without a real Export backend.

  defp socket(assigns \\ %{}) do
    ws_id = "ws-history-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: ws_id},
            tab: "terminal",
            history_loaded?: false,
            history_subscribed?: false
          },
          assigns
        )
    }
  end

  test "assign_defaults seeds empty panel state without domain calls" do
    s = HistoryEvents.assign_defaults(socket())

    assert s.assigns.history_loaded? == false
    assert s.assigns.history_subscribed? == false
    assert s.assigns.history_error == nil
    assert s.assigns.history_results == []
    assert s.assigns.history_filters.limit == 20
    assert s.assigns.history_filters.query == ""
    assert is_struct(s.assigns.history_form, Phoenix.HTML.Form)
    assert s.assigns.history_payload == %{limit: 20, results: []}
  end

  test "open does not search when the socket is not connected" do
    s =
      HistoryEvents.assign_defaults(
        socket(%{
          history_loaded?: false,
          history_results: []
        })
      )

    s2 = HistoryEvents.open(s, %{"query" => "hello"})
    # connected?/1 is false on a bare socket — open only seeds filters.
    assert s2.assigns.history_loaded? == false
    assert s2.assigns.history_filters.query == "hello"
    assert s2.assigns.history_error == nil
  end

  test "open ignores params that are not seed filters" do
    s = HistoryEvents.assign_defaults(socket())
    s2 = HistoryEvents.open(s, %{"tab" => "history", "noise" => "x"})
    assert s2.assigns.history_filters.query == ""
  end

  test "refresh_if_open is a no-op when the history tab is not active" do
    s =
      HistoryEvents.assign_defaults(
        socket(%{tab: "terminal", history_loaded?: true, history_error: nil})
      )

    assert HistoryEvents.refresh_if_open(s) == s
  end

  test "refresh_if_open is a no-op when history has not been loaded yet" do
    s =
      HistoryEvents.assign_defaults(socket(%{tab: "history", history_loaded?: false}))

    assert HistoryEvents.refresh_if_open(s) == s
  end

  test "history:search nested params apply filters then set unavailable error" do
    s = HistoryEvents.assign_defaults(socket())

    assert {:noreply, s2} =
             HistoryEvents.handle_event(
               "history:search",
               %{"search" => %{"query" => "tmux", "limit" => "10"}},
               s
             )

    assert s2.assigns.history_filters.query == "tmux"
    assert s2.assigns.history_filters.limit == 10

    assert s2.assigns.history_error ==
             "Previous sessions are not available for this workspace."
  end

  test "history:search flat params wrap into the search form shape" do
    s = HistoryEvents.assign_defaults(socket())

    assert {:noreply, s2} =
             HistoryEvents.handle_event("history:search", %{"query" => "flat"}, s)

    assert s2.assigns.history_filters.query == "flat"
  end

  test "history:clear resets filters and records the unavailable error" do
    s =
      HistoryEvents.assign_defaults(socket())
      |> then(fn sock ->
        {:noreply, sock} =
          HistoryEvents.handle_event(
            "history:search",
            %{"search" => %{"query" => "keep"}},
            sock
          )

        sock
      end)

    assert s.assigns.history_filters.query == "keep"

    assert {:noreply, s2} = HistoryEvents.handle_event("history:clear", %{}, s)
    assert s2.assigns.history_filters.query == ""
    assert s2.assigns.history_filters.limit == 20

    assert s2.assigns.history_error ==
             "Previous sessions are not available for this workspace."
  end

  test "history:refresh re-runs search without changing filters" do
    s = HistoryEvents.assign_defaults(socket())

    assert {:noreply, s2} = HistoryEvents.handle_event("history:refresh", %{}, s)

    assert s2.assigns.history_error ==
             "Previous sessions are not available for this workspace."

    assert s2.assigns.history_filters.limit == 20
  end
end
