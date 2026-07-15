defmodule DevIDE.FilePanes do
  @moduledoc """
  Registry of file-editor panes bound to tmux pane ids.

  A file pane rides a real tmux pane (tmux stays the geometry allocator) whose
  content is a native CodeMirror overlay rendered by the web layer. This module
  owns the binding + the pane's ordered list of open tabs, mirroring the shape of
  `DevIDE.PreviewPanes` but without any browser-control machinery.

  Policy: **one file pane per tmux window**. Opening a file in a window that
  already has a file pane reuses it and adds/activates a tab; otherwise a pane is
  split off the anchor. Agents (and the web layer) declare *intent* through
  `open_file_in_pane/3`; dev_ide owns the split/reuse/placement decision.

  State ownership: the registration persists the tab list + active path only.
  File **content and version tokens are never stored** — they are read fresh from
  disk via `DevIDE.Workspaces.FileAccess` on every render/save so a stale token
  can never clobber a concurrently-edited file.
  """

  use GenServer

  import Ecto.Query

  alias DevIDE.FilePanes.FilePaneRegistration
  alias DevIDE.Files.PathSafety
  alias DevIDE.Panes.Events, as: PaneEvents
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIDE.Workspaces.FileAccess
  alias DevIDE.Repo

  @table :dev_ide_file_panes
  @topology_tag DevIDE.Terminals.TmuxTopology
  @pane_type :file

  @type registration :: %{
          id: String.t(),
          pane_id: String.t(),
          workspace_id: String.t(),
          tmux_session: String.t() | nil,
          pane_window_id: String.t() | nil,
          placement: String.t() | nil,
          anchor_pane_id: String.t() | nil,
          anchor_window_id: String.t() | nil,
          open_files: [%{path: String.t(), line: integer() | nil}],
          active_path: String.t() | nil,
          status: :open
        }

  # --- lifecycle ----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok,
     %{
       subscriptions: MapSet.new(),
       workspace_index: %{},
       window_index: %{}
     }}
  end

  # --- public API ---------------------------------------------------------------

  @doc """
  Open `path` (at optional `:line`) in a file pane adjacent to an anchor pane,
  reusing the window's file pane if one exists.

  `workspace` is a workspace struct/map. Opts:

    * `:line` — 1-based line to reveal.
    * `:tmux_session` — required session (or resolved from the workspace).
    * `:anchor_pane_id` — pane to split off / whose window to target (defaults to
      the session's active pane).
    * `:anchor_window_id` — window to target (defaults to the anchor's window).
    * `:placement` — `"right"` (default) or `"bottom"`.
    * `:activate` — activate the opened tab (default `true`).

  Returns `{:ok, %{pane_id, registration, reused}}` or `{:error, reason}`.
  """
  @spec open_file_in_pane(map(), String.t(), keyword()) ::
          {:ok, %{pane_id: String.t(), registration: registration(), reused: boolean()}}
          | {:error, term()}
  def open_file_in_pane(workspace, path, opts \\ []) when is_map(workspace) and is_binary(path) do
    workspace_id = workspace_id(workspace)
    line = normalize_line(opts[:line])

    with {:ok, loc} <- Workspaces.safe_host_loc(workspace),
         {:ok, rel} <- to_rel(loc, path),
         {:ok, _preflight} <- FileAccess.read_text(loc, rel),
         {:ok, session} <- resolve_session(workspace, opts),
         {:ok, anchor} <- resolve_anchor(session, opts),
         {:ok, window_id} <- resolve_window(session, anchor, opts) do
      case get_by_window(session, window_id) do
        %{pane_id: pane_id} ->
          with {:ok, reg} <-
                 open_tab(pane_id, rel, line: line, activate: opts[:activate] != false) do
            {:ok, %{pane_id: pane_id, registration: reg, reused: true}}
          end

        _ ->
          split_and_register(workspace_id, loc, session, anchor, window_id, rel, line, opts)
      end
    end
  end

  @doc "Register a file pane binding. Broadcasts `:registered`."
  @spec register(map()) :: {:ok, registration()} | {:error, term()}
  def register(attrs) when is_map(attrs) do
    case GenServer.call(__MODULE__, {:register, attrs}) do
      {:ok, reg} ->
        broadcast(:registered, reg)
        {:ok, reg}

      err ->
        err
    end
  end

  @doc "Remove a file pane binding and kill its holder pane. Broadcasts `:removed`."
  @spec deregister(String.t()) :: :ok | {:error, :not_found}
  def deregister(pane_id) when is_binary(pane_id) do
    case GenServer.call(__MODULE__, {:deregister, pane_id}) do
      {:ok, reg} ->
        broadcast(:removed, reg)
        :ok

      err ->
        err
    end
  end

  @doc "Add-or-activate a tab. Opts: `:line`, `:activate` (default true)."
  @spec open_tab(String.t(), String.t(), keyword()) :: {:ok, registration()} | {:error, term()}
  def open_tab(pane_id, path, opts \\ []) when is_binary(pane_id) and is_binary(path) do
    broadcast_after(GenServer.call(__MODULE__, {:open_tab, pane_id, path, opts}))
  end

  @doc "Activate an already-open tab."
  @spec activate_tab(String.t(), String.t()) :: {:ok, registration()} | {:error, term()}
  def activate_tab(pane_id, path) when is_binary(pane_id) and is_binary(path) do
    broadcast_after(GenServer.call(__MODULE__, {:activate_tab, pane_id, path}))
  end

  @doc """
  Close a tab. Closing the last tab deregisters the pane and kills its holder.
  Returns `{:ok, registration | :closed}`.
  """
  @spec close_tab(String.t(), String.t()) :: {:ok, registration() | :closed} | {:error, term()}
  def close_tab(pane_id, path) when is_binary(pane_id) and is_binary(path) do
    case GenServer.call(__MODULE__, {:close_tab, pane_id, path}) do
      {:ok, :closed, reg} ->
        broadcast(:removed, reg)
        {:ok, :closed}

      {:ok, reg} ->
        broadcast(:updated, reg)
        {:ok, reg}

      err ->
        err
    end
  end

  @doc """
  Write `content` to a tab's file with optimistic concurrency. `expected_version`
  must match the on-disk version or `{:error, :conflict}` is returned. Runs the IO
  outside the GenServer.
  """
  @spec save_tab(String.t(), String.t(), binary(), String.t()) ::
          {:ok, %{version: String.t(), size: non_neg_integer()}} | {:error, term()}
  def save_tab(pane_id, path, content, expected_version)
      when is_binary(pane_id) and is_binary(path) and is_binary(content) do
    with reg when is_map(reg) <- get_by_pane(pane_id),
         {:ok, loc} <- workspace_loc(reg.workspace_id),
         {:ok, rel} <- to_rel(loc, path),
         {:ok, result} <- FileAccess.write_text(loc, rel, content, expected_version) do
      broadcast(:updated, reg)
      {:ok, result}
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  @doc "Re-read a tab's current on-disk content + version."
  @spec reload_tab(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reload_tab(pane_id, path) when is_binary(pane_id) and is_binary(path) do
    with reg when is_map(reg) <- get_by_pane(pane_id),
         {:ok, loc} <- workspace_loc(reg.workspace_id),
         {:ok, rel} <- to_rel(loc, path) do
      FileAccess.read_text(loc, rel)
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  @doc "Lookup a registration by tmux pane id (rehydrating from the DB on a miss)."
  @spec get_by_pane(String.t()) :: registration() | nil
  def get_by_pane(pane_id) when is_binary(pane_id) do
    case lookup_by_pane(pane_id) do
      nil ->
        if Process.whereis(__MODULE__) == self() do
          nil
        else
          GenServer.call(__MODULE__, {:get_by_pane, pane_id})
        end

      registration ->
        registration
    end
  end

  @doc "The file pane bound to a tmux window, if any (the reuse key)."
  @spec get_by_window(String.t(), String.t()) :: registration() | nil
  def get_by_window(tmux_session, window_id)
      when is_binary(tmux_session) and is_binary(window_id) do
    GenServer.call(__MODULE__, {:get_by_window, tmux_session, window_id})
  end

  @doc "All file panes for a workspace, resolving aliases."
  @spec list_for_workspace(String.t()) :: [registration()]
  def list_for_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list_for_workspace, WorkspaceAliases.viewer_ids(workspace_id)})
  end

  @doc """
  Build the render payload for a pane (reads the active file fresh). Returns `%{}`
  for an unknown pane so `DevIDE.Panes` can identify ownership.
  """
  @spec render_state(String.t()) :: map()
  def render_state(pane_id) when is_binary(pane_id) do
    case get_by_pane(pane_id) do
      nil -> %{}
      reg -> build_payload(reg)
    end
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # --- GenServer callbacks ------------------------------------------------------

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    case do_register(attrs, state) do
      {:ok, reg, state} -> {:reply, {:ok, reg}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deregister, pane_id}, _from, state) do
    case do_deregister(pane_id, state) do
      {:ok, reg, state} -> {:reply, {:ok, reg}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_tab, pane_id, path, opts}, _from, state) do
    reply_with_mutation(state, pane_id, fn reg ->
      activate? = Keyword.get(opts, :activate, true) != false
      line = normalize_line(opts[:line])
      tab = %{path: path, line: line}

      open_files =
        case Enum.find_index(reg.open_files, &(&1.path == path)) do
          nil ->
            reg.open_files ++ [tab]

          idx ->
            List.replace_at(reg.open_files, idx, merge_tab(Enum.at(reg.open_files, idx), line))
        end

      %{reg | open_files: open_files, active_path: if(activate?, do: path, else: reg.active_path)}
    end)
  end

  def handle_call({:activate_tab, pane_id, path}, _from, state) do
    reply_with_mutation(state, pane_id, fn reg ->
      if Enum.any?(reg.open_files, &(&1.path == path)) do
        %{reg | active_path: path}
      else
        reg
      end
    end)
  end

  def handle_call({:close_tab, pane_id, path}, _from, state) do
    case get_by_pane(pane_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      reg ->
        remaining = Enum.reject(reg.open_files, &(&1.path == path))

        if remaining == [] do
          {:ok, closed_reg, state} = do_deregister(pane_id, state)
          {:reply, {:ok, :closed, closed_reg}, state}
        else
          active_path =
            if reg.active_path == path, do: last_path(remaining), else: reg.active_path

          updated = %{reg | open_files: remaining, active_path: active_path}
          state = persist_and_store(updated, state)
          {:reply, {:ok, updated}, state}
        end
    end
  end

  def handle_call({:get_by_pane, pane_id}, _from, state) do
    {reg, state} = get_or_rehydrate_by_pane(pane_id, state)
    {:reply, reg, state}
  end

  def handle_call({:get_by_window, session, window_id}, _from, state) do
    reg =
      case Map.get(state.window_index, {session, window_id}) do
        nil -> nil
        pane_id -> get_by_pane(pane_id)
      end

    {:reply, reg, state}
  end

  def handle_call({:list_for_workspace, workspace_ids}, _from, state) do
    state = rehydrate_workspaces(workspace_ids, state)
    {:reply, list_workspace_registrations(state.workspace_index, workspace_ids), state}
  end

  def handle_call(:clear, _from, _state) do
    close_all_persisted()
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{subscriptions: MapSet.new(), workspace_index: %{}, window_index: %{}}}
  end

  @impl true
  def handle_info({@topology_tag, {:updated, topology}}, state) do
    {:noreply, expire_vanished_panes(topology, state)}
  end

  def handle_info({@topology_tag, {:session_terminated, %{session: session}}}, state) do
    stale =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(fn pane_id ->
        match?(%{tmux_session: ^session}, get_by_pane(pane_id))
      end)

    # One UPDATE for all vanished panes — avoid N+1 close_persisted/1 in the reduce.
    _ = close_persisted_many(stale)

    state =
      Enum.reduce(stale, state, fn pane_id, acc ->
        {reg, acc} =
          case do_deregister(pane_id, acc, persist?: false) do
            {:ok, reg, next} -> {reg, next}
            {:error, _, next} -> {nil, next}
          end

        if reg, do: broadcast(:removed, reg)
        acc
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- registration internals ---------------------------------------------------

  defp do_register(attrs, state) do
    pane_id = string_param(attrs, :pane_id)
    workspace_id = string_param(attrs, :workspace_id)

    with {:ok, pane_id} <- require_binary(pane_id, :missing_pane_id),
         {:ok, workspace_id} <- require_binary(workspace_id, :missing_workspace_id) do
      # Displace any existing file pane on the same tmux window (one per window).
      tmux_session = string_param(attrs, :tmux_session)
      window_id = string_param(attrs, :pane_window_id)

      state =
        case window_id && tmux_session && Map.get(state.window_index, {tmux_session, window_id}) do
          existing when is_binary(existing) and existing != pane_id ->
            case do_deregister(existing, state) do
              {:ok, reg, next} ->
                broadcast(:removed, reg)
                next

              {:error, _, next} ->
                next
            end

          _ ->
            state
        end

      open_files = normalize_open_files(attrs)

      registration = %{
        id: pane_id,
        pane_id: pane_id,
        workspace_id: workspace_id,
        tmux_session: tmux_session,
        pane_window_id: window_id,
        placement: string_param(attrs, :placement),
        anchor_pane_id: string_param(attrs, :anchor_pane_id),
        anchor_window_id: string_param(attrs, :anchor_window_id),
        open_files: open_files,
        active_path: string_param(attrs, :active_path) || first_path(open_files),
        status: :open
      }

      state = persist_and_store(registration, state)
      {:ok, registration, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_deregister(pane_id, state, opts \\ []) do
    case get_by_pane(pane_id) do
      nil ->
        {:error, :not_found, state}

      reg ->
        :ets.delete(@table, pane_id)

        if Keyword.get(opts, :persist?, true) do
          close_persisted(pane_id)
        end

        _ = kill_pane(reg)

        state =
          state
          |> drop_workspace_index(pane_id, reg.workspace_id)
          |> drop_window_index(reg)

        {:ok, reg, state}
    end
  end

  # Mutate a stored registration in place, persist, and reply with the new value.
  defp reply_with_mutation(state, pane_id, fun) do
    case get_by_pane(pane_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      reg ->
        updated = fun.(reg)
        state = persist_and_store(updated, state)
        {:reply, {:ok, updated}, state}
    end
  end

  defp persist_and_store(registration, state) do
    :ets.insert(@table, {registration.pane_id, registration})
    _ = persist_registration(registration)

    state
    |> put_workspace_index(registration.pane_id, registration.workspace_id)
    |> put_window_index(registration)
    |> maybe_subscribe_topology(registration.tmux_session)
  end

  # --- open_file_in_pane helpers ------------------------------------------------

  defp split_and_register(workspace_id, loc, session, anchor, window_id, rel, line, opts) do
    placement = opts[:placement] || "right"
    direction = if placement == "bottom", do: "v", else: "h"

    with {:ok, pane_id} <-
           tmux_adapter().split_pane(session, anchor, direction,
             cwd: loc_root(loc),
             command: holder_command()
           ) do
      # tmux focuses the new holder pane; restore the anchor so Ghostty keeps
      # streaming the operator's shell output instead of the holder banner.
      _ = tmux_adapter().select_pane(session, anchor)

      attrs = %{
        pane_id: pane_id,
        workspace_id: workspace_id,
        tmux_session: session,
        pane_window_id: window_id,
        placement: placement,
        anchor_pane_id: anchor,
        anchor_window_id: window_id,
        open_files: [%{path: rel, line: line}],
        active_path: rel
      }

      with {:ok, reg} <- register(attrs) do
        {:ok, %{pane_id: pane_id, registration: reg, reused: false}}
      end
    end
  end

  defp resolve_session(workspace, opts) do
    case opts[:tmux_session] || workspace_tmux_session(workspace) do
      session when is_binary(session) and session != "" -> {:ok, session}
      _ -> {:error, :no_tmux_session}
    end
  end

  defp resolve_anchor(session, opts) do
    case opts[:anchor_pane_id] do
      pane when is_binary(pane) and pane != "" ->
        {:ok, pane}

      _ ->
        case TmuxTopology.snapshot(session, tmux: tmux_adapter()).active_pane_id do
          pane when is_binary(pane) and pane != "" -> {:ok, pane}
          _ -> {:error, :no_active_pane}
        end
    end
  end

  defp resolve_window(session, anchor, opts) do
    case opts[:anchor_window_id] do
      window when is_binary(window) and window != "" ->
        {:ok, window}

      _ ->
        topology = TmuxTopology.snapshot(session, tmux: tmux_adapter())

        case Enum.find(topology.panes || [], &(&1.id == anchor)) do
          %{window_id: window_id} when is_binary(window_id) -> {:ok, window_id}
          _ -> {:error, :window_not_found}
        end
    end
  end

  # --- payload / broadcast ------------------------------------------------------

  defp build_payload(reg) do
    %{
      tabs:
        Enum.map(reg.open_files, &%{path: &1.path, title: Path.basename(&1.path), line: &1.line}),
      active_path: reg.active_path,
      active: active_payload(reg),
      workspace_id: reg.workspace_id,
      tmux_session: reg.tmux_session
    }
  end

  defp active_payload(%{active_path: nil}), do: nil

  defp active_payload(%{active_path: path} = reg) do
    line = active_line(reg, path)

    case workspace_loc(reg.workspace_id) do
      {:ok, loc} ->
        case FileAccess.read_text(loc, path) do
          {:ok, %{content: content, version: version}} ->
            %{path: path, content: content, version: version, line: line}

          {:error, reason} ->
            %{path: path, error: reason, line: line}
        end

      _ ->
        %{path: path, error: :workspace_not_found, line: line}
    end
  end

  defp active_line(reg, path) do
    case Enum.find(reg.open_files, &(&1.path == path)) do
      %{line: line} -> line
      _ -> nil
    end
  end

  # broadcast_after: wrap a GenServer mutation reply, emitting `:updated`.
  defp broadcast_after({:ok, reg}) do
    broadcast(:updated, reg)
    {:ok, reg}
  end

  defp broadcast_after(other), do: other

  defp broadcast(reason, reg) do
    payload = if reason == :removed, do: %{}, else: build_payload(reg)

    PaneEvents.broadcast(%{
      reason: reason,
      type: @pane_type,
      pane_id: reg.pane_id,
      workspace_id: reg.workspace_id,
      tmux_session: reg.tmux_session,
      payload: payload
    })
  end

  # --- indices / topology -------------------------------------------------------

  defp lookup_by_pane(pane_id) when is_binary(pane_id) do
    case :ets.lookup(@table, pane_id) do
      [{^pane_id, registration}] -> registration
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put_workspace_index(state, pane_id, workspace_id) do
    ids =
      state.workspace_index
      |> Map.get(workspace_id, [])
      |> then(&Enum.uniq([pane_id | &1]))

    %{state | workspace_index: Map.put(state.workspace_index, workspace_id, ids)}
  end

  defp drop_workspace_index(state, pane_id, workspace_id) do
    ids =
      state.workspace_index
      |> Map.get(workspace_id, [])
      |> Enum.reject(&(&1 == pane_id))

    workspace_index =
      if ids == [],
        do: Map.delete(state.workspace_index, workspace_id),
        else: Map.put(state.workspace_index, workspace_id, ids)

    %{state | workspace_index: workspace_index}
  end

  defp put_window_index(state, %{
         tmux_session: session,
         pane_window_id: window_id,
         pane_id: pane_id
       })
       when is_binary(session) and is_binary(window_id) do
    %{state | window_index: Map.put(state.window_index, {session, window_id}, pane_id)}
  end

  defp put_window_index(state, _reg), do: state

  defp drop_window_index(state, %{tmux_session: session, pane_window_id: window_id})
       when is_binary(session) and is_binary(window_id) do
    %{state | window_index: Map.delete(state.window_index, {session, window_id})}
  end

  defp drop_window_index(state, _reg), do: state

  defp maybe_subscribe_topology(state, session) when is_binary(session) and session != "" do
    if MapSet.member?(state.subscriptions, session) do
      state
    else
      _ = TmuxTopology.subscribe(session)
      %{state | subscriptions: MapSet.put(state.subscriptions, session)}
    end
  end

  defp maybe_subscribe_topology(state, _), do: state

  defp expire_vanished_panes(%{session: session, panes: panes}, state) do
    live_ids = MapSet.new(Enum.map(panes || [], & &1.id))

    # Rebuild the window index from the fresh topology so move-pane/break-pane
    # can't leave a stale {session, window} => pane mapping.
    state = refresh_window_index(state, session, panes || [])

    stale =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(fn pane_id ->
        case get_by_pane(pane_id) do
          %{tmux_session: ^session} = reg -> not MapSet.member?(live_ids, reg.pane_id)
          _ -> false
        end
      end)

    Enum.reduce(stale, state, fn pane_id, acc ->
      case do_deregister(pane_id, acc) do
        {:ok, reg, next} ->
          broadcast(:removed, reg)
          next

        {:error, _, next} ->
          next
      end
    end)
  end

  defp refresh_window_index(state, session, panes) do
    by_id = Map.new(panes, &{&1.id, &1})

    window_index =
      state.window_index
      |> Enum.reduce(%{}, fn
        {{^session, _window_id}, pane_id} = entry, acc ->
          case Map.get(by_id, pane_id) do
            %{window_id: current_window} when is_binary(current_window) ->
              Map.put(acc, {session, current_window}, pane_id)

            _ ->
              # pane gone — drop it; expire pass will deregister the registration
              _ = entry
              acc
          end

        {key, pane_id}, acc ->
          Map.put(acc, key, pane_id)
      end)

    %{state | window_index: window_index}
  end

  # --- rehydration --------------------------------------------------------------

  defp get_or_rehydrate_by_pane(pane_id, state) do
    case lookup_by_pane(pane_id) do
      nil ->
        case load_open_persisted(pane_id) do
          nil -> {nil, state}
          persisted -> rehydrate(persisted, state)
        end

      reg ->
        {reg, state}
    end
  end

  defp rehydrate_workspaces(workspace_ids, state) do
    workspace_ids
    |> load_open_persisted_for_workspaces()
    |> Enum.reduce(state, fn persisted, acc ->
      {_reg, next} = rehydrate(persisted, acc)
      next
    end)
  end

  defp rehydrate(%FilePaneRegistration{} = persisted, state) do
    reg = persisted_to_map(persisted)

    cond do
      lookup_by_pane(reg.pane_id) ->
        {lookup_by_pane(reg.pane_id), state}

      not pane_live?(reg) ->
        close_persisted(reg.pane_id)

        {nil,
         state |> drop_workspace_index(reg.pane_id, reg.workspace_id) |> drop_window_index(reg)}

      true ->
        :ets.insert(@table, {reg.pane_id, reg})

        state =
          state
          |> put_workspace_index(reg.pane_id, reg.workspace_id)
          |> put_window_index(reg)
          |> maybe_subscribe_topology(reg.tmux_session)

        {reg, state}
    end
  end

  defp pane_live?(%{tmux_session: session, pane_id: pane_id})
       when is_binary(session) and session != "" do
    session
    |> tmux_adapter().list_session_panes()
    |> Enum.any?(&(Map.get(&1, :id) == pane_id))
  rescue
    _ -> false
  end

  defp pane_live?(_), do: false

  defp list_workspace_registrations(workspace_index, workspace_ids) do
    workspace_ids
    |> Enum.flat_map(&Map.get(workspace_index, &1, []))
    |> Enum.uniq()
    |> Enum.map(&get_by_pane/1)
    |> Enum.reject(&is_nil/1)
  end

  # --- persistence --------------------------------------------------------------

  defp persistence_enabled? do
    Application.get_env(:dev_ide, :file_pane_persistence, true)
  end

  defp persist_registration(reg) do
    if persistence_enabled?() do
      attrs = %{
        workspace_id: reg.workspace_id,
        tmux_session: reg.tmux_session,
        pane_id: reg.pane_id,
        pane_window_id: reg.pane_window_id,
        placement: reg.placement,
        anchor_pane_id: reg.anchor_pane_id,
        anchor_window_id: reg.anchor_window_id,
        open_files: Enum.map(reg.open_files, &%{"path" => &1.path, "line" => &1.line}),
        active_path: reg.active_path,
        status: :open
      }

      # Partial unique index file_pane_registrations_open_pane_id_index
      # (pane_id WHERE status = 'open') — single round-trip upsert.
      case %FilePaneRegistration{}
           |> FilePaneRegistration.changeset(attrs)
           |> Repo.insert(
             on_conflict:
               {:replace,
                [
                  :workspace_id,
                  :tmux_session,
                  :pane_window_id,
                  :placement,
                  :anchor_pane_id,
                  :anchor_window_id,
                  :open_files,
                  :active_path,
                  :status,
                  :updated_at
                ]},
             conflict_target: {:unsafe_fragment, "(pane_id) WHERE (status = 'open')"}
           ) do
        {:ok, row} -> {:ok, row}
        {:error, _} = err -> err
      end
    else
      {:ok, reg}
    end
  rescue
    _ -> {:ok, reg}
  end

  defp close_persisted(pane_id) when is_binary(pane_id) do
    close_persisted_many([pane_id])
  end

  defp close_persisted_many(pane_ids) when is_list(pane_ids) do
    pane_ids =
      pane_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if pane_ids != [] and persistence_enabled?() do
      from(r in FilePaneRegistration, where: r.pane_id in ^pane_ids and r.status == :open)
      |> Repo.update_all(set: [status: :closed])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp close_all_persisted do
    if persistence_enabled?() do
      from(r in FilePaneRegistration, where: r.status == :open)
      |> Repo.update_all(set: [status: :closed])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp load_open_persisted(pane_id) do
    if persistence_enabled?() do
      Repo.one(
        from r in FilePaneRegistration,
          where: r.pane_id == ^pane_id and r.status == :open,
          limit: 1
      )
    end
  rescue
    _ -> nil
  end

  defp load_open_persisted_for_workspaces(workspace_ids) do
    ids = Enum.reject(workspace_ids, &(&1 in [nil, ""]))

    if ids == [] or not persistence_enabled?() do
      []
    else
      Repo.all(
        from r in FilePaneRegistration,
          where: r.workspace_id in ^ids and r.status == :open,
          order_by: [asc: r.inserted_at]
      )
    end
  rescue
    _ -> []
  end

  defp persisted_to_map(%FilePaneRegistration{} = r) do
    open_files = normalize_open_files(%{open_files: r.open_files})

    %{
      id: r.pane_id,
      pane_id: r.pane_id,
      workspace_id: r.workspace_id,
      tmux_session: r.tmux_session,
      pane_window_id: r.pane_window_id,
      placement: r.placement,
      anchor_pane_id: r.anchor_pane_id,
      anchor_window_id: r.anchor_window_id,
      open_files: open_files,
      active_path: r.active_path || first_path(open_files),
      status: :open
    }
  end

  # --- small helpers ------------------------------------------------------------

  defp normalize_open_files(attrs) do
    (Map.get(attrs, :open_files) || Map.get(attrs, "open_files") || [])
    |> Enum.map(&normalize_tab/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tab(%{path: path} = tab) when is_binary(path),
    do: %{path: path, line: normalize_line(Map.get(tab, :line))}

  defp normalize_tab(%{"path" => path} = tab) when is_binary(path),
    do: %{path: path, line: normalize_line(Map.get(tab, "line"))}

  defp normalize_tab(_), do: nil

  defp merge_tab(tab, nil), do: tab
  defp merge_tab(tab, line), do: %{tab | line: line}

  defp normalize_line(line) when is_integer(line) and line > 0, do: line
  defp normalize_line(_), do: nil

  defp first_path([%{path: path} | _]), do: path
  defp first_path(_), do: nil

  defp last_path(tabs) do
    case List.last(tabs) do
      %{path: path} -> path
      _ -> nil
    end
  end

  defp workspace_loc(workspace_id) do
    with {:ok, workspace} <- Workspaces.get(workspace_id),
         {:ok, loc} <- Workspaces.safe_host_loc(workspace) do
      {:ok, loc}
    else
      _ -> {:error, :workspace_not_found}
    end
  end

  defp to_rel(loc, path) do
    root = loc_root(loc)

    rel =
      if String.starts_with?(path, "/") do
        Path.relative_to(path, root)
      else
        path
      end

    case PathSafety.resolve(root, rel) do
      {:ok, _abs} -> {:ok, rel}
      {:error, _} = err -> err
    end
  end

  defp loc_root({:local, root}), do: root
  defp loc_root({:remote, _host, root}), do: root

  defp holder_command do
    Application.app_dir(:dev_ide, "priv/scripts/devide-file-pane")
  end

  defp kill_pane(%{tmux_session: session, pane_id: pane_id})
       when is_binary(session) and is_binary(pane_id) do
    tmux_adapter().kill_pane(session, pane_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp kill_pane(_), do: :ok

  defp workspace_tmux_session(workspace) do
    Map.get(workspace, :tmux_session) || Map.get(workspace, "tmux_session")
  end

  defp workspace_id(%{id: id}) when is_binary(id), do: id
  defp workspace_id(%{"id" => id}) when is_binary(id), do: id
  defp workspace_id(_), do: nil

  defp string_param(attrs, key) when is_atom(key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    case value do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp require_binary(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_value, error), do: {:error, error}

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, DevIDE.Terminals.Tmux)
  end
end
