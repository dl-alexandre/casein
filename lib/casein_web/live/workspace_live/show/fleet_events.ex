defmodule CaseinWeb.WorkspaceLive.Show.FleetEvents do
  # Fleet board drawer open/close. Board rows rebuild with topology tabs.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Casein.Terminals.FleetBoard
  alias CaseinWeb.WorkspaceLive.Show.TerminalEvents

  def mount(socket) do
    socket
    |> assign(:fleet_drawer_open, false)
    |> assign(:fleet_board, socket.assigns[:fleet_board] || FleetBoard.empty())
  end

  def handle_event("fleet_drawer:toggle", _params, socket) do
    {:noreply, assign(socket, :fleet_drawer_open, not socket.assigns.fleet_drawer_open)}
  end

  def handle_event("fleet_drawer:close", _params, socket) do
    {:noreply, assign(socket, :fleet_drawer_open, false)}
  end

  @doc """
  `C-b a` / the badge's needs-you half: focus the next pane that needs you.

  Membership and order come from `FleetBoard.next_needs_you/2`, which walks the
  same `needs_you?` set the badge counts — see its docstring for why the bucket
  is not the rule. This handler only routes; it never re-derives who needs you.

  Focusing reuses `tmux:select_window`, the event the drawer rows already issue,
  so a jump and a click land through one code path. With nothing asking for you
  the key is a no-op with a quiet note rather than a silent nothing, which is
  what tells an operator the key worked and the fleet is calm.
  """
  def handle_event("fleet:jump_needs_you", _params, socket) do
    board = socket.assigns[:fleet_board] || FleetBoard.empty()

    case FleetBoard.next_needs_you(board, socket.assigns[:tmux_active_window_id]) do
      nil ->
        {:noreply, put_flash(socket, :info, "Nothing needs you right now.")}

      %{window_id: window_id} ->
        TerminalEvents.handle_event("tmux:select_window", %{"window-id" => window_id}, socket)
    end
  end
end
