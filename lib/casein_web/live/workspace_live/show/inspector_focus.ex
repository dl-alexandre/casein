defmodule CaseinWeb.WorkspaceLive.Show.InspectorFocus do
  @moduledoc """
  Socket-state focus / zoom helpers for the single LiveView-owned inspector
  region (#692). Real tmux pane ids never flow through these helpers into a
  tmux adapter. Slot list + geometry stay owned by `Casein.Cockpit.Inspectors` /
  `InspectorEvents` (#690 / #750).

  ## Focus model (authoritative)

  Leader zoom/close/navigate decide their target with **`focus_target/1` only**.
  Do not re-derive "is an inspector focused?" at call sites.

  | Layer | Role when an inspector is focused |
  | ----- | --------------------------------- |
  | **`inspector_focus_id`** | **Authoritative for leader ops** (`C-b z` / `C-b x` / arrows). Set when focus enters the inspector region; cleared when it returns to the terminal region. |
  | **`active_inspector_id`** | Which viewport fills the one inspector region (replace-on-open; not a tab). |
  | **`focused_pane_id` / tmux active pane** | Still the tmux region's active PTY. Unchanged while the inspector holds leader focus; terminal stays live underneath zoom. |
  | **Browser DOM focus** | Content editing inside the inspector panel. Does **not** move leader target by itself — clicking chrome calls `focus_inspector/2`. |
  | **Input-ownership ladder** | Unchanged: *global > leader > pane content*. While leader mode is active, keys hit leader bindings first; those bindings read `focus_target/1`. |

  Opening a second inspector **replaces** the first (no tab strip). Returning to
  a previous inspector is a palette/surface action, not chrome.
  """

  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  @type focus_target :: {:inspector, String.t()} | {:tmux, String.t() | nil}

  @doc "Extra mount assigns for focus/zoom state on top of #690."
  @spec mount_assigns(map()) :: map()
  def mount_assigns(base \\ %{}) when is_map(base) do
    Map.merge(base, %{
      active_inspector_id: nil,
      inspector_focus_id: nil,
      inspector_zoomed?: false
    })
  end

  @doc "True when leader ops should act on the inspector viewport."
  @spec inspector_focused?(map()) :: boolean()
  def inspector_focused?(assigns) when is_map(assigns) do
    match?({:inspector, _}, focus_target(assigns))
  end

  @doc """
  Resolve what leader zoom/close/navigate should act on.

  Prefers an explicit inspector focus id when it still exists in
  `:inspector_slots`. This is the single authority for inspector-vs-tmux
  routing — see the module doc.
  """
  @spec focus_target(map()) :: focus_target()
  def focus_target(assigns) when is_map(assigns) do
    case assigns[:inspector_focus_id] do
      id when is_binary(id) and id != "" ->
        if slot?(assigns, id) do
          {:inspector, id}
        else
          {:tmux, assigns[:tmux_active_pane_id]}
        end

      _ ->
        {:tmux, assigns[:tmux_active_pane_id]}
    end
  end

  @doc "Active inspector id (the single open slot, if any)."
  @spec active_id(map()) :: String.t() | nil
  def active_id(assigns) when is_map(assigns) do
    slots = List.wrap(assigns[:inspector_slots])
    preferred = assigns[:active_inspector_id] || assigns[:inspector_focus_id]

    cond do
      is_binary(preferred) and Enum.any?(slots, &(&1.id == preferred)) ->
        preferred

      match?([%{id: _} | _], slots) ->
        hd(slots).id

      true ->
        nil
    end
  end

  @doc "Keep focus/zoom assigns coherent after inspector list changes."
  @spec reconcile(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reconcile(socket) do
    import Phoenix.Component, only: [assign: 3]

    slots = List.wrap(socket.assigns[:inspector_slots])
    ids = MapSet.new(slots, & &1.id)

    active =
      case socket.assigns[:active_inspector_id] do
        id when is_binary(id) ->
          if MapSet.member?(ids, id), do: id, else: default_active(slots)

        _ ->
          default_active(slots)
      end

    focus =
      case socket.assigns[:inspector_focus_id] do
        id when is_binary(id) ->
          if MapSet.member?(ids, id), do: id, else: nil

        _ ->
          nil
      end

    zoomed? = socket.assigns[:inspector_zoomed?] == true and is_binary(active)

    socket
    |> assign(:active_inspector_id, active)
    |> assign(:inspector_focus_id, focus)
    |> assign(:inspector_zoomed?, zoomed?)
  end

  @doc "Focus the inspector viewport (socket state only)."
  @spec focus_inspector(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def focus_inspector(socket, id) when is_binary(id) do
    import Phoenix.Component, only: [assign: 3]

    if slot?(socket.assigns, id) do
      socket
      |> assign(:inspector_focus_id, id)
      |> assign(:active_inspector_id, id)
      |> assign(:ui_highlight_pane_id, id)
    else
      socket
    end
  end

  @doc "Clear inspector focus so leader ops target the tmux region again."
  @spec focus_terminal(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def focus_terminal(socket) do
    import Phoenix.Component, only: [assign: 3]

    socket
    |> assign(:inspector_focus_id, nil)
    |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])
  end

  @doc "Toggle inspector zoom fill (socket state; terminal stays mounted)."
  @spec toggle_zoom(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_zoom(socket) do
    import Phoenix.Component, only: [assign: 3]

    case focus_target(socket.assigns) do
      {:inspector, id} ->
        zoomed? = socket.assigns[:inspector_zoomed?] == true

        socket
        |> assign(:inspector_zoomed?, not zoomed?)
        |> assign(:active_inspector_id, id)
        |> assign(:inspector_focus_id, id)

      _ ->
        socket
    end
  end

  @doc "Close the focused inspector via InspectorEvents (no tmux)."
  @spec close_focused(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, term()}
  def close_focused(socket) do
    import Phoenix.Component, only: [assign: 3]

    case focus_target(socket.assigns) do
      {:inspector, id} ->
        socket =
          socket
          |> InspectorEvents.close_inspector(id)
          |> reconcile()
          |> assign(:inspector_focus_id, nil)
          |> assign(:inspector_zoomed?, false)
          |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])

        {:ok, socket}

      _ ->
        {:error, :not_inspector}
    end
  end

  @doc """
  Cross-region arrow navigation when an inspector is open.

  Returns `{:inspector, socket}`, `{:terminal, socket}`, or `:tmux` when the
  caller should keep the existing tmux navigate path. There is only one
  inspector — arrows move between the terminal region and the inspector region,
  never between inspector tabs.
  """
  @spec navigate(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:inspector, Phoenix.LiveView.Socket.t()}
          | {:terminal, Phoenix.LiveView.Socket.t()}
          | :tmux
  def navigate(socket, dir) when dir in ["left", "right", "up", "down", "next", "prev", "last"] do
    slots = List.wrap(socket.assigns[:inspector_slots])

    if slots == [] do
      :tmux
    else
      placement = normalize_placement(socket.assigns[:inspector_placement])

      case focus_target(socket.assigns) do
        {:inspector, _id} ->
          navigate_from_inspector(socket, dir, placement)

        {:tmux, _} ->
          navigate_from_terminal(socket, dir, placement, slots)
      end
    end
  end

  def navigate(_socket, _dir), do: :tmux

  @doc "After opening a slot, focus it."
  @spec after_open(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def after_open(socket, id) when is_binary(id) do
    socket
    |> reconcile()
    |> focus_inspector(id)
  end

  def after_open(socket, _) do
    case active_id(socket.assigns) do
      nil -> reconcile(socket)
      id -> after_open(socket, id)
    end
  end

  defp navigate_from_terminal(socket, dir, placement, slots) do
    into_inspector? =
      case {placement, dir} do
        {:right, "right"} -> true
        {:bottom, "down"} -> true
        {_, "next"} -> true
        _ -> false
      end

    if into_inspector? do
      target = active_id(socket.assigns) || hd(slots).id
      {:inspector, focus_inspector(socket, target)}
    else
      :tmux
    end
  end

  defp navigate_from_inspector(socket, dir, placement) do
    leave_inspector? =
      case {placement, dir} do
        {:right, "left"} -> true
        {:bottom, "up"} -> true
        {_, "prev"} -> true
        {_, "last"} -> true
        {_, "next"} -> true
        {:right, "right"} -> false
        {:bottom, "down"} -> false
        {_, "left"} -> true
        {_, "up"} -> true
        _ -> false
      end

    if leave_inspector? do
      {:terminal, focus_terminal(socket)}
    else
      {:inspector, socket}
    end
  end

  defp default_active([]), do: nil
  defp default_active([%{id: id} | _]), do: id

  defp slot?(assigns, id) do
    Enum.any?(List.wrap(assigns[:inspector_slots]), &(&1.id == id))
  end

  defp normalize_placement(placement) when placement in [:right, :bottom], do: placement
  defp normalize_placement("right"), do: :right
  defp normalize_placement("bottom"), do: :bottom
  defp normalize_placement(_), do: :right
end
