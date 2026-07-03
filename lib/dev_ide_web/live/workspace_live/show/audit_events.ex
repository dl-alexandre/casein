defmodule DevIdeWeb.WorkspaceLive.Show.AuditEvents do
  # Audit drawer handle_event clauses and stream helpers extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change). Show
  # delegates every "audit_drawer:*" event here via a prefix delegator.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIDE.Audit
  alias DevIDE.Runs.Ledger
  alias DevIdeWeb.WorkspaceLive.Show.AuditDrawer

  @max_audit_stream 50

  def handle_event("audit_drawer:toggle", _, socket) do
    open? = not socket.assigns.audit_drawer_open

    socket =
      socket
      |> assign(:audit_drawer_open, open?)
      |> then(fn s -> if open?, do: refresh_audit_stream(s), else: s end)

    {:noreply, socket}
  end

  def handle_event("audit_drawer:close", _, socket),
    do: {:noreply, assign(socket, :audit_drawer_open, false)}

  def handle_event("audit_drawer:refresh", _, socket),
    do: {:noreply, refresh_audit_stream(socket)}

  def handle_event("audit_drawer:filter_window", %{"filter" => filter}, socket) do
    filter = String.trim(to_string(filter || ""))

    {:noreply,
     socket
     |> assign(:audit_window_filter, filter)
     |> refresh_audit_stream()}
  end

  def refresh_audit_stream(socket) do
    if connected?(socket) do
      events =
        socket
        |> refreshed_audit()
        |> filter_audit_events(socket.assigns[:audit_window_filter])

      socket
      |> stream(:audit_events, events, reset: true)
      |> assign(:audit_events_count, length(events))
      |> assign(:audit_deny_count, AuditDrawer.deny_count(events))
      |> assign(:audit_ledger_count, AuditDrawer.ledger_event_count(events))
    else
      socket
    end
  end

  def maybe_insert_audit_event(socket, nil), do: socket

  def maybe_insert_audit_event(socket, %Audit.Event{} = event) do
    filter = socket.assigns[:audit_window_filter]

    if connected?(socket) and audit_event_visible?(event, filter) do
      count = (socket.assigns[:audit_events_count] || 0) + 1

      socket =
        socket
        |> stream_insert(:audit_events, event, at: 0)
        |> assign(:audit_events_count, count)
        |> update(:audit_deny_count, &(&1 + if(event.decision == :deny, do: 1, else: 0)))
        |> update(:audit_ledger_count, &(&1 + if(Ledger.ledger_event?(event), do: 1, else: 0)))

      if count > @max_audit_stream, do: refresh_audit_stream(socket), else: socket
    else
      socket
    end
  end

  defp refreshed_audit(socket) do
    Audit.recent_for(socket.assigns.workspace.id, 50)
  end

  defp filter_audit_events(events, filter) when filter in [nil, ""], do: events

  defp filter_audit_events(events, filter) when is_list(events) do
    needle = String.downcase(to_string(filter))
    Enum.filter(events, &audit_event_matches_window?(&1, needle))
  end

  defp filter_audit_events(events, _filter), do: events

  defp audit_event_matches_window?(event, needle) do
    case audit_event_window_ref(event) do
      ref when is_binary(ref) and ref != "" -> String.contains?(String.downcase(ref), needle)
      _ -> false
    end
  end

  defp audit_event_window_ref(%{metadata: metadata}) when is_map(metadata) do
    name = metadata["tmux_window_name"] || metadata[:tmux_window_name]
    id = metadata["tmux_window_id"] || metadata[:tmux_window_id]

    cond do
      is_binary(name) and name != "" -> name
      is_binary(id) and id != "" -> id
      true -> nil
    end
  end

  defp audit_event_window_ref(_), do: nil

  defp audit_event_visible?(_event, filter) when filter in [nil, ""], do: true

  defp audit_event_visible?(event, filter),
    do: audit_event_matches_window?(event, String.downcase(to_string(filter)))
end
