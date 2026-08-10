defmodule CaseinWeb.WorkspaceLive.Show.InspectorEvents do
  @moduledoc false

  # LiveView-owned inspector slots (issue #690) + focus/zoom/close (#692) +
  # diff open path (#691). Socket state only — no registry, no tmux holder, no
  # Panes.feature_types. Ordinary LiveView events + a workspace PubSub surface
  # request from Casein.Cockpit.Inspectors. Layout nodes are slots (#750).
  # One inspector at a time: open replaces; no tab strip.

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Cockpit.Inspectors
  alias Casein.Workspaces.FileAccess
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.Context
  alias CaseinWeb.WorkspaceLive.Show.InspectorFocus
  alias CaseinWeb.WorkspaceLive.Show.RunEvents
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

  # Open a diff inspector beside the terminal, or fall back to the full-area
  # `diff` tab when there is no workspace/tmux context to sit beside
  # (mirror of FilePaneEvents `tree:open_in_pane` → files tab).
  def handle_event("diff:open_inspector", params, socket) do
    path = string_param(params, "path")

    if inspector_context?(socket) do
      {:noreply, open_diff_inspector(socket, path)}
    else
      open_in_diff_tab(socket, path)
    end
  end

  # Open a run inspector beside the terminal, or fall back to the full-area
  # `run` tab when there is no workspace/tmux context (#694).
  def handle_event("run:open_inspector", params, socket) do
    run_id = string_param(params, "run_id")

    if inspector_context?(socket) do
      {:noreply, open_run_inspector(socket, run_id)}
    else
      open_in_run_tab(socket, run_id)
    end
  end

  def handle_info({:inspector_open, attrs}, socket) do
    socket =
      case inspector_kind(attrs) do
        :diff -> open_diff_inspector(socket, path_from_attrs(attrs), attrs)
        :run -> open_run_inspector(socket, run_id_from_attrs(attrs), attrs)
        _ -> open_inspector(socket, attrs)
      end

    {:noreply, socket}
  end

  def open_inspector(socket, attrs) do
    opts = geometry_opts(socket)
    # Region holds one inspector — open replaces any previous slot (#692).
    {slots, geometry} = Inspectors.open(socket.assigns.inspector_slots, attrs, opts)
    opened_id = List.first(slots) && List.first(slots).id

    socket
    |> assign(:inspector_slots, slots)
    |> assign(:cockpit_geometry, geometry)
    # Replace clears prior zoom; focus lands on the new viewport.
    |> assign(:inspector_zoomed?, false)
    |> InspectorFocus.after_open(opened_id)
  end

  def close_inspector(socket, id) do
    opts = geometry_opts(socket)
    {slots, geometry} = Inspectors.close(socket.assigns.inspector_slots, id, opts)

    socket
    |> assign(:inspector_slots, slots)
    |> assign(:cockpit_geometry, geometry)
    |> maybe_clear_diff_assigns(slots)
    |> assign(:active_inspector_id, nil)
    |> assign(:inspector_focus_id, nil)
    |> assign(:inspector_zoomed?, false)
    |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])
    |> InspectorFocus.reconcile()
  end

  def close_all(socket) do
    opts = geometry_opts(socket)
    {slots, geometry} = Inspectors.close_all(opts)

    socket
    |> assign(:inspector_slots, slots)
    |> assign(:cockpit_geometry, geometry)
    |> assign(:active_inspector_id, nil)
    |> assign(:inspector_focus_id, nil)
    |> assign(:inspector_zoomed?, false)
    |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])
    |> assign(:file_diff, nil)
  end

  @doc """
  Apply a serialized inspector list (session-template restore).

  Re-derives diff data from path and run ledger from optional run_id. A run id
  that no longer exists lands on the ledger with nothing selected — normal
  empty state, not an error.
  """
  def restore_inspectors(socket, serialized) do
    {slots, geometry} = Inspectors.restore(serialized, geometry_opts(socket))

    socket =
      socket
      |> assign(:inspector_slots, slots)
      |> assign(:cockpit_geometry, geometry)
      |> InspectorFocus.reconcile()

    socket = restore_diff_content(socket, slots)
    restore_run_content(socket, slots)
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

  defp open_run_inspector(socket, run_id, extra \\ %{}) do
    run_id = normalize_path(run_id) || run_id_from_attrs(extra)
    id = id_from_attrs(extra) || "insp-run"
    title = title_from_attrs(extra) || run_title(run_id)

    attrs = %{
      kind: :run,
      id: id,
      title: title,
      run_id: run_id
    }

    socket
    |> open_inspector(attrs)
    |> assign(:tab, "terminal")
    |> load_run_for_id(run_id)
  end

  # Re-derive ledger against current state. A missing run id is a normal empty
  # state: show the ledger with nothing selected — never error, crash, or blank.
  defp load_run_for_id(socket, run_id) when is_binary(run_id) and run_id != "" do
    socket = RunEvents.refresh_run_ledger(socket, run_id)

    case socket.assigns[:selected_run_summary] do
      %{id: ^run_id} ->
        socket

      _ ->
        # Gone / unknown: land on ledger overview, nothing selected.
        socket
        |> assign(:selected_run_id, nil)
        |> assign(:selected_run_summary, nil)
        |> assign(:selected_run_timeline, [])
        |> assign(:selected_run_artifacts, [])
        |> assign(:selected_run_failure_reason, nil)
        |> assign(:selected_run_can_retry, false)
    end
  end

  defp load_run_for_id(socket, _) do
    RunEvents.refresh_run_ledger(socket, nil)
    |> then(fn s ->
      # Overview: keep ledger rows, clear forced selection when none preferred.
      s
    end)
  end

  defp restore_diff_content(socket, slots) do
    case Inspectors.primary_diff_path(slots) do
      path when is_binary(path) ->
        socket
        |> assign(:tab, "terminal")
        |> load_diff_for_path(path)

      _ ->
        if Inspectors.diff_open?(slots) do
          socket
          |> assign(:tab, "terminal")
          |> Show.refresh_git_status()
        else
          socket
        end
    end
  end

  defp restore_run_content(socket, slots) do
    cond do
      not Inspectors.run_open?(slots) ->
        socket

      true ->
        run_id = Inspectors.primary_run_id(slots)

        socket
        |> assign(:tab, "terminal")
        |> load_run_for_id(run_id)
    end
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

  defp open_in_run_tab(socket, run_id) when is_binary(run_id) and run_id != "" do
    {:noreply,
     socket
     |> load_run_for_id(run_id)
     |> assign(:tab, "run")}
  end

  defp open_in_run_tab(socket, _run_id) do
    {:noreply,
     socket
     |> load_run_for_id(nil)
     |> assign(:tab, "run")}
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

  defp maybe_clear_diff_assigns(socket, slots) do
    if Inspectors.diff_open?(slots) do
      socket
    else
      assign(socket, :file_diff, nil)
    end
  end

  defp recompute_geometry(socket) do
    geometry =
      Inspectors.geometry(socket.assigns.inspector_slots, geometry_opts(socket))

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
      :run -> :run
      "run" -> :run
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

  defp run_id_from_attrs(attrs) when is_map(attrs) do
    normalize_path(
      Map.get(attrs, :run_id) ||
        Map.get(attrs, "run_id") ||
        get_in(attrs, [:attrs, "run_id"]) ||
        get_in(attrs, ["attrs", "run_id"])
    )
  end

  defp run_id_from_attrs(_), do: nil

  defp run_title(run_id) when is_binary(run_id) and run_id != "" do
    short = if byte_size(run_id) > 8, do: String.slice(run_id, 0, 8), else: run_id
    "Run " <> short
  end

  defp run_title(_), do: "Run"

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
    atom_key =
      case key do
        "path" -> :path
        "run_id" -> :run_id
        _ -> nil
      end

    raw = Map.get(params, key) || (atom_key && Map.get(params, atom_key))
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
