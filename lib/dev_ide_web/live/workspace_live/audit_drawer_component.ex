defmodule DevIdeWeb.WorkspaceLive.AuditDrawerComponent do
  @moduledoc """
  Audit drawer as a stateful LiveComponent: owns the audit-event stream,
  the visible/deny/ledger counters, and the window filter.

  Open/closed stays hub state on the Show LiveView — the command palette
  toggles it and `run_ledger:open` closes it, both outside this component —
  so `audit_drawer:toggle`/`audit_drawer:close` still route to Show while
  `audit_drawer:refresh`/`audit_drawer:filter_window` target this component
  (gated through `PanelGate`, since component events bypass Show's authz
  hook). Show forwards live audit events with
  `send_update(..., insert_audit_event: event)`; the stream refreshes
  itself when `open` transitions to true.
  """

  use DevIdeWeb, :live_component

  import DevIdeWeb.WorkspaceLive.Show.AuditDrawer, only: [audit_drawer: 1]

  alias DevIDE.Audit
  alias DevIDE.Runs.Ledger
  alias DevIdeWeb.WorkspaceLive.Show.AuditDrawer
  alias DevIdeWeb.WorkspaceLive.Show.PanelGate

  @max_audit_stream 50

  @config_keys ~w(id open workspace current_user)a

  @impl true
  def update(%{insert_audit_event: event}, socket) do
    {:ok, maybe_insert_audit_event(socket, event)}
  end

  def update(assigns, socket) do
    was_open? = socket.assigns[:open] == true
    first_mount? = not Map.has_key?(socket.assigns, :audit_window_filter)

    socket =
      socket
      |> assign(Map.take(assigns, @config_keys))
      |> then(fn s ->
        if first_mount? do
          s
          |> assign(:audit_window_filter, "")
          |> assign(:audit_events_count, 0)
          |> assign(:audit_deny_count, 0)
          |> assign(:audit_ledger_count, 0)
          |> assign(:audit_trace, nil)
          |> stream(:audit_events, [])
        else
          s
        end
      end)

    # Opening refreshes so the drawer never shows a stale window (same as
    # the old audit_drawer:toggle open path).
    socket =
      if socket.assigns.open and not was_open? do
        refresh_audit_stream(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.audit_drawer
        audit_drawer_open={@open}
        audit_events_count={@audit_events_count}
        audit_ledger_count={@audit_ledger_count}
        audit_window_filter={@audit_window_filter}
        audit_trace={@audit_trace}
        workspace={@workspace}
        streams={@streams}
        target={@myself}
      />
    </div>
    """
  end

  @impl true
  def handle_event("audit_drawer:refresh" = event, _, socket) do
    PanelGate.gate_event(socket, event, fn ->
      {:noreply, refresh_audit_stream(socket)}
    end)
  end

  def handle_event("audit_drawer:filter_window" = event, %{"filter" => filter}, socket) do
    PanelGate.gate_event(socket, event, fn ->
      filter = String.trim(to_string(filter || ""))

      {:noreply,
       socket
       |> assign(:audit_window_filter, filter)
       |> refresh_audit_stream()}
    end)
  end

  # Drill into one event's causal chain (correlation stamped by
  # DevIDE.Signals.Context). list_by_correlation reads the durable audit table
  # and returns the chain in causal order.
  def handle_event("audit_drawer:trace" = event, %{"correlation" => cid}, socket)
      when is_binary(cid) and cid != "" do
    PanelGate.gate_event(socket, event, fn ->
      {:noreply,
       assign(socket, :audit_trace, %{correlation_id: cid, events: Audit.list_by_correlation(cid)})}
    end)
  end

  def handle_event("audit_drawer:trace_close" = event, _params, socket) do
    PanelGate.gate_event(socket, event, fn ->
      {:noreply, assign(socket, :audit_trace, nil)}
    end)
  end

  def refresh_audit_stream(socket) do
    events =
      socket.assigns.workspace.id
      |> Audit.recent_for(50)
      |> filter_audit_events(socket.assigns[:audit_window_filter])

    socket
    |> stream(:audit_events, events, reset: true)
    |> assign(:audit_events_count, length(events))
    |> assign(:audit_deny_count, AuditDrawer.deny_count(events))
    |> assign(:audit_ledger_count, AuditDrawer.ledger_event_count(events))
    |> assign(:audit_trace, nil)
  end

  def maybe_insert_audit_event(socket, nil), do: socket

  def maybe_insert_audit_event(socket, %Audit.Event{} = event) do
    filter = socket.assigns[:audit_window_filter]

    if audit_event_visible?(event, filter) do
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

  defp filter_audit_events(events, filter) when filter in [nil, ""], do: events

  defp filter_audit_events(events, filter) when is_list(events) do
    needle = String.downcase(to_string(filter))
    Enum.filter(events, &audit_event_matches_window?(&1, needle))
  end

  defp filter_audit_events(events, _filter), do: events

  defp audit_event_visible?(event, filter) when is_binary(filter) and filter != "" do
    audit_event_matches_window?(event, String.downcase(filter))
  end

  defp audit_event_visible?(_event, _filter), do: true

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
end
