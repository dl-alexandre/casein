defmodule CaseinWeb.WorkspaceLive.Show.InspectorEvents do
  @moduledoc false

  # LiveView-owned inspector panes (issue #690) + focus/tabs (#692) + diff open
  # path (#691). Socket state only — no registry, no tmux holder, no
  # Panes.feature_types. Ordinary LiveView events + a workspace PubSub surface
  # request from Casein.Cockpit.Inspectors.

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Cockpit.Inspectors
  alias Casein.Workspaces.FileAccess
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.Context
  alias CaseinWeb.WorkspaceLive.Show.InspectorFocus
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome

  def mount_assigns(socket) do
    socket =
      Enum.reduce(Inspectors.initial_assigns(), socket, fn {k, v}, s -> assign(s, k, v) end)

    Enum.reduce(InspectorFocus.mount_assigns(), socket, fn {k, v}, s -> assign(s, k, v) end)
  end

  def subscribe(socket) do
    if connected?(socket) do
      _ = Inspectors.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  def handle_event("inspector:open", params, socket) do
    {:noreply, open_inspector(socket, params)}
  end

  def handle_event("inspector:close", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, close_inspector(socket, id)}
  end

  def handle_event("inspector:close", _params, socket), do: {:noreply, socket}

  def handle_event("inspector:close_all", _params, socket) do
    {:noreply, close_all(socket)}
  end

  def handle_event("inspector:select", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, InspectorFocus.focus_inspector(socket, id)}
  end

  def handle_event("inspector:select", _params, socket), do: {:noreply, socket}

  def handle_event("inspector:set_placement", %{"placement" => placement}, socket) do
    placement = if placement in ["bottom", :bottom], do: :bottom, else: :right

    socket =
      socket
      |> assign(:inspector_placement, placement)
      |> recompute_geometry()
      |> InspectorFocus.reconcile()

    {:noreply, socket}
  end

  def handle_event("inspector:set_placement", _params, socket), do: {:noreply, socket}

  @doc """
  Open a diff inspector beside the terminal, or fall back to the full-area
  `diff` tab when there is no workspace/tmux context to sit beside
  (mirror of FilePaneEvents `tree:open_in_pane` → files tab).
  """
  def handle_event("diff:open_inspector", params, socket) do
    path = string_param(params, "path")

    if inspector_context?(socket) do
      {:noreply, open_diff_inspector(socket, path)}
    else
      open_in_diff_tab(socket, path)
    end
  end

  def handle_info({:inspector_open, attrs}, socket) do
    socket =
      case inspector_kind(attrs) do
        :diff -> open_diff_inspector(socket, path_from_attrs(attrs), attrs)
        _ -> open_inspector(socket, attrs)
      end

    {:noreply, socket}
  end

  def open_inspector(socket, attrs) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.open(socket.assigns.inspector_panes, attrs, opts)
    opened_id = List.last(panes) && List.last(panes).id

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
    |> InspectorFocus.after_open(opened_id)
  end

  def close_inspector(socket, id) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.close(socket.assigns.inspector_panes, id, opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
    |> maybe_clear_diff_assigns(panes)
    |> InspectorFocus.reconcile()
    |> then(fn socket ->
      case InspectorFocus.active_id(socket.assigns) do
        nil ->
          socket
          |> assign(:inspector_focus_id, nil)
          |> assign(:inspector_zoomed?, false)
          |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])

        next_id ->
          if socket.assigns[:inspector_focus_id] do
            InspectorFocus.focus_inspector(socket, next_id)
          else
            assign(socket, :active_inspector_id, next_id)
          end
      end
    end)
  end

  def close_all(socket) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.close_all(opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
    |> assign(:active_inspector_id, nil)
    |> assign(:inspector_focus_id, nil)
    |> assign(:inspector_zoomed?, false)
    |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])
    |> assign(:file_diff, nil)
  end

  @doc "Apply a serialized inspector list (session-template restore). Re-derives diff data."
  def restore_inspectors(socket, serialized) do
    {panes, geometry} = Inspectors.restore(serialized, geometry_opts(socket))

    socket =
      socket
      |> assign(:inspector_panes, panes)
      |> assign(:cockpit_geometry, geometry)
      |> InspectorFocus.reconcile()

    case Inspectors.primary_diff_path(panes) do
      path when is_binary(path) ->
        socket
        |> assign(:tab, "terminal")
        |> load_diff_for_path(path)

      _ ->
        if Inspectors.diff_open?(panes) do
          socket
          |> assign(:tab, "terminal")
          |> Show.refresh_git_status()
        else
          socket
        end
    end
  end

  # --- internals ----------------------------------------------------------------

  defp open_diff_inspector(socket, path, extra \\ %{}) do
    path = normalize_path(path) || path_from_attrs(extra)
    id = id_from_attrs(extra) || "insp-diff"
    title = title_from_attrs(extra) || path || "Diff"

    attrs = %{
      kind: :diff,
      id: id,
      title: title,
      path: path
    }

    socket
    |> open_inspector(attrs)
    |> assign(:tab, "terminal")
    |> then(fn s ->
      if is_binary(path) do
        load_diff_for_path(s, path)
      else
        Show.refresh_git_status(s)
      end
    end)
  end

  defp load_diff_for_path(socket, path) do
    case Context.context_host_loc(socket) do
      {:ok, loc} ->
        case FileAccess.read_text(loc, path) do
          {:ok, file} ->
            socket
            |> Show.assign_open_file(file)
            |> assign(:file_error, nil)
            |> Show.load_diff(file.path)
            |> Show.refresh_git_status()

          {:error, reason} ->
            socket
            |> Show.assign_open_file(%{path: path, content: "", size: 0})
            |> assign(:file_error, Context.format_file_error(reason))
            |> Show.load_diff(path)
            |> Show.refresh_git_status()
        end

      _ ->
        socket
        |> Show.assign_open_file(%{path: path, content: "", size: 0})
        |> Show.load_diff(path)
    end
  end

  # Mirror FilePaneEvents.open_in_files_tab/2: load the path, switch full-area tab.
  defp open_in_diff_tab(socket, path) when is_binary(path) and path != "" do
    {:noreply,
     socket
     |> load_diff_for_path(path)
     |> assign(:tab, "diff")}
  end

  defp open_in_diff_tab(socket, _path) do
    {:noreply,
     socket
     |> assign(:tab, "diff")
     |> Show.refresh_git_status()}
  end

  # Mirror FilePaneEvents."tree:open_in_pane": need a live tmux session and an
  # anchor plain-terminal pane. Inspectors do not split tmux, but without a
  # running terminal there is nothing to sit beside — fall back to the tab.
  defp inspector_context?(socket) do
    tmux_session = socket.assigns[:tmux_session]
    host_ok? = match?({:ok, _}, socket.assigns[:host_loc])

    is_binary(tmux_session) and tmux_session != "" and host_ok? and
      is_binary(anchor_pane_id(socket))
  end

  defp anchor_pane_id(socket) do
    surface = socket.assigns[:terminal_surface_pane_id]
    active = socket.assigns[:tmux_active_pane_id]

    feature? =
      TerminalChrome.feature_pane?(
        socket.assigns[:preview_panes] || %{},
        socket.assigns[:feature_panes] || %{},
        active
      )

    cond do
      is_binary(surface) and surface != "" -> surface
      is_binary(active) and active != "" and not feature? -> active
      true -> nil
    end
  end

  defp maybe_clear_diff_assigns(socket, panes) do
    if Inspectors.diff_open?(panes) do
      socket
    else
      assign(socket, :file_diff, nil)
    end
  end

  defp recompute_geometry(socket) do
    geometry =
      Inspectors.geometry(socket.assigns.inspector_panes, geometry_opts(socket))

    assign(socket, :cockpit_geometry, geometry)
  end

  defp geometry_opts(socket) do
    [
      placement: socket.assigns[:inspector_placement] || :right,
      fraction: socket.assigns[:inspector_fraction] || 0.4
    ]
  end

  defp inspector_kind(attrs) when is_map(attrs) do
    case Map.get(attrs, :kind) || Map.get(attrs, "kind") do
      :diff -> :diff
      "diff" -> :diff
      _ -> :other
    end
  end

  defp inspector_kind(_), do: :other

  defp path_from_attrs(attrs) when is_map(attrs) do
    normalize_path(
      Map.get(attrs, :path) ||
        Map.get(attrs, "path") ||
        get_in(attrs, [:attrs, "path"]) ||
        get_in(attrs, ["attrs", "path"])
    )
  end

  defp path_from_attrs(_), do: nil

  defp id_from_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, :id) || Map.get(attrs, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp id_from_attrs(_), do: nil

  defp title_from_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, :title) || Map.get(attrs, "title") do
      title when is_binary(title) and title != "" -> title
      _ -> nil
    end
  end

  defp title_from_attrs(_), do: nil

  defp string_param(params, key) when is_map(params) and is_binary(key) do
    raw =
      Map.get(params, key) ||
        case key do
          "path" -> Map.get(params, :path)
          _ -> nil
        end

    normalize_path(raw)
  end

  defp normalize_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      p -> p
    end
  end

  defp normalize_path(_), do: nil
end
