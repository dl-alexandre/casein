defmodule Casein.FilePanes do
  @moduledoc """
  Registry of file-editor panes bound to tmux pane ids.

  A file pane rides a real tmux pane (tmux stays the geometry allocator) whose
  content is a native CodeMirror overlay rendered by the web layer. This module
  owns the binding + the pane's ordered list of open tabs, mirroring the shape of
  `Casein.PreviewPanes` but without any browser-control machinery.

  Policy: **one file pane per tmux window**. Opening a file in a window that
  already has a file pane reuses it and adds/activates a tab; otherwise a pane is
  split off the anchor. Agents (and the web layer) declare *intent* through
  `open_file_in_pane/3`; dev_ide owns the split/reuse/placement decision.

  State ownership: the registration persists the tab list + active path only.
  File **content and version tokens are never stored** — they are read fresh from
  disk via `Casein.Workspaces.FileAccess` on every render/save so a stale token
  can never clobber a concurrently-edited file.

  I/O (Repo + tmux) runs in `Task.Supervisor.async_nolink` offload tasks with
  per-pane serialization. ETS + `workspace_index` + `window_index` commits stay
  atomic in the GenServer process.
  """

  use GenServer

  alias Casein.FilePanes.FilePaneRegistration
  alias Casein.FilePanes.Index
  alias Casein.FilePanes.Payload
  alias Casein.FilePanes.Persistence
  alias Casein.FilePanes.Registration
  alias Casein.Terminals.TmuxTopology
  alias Casein.Workspaces
  alias Casein.Workspaces.Aliases, as: WorkspaceAliases
  alias Casein.Workspaces.FileAccess

  @table :dev_ide_file_panes
  @topology_tag Casein.Terminals.TmuxTopology
  # Register/deregister/clear wait on offloaded Repo/tmux I/O.
  @lifecycle_call_timeout 30_000

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

    {:ok, empty_state()}
  end

  defp empty_state do
    %{
      subscriptions: MapSet.new(),
      workspace_index: %{},
      window_index: %{},
      pending_ops: %{},
      inflight_panes: %{},
      op_queue: %{},
      rehydrate_keys: %{},
      flush_waiters: []
    }
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
    workspace_id = Registration.workspace_id(workspace)
    line = Registration.normalize_line(opts[:line])

    with {:ok, loc} <- Workspaces.safe_host_loc(workspace),
         {:ok, rel} <- Registration.to_rel(loc, path),
         {:ok, _preflight} <- FileAccess.read_text(loc, rel),
         {:ok, session} <- resolve_session(workspace, opts),
         {:ok, {anchor, window_id}} <- resolve_anchor_window(session, opts) do
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
    GenServer.call(__MODULE__, {:register, attrs}, @lifecycle_call_timeout)
  end

  @doc "Remove a file pane binding and kill its holder pane. Broadcasts `:removed`."
  @spec deregister(String.t()) :: :ok | {:error, :not_found}
  def deregister(pane_id) when is_binary(pane_id) do
    case GenServer.call(__MODULE__, {:deregister, pane_id}, @lifecycle_call_timeout) do
      {:ok, _reg} -> :ok
      err -> err
    end
  end

  @doc "Add-or-activate a tab. Opts: `:line`, `:activate` (default true)."
  @spec open_tab(String.t(), String.t(), keyword()) :: {:ok, registration()} | {:error, term()}
  def open_tab(pane_id, path, opts \\ []) when is_binary(pane_id) and is_binary(path) do
    Payload.broadcast_after(GenServer.call(__MODULE__, {:open_tab, pane_id, path, opts}))
  end

  @doc "Activate an already-open tab."
  @spec activate_tab(String.t(), String.t()) :: {:ok, registration()} | {:error, term()}
  def activate_tab(pane_id, path) when is_binary(pane_id) and is_binary(path) do
    Payload.broadcast_after(GenServer.call(__MODULE__, {:activate_tab, pane_id, path}))
  end

  @doc """
  Close a tab. Closing the last tab deregisters the pane and kills its holder.
  Returns `{:ok, registration | :closed}`.
  """
  @spec close_tab(String.t(), String.t()) :: {:ok, registration() | :closed} | {:error, term()}
  def close_tab(pane_id, path) when is_binary(pane_id) and is_binary(path) do
    case GenServer.call(__MODULE__, {:close_tab, pane_id, path}, @lifecycle_call_timeout) do
      {:ok, :closed, _reg} ->
        {:ok, :closed}

      {:ok, reg} ->
        Payload.broadcast(:updated, reg)
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
         {:ok, loc} <- Registration.workspace_loc(reg.workspace_id),
         {:ok, rel} <- Registration.to_rel(loc, path),
         {:ok, result} <- FileAccess.write_text(loc, rel, content, expected_version) do
      Payload.broadcast(:updated, reg)
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
         {:ok, loc} <- Registration.workspace_loc(reg.workspace_id),
         {:ok, rel} <- Registration.to_rel(loc, path) do
      FileAccess.read_text(loc, rel)
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  @doc "Lookup a registration by tmux pane id (rehydrating from the DB on a miss)."
  @spec get_by_pane(String.t()) :: registration() | nil
  def get_by_pane(pane_id) when is_binary(pane_id) do
    case Index.lookup(pane_id) do
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
  for an unknown pane so `Casein.Panes` can identify ownership.
  """
  @spec render_state(String.t()) :: map()
  def render_state(pane_id) when is_binary(pane_id) do
    case get_by_pane(pane_id) do
      nil -> %{}
      reg -> Payload.build(reg)
    end
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear, @lifecycle_call_timeout)

  @doc """
  Blocks until all previously queued Repo and tmux side effects have drained.

  Most lifecycle calls already wait for their own offloaded work. Tab mutations
  reply after their in-memory commit, so callers that require persistence before
  continuing can use this compatibility boundary.
  """
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush, @lifecycle_call_timeout)

  # --- GenServer callbacks ------------------------------------------------------

  @impl true
  def handle_call({:register, attrs}, from, state) do
    pane_id = Registration.string_param(attrs, :pane_id)
    enqueue_or_start_register(attrs, pane_id, from, state)
  end

  def handle_call({:deregister, pane_id}, from, state) do
    enqueue_or_start_deregister(pane_id, from, state, persist?: true)
  end

  def handle_call({:open_tab, pane_id, path, opts}, from, state) do
    case Index.lookup(pane_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      reg ->
        activate? = Keyword.get(opts, :activate, true) != false
        line = Registration.normalize_line(opts[:line])
        tab = %{path: path, line: line}

        open_files =
          case Enum.find_index(reg.open_files, &(&1.path == path)) do
            nil ->
              reg.open_files ++ [tab]

            idx ->
              List.replace_at(
                reg.open_files,
                idx,
                Registration.merge_tab(Enum.at(reg.open_files, idx), line)
              )
          end

        updated = %{
          reg
          | open_files: open_files,
            active_path: if(activate?, do: path, else: reg.active_path)
        }

        # In-memory mutation + reply first; offload only the Repo upsert.
        state = store_registration(updated, state)
        GenServer.reply(from, {:ok, updated})
        enqueue_or_start_tab_persist(pane_id, updated, state)
    end
  end

  def handle_call({:activate_tab, pane_id, path}, from, state) do
    case Index.lookup(pane_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      reg ->
        updated =
          if Enum.any?(reg.open_files, &(&1.path == path)) do
            %{reg | active_path: path}
          else
            reg
          end

        state = store_registration(updated, state)
        GenServer.reply(from, {:ok, updated})
        enqueue_or_start_tab_persist(pane_id, updated, state)
    end
  end

  def handle_call({:close_tab, pane_id, path}, from, state) do
    case Index.lookup(pane_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      reg ->
        remaining = Enum.reject(reg.open_files, &(&1.path == path))

        if remaining == [] do
          enqueue_or_start_deregister(pane_id, from, state, persist?: true, reply: :closed)
        else
          active_path =
            if reg.active_path == path,
              do: Registration.last_path(remaining),
              else: reg.active_path

          updated = %{reg | open_files: remaining, active_path: active_path}
          state = store_registration(updated, state)
          GenServer.reply(from, {:ok, updated})
          enqueue_or_start_tab_persist(pane_id, updated, state)
        end
    end
  end

  def handle_call({:get_by_pane, pane_id}, from, state) do
    case Index.lookup(pane_id) do
      %{} = registration ->
        {:reply, registration, state}

      nil ->
        start_or_join_rehydrate(
          {:pane, pane_id},
          from,
          state,
          fn ->
            case Persistence.load_open(pane_id) do
              nil -> {:rehydrate_done, []}
              persisted -> {:rehydrate_done, [rehydrate_io_result(persisted)]}
            end
          end
        )
    end
  end

  def handle_call({:get_by_window, session, window_id}, _from, state) do
    reg =
      case Map.get(state.window_index, {session, window_id}) do
        nil -> nil
        pane_id -> Index.lookup(pane_id)
      end

    {:reply, reg, state}
  end

  def handle_call({:list_for_workspace, workspace_ids}, from, state) do
    key = {:workspaces, Enum.sort(workspace_ids)}

    start_or_join_rehydrate(
      key,
      from,
      state,
      fn ->
        results =
          workspace_ids
          |> Persistence.load_open_for_workspaces()
          |> Enum.map(&rehydrate_io_result/1)

        {:rehydrate_done, results}
      end,
      list_reply: workspace_ids
    )
  end

  def handle_call(:clear, from, state) do
    :ets.delete_all_objects(@table)

    # Unblock any waiters so clear() in test setup cannot hang behind crashed tasks.
    Enum.each(state.pending_ops, fn {_ref, op} ->
      reply_op(op, {:error, :file_cleared})
      reply_rehydrate_waiters(op, nil)
    end)

    # Queued (not-yet-started) ops would otherwise be silently dropped with
    # empty_state and their callers left hanging for the full call timeout.
    Enum.each(state.op_queue, fn {_pane_id, q} ->
      Enum.each(:queue.to_list(q), fn
        {_kind, _payload, waiter} when not is_nil(waiter) ->
          GenServer.reply(waiter, {:error, :file_cleared})

        _ ->
          :ok
      end)
    end)

    offload_op(
      from,
      :clear,
      nil,
      nil,
      fn ->
        Persistence.close_all()
        :ok
      end,
      %{empty_state() | pending_ops: %{}, flush_waiters: state.flush_waiters}
    )
  end

  def handle_call(:flush, from, state) do
    if idle_ops?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | flush_waiters: [from | state.flush_waiters]}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending_ops, ref) do
      {nil, _} ->
        {:noreply, state}

      {op, pending} ->
        state = %{state | pending_ops: pending}
        state = commit_op(op, result, state)
        {:noreply, maybe_notify_flush_waiters(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case pop_pending_op_for_pid(state.pending_ops, pid) do
      nil ->
        {:noreply, state}

      {ref, op, pending} ->
        state = %{state | pending_ops: pending}
        state = clear_rehydrate_key(state, op)

        # Rehydrate-kind callers expect `registration | nil` or a list, never an
        # error tuple — fall back to the committed state shape.
        case op do
          %{kind: :rehydrate} ->
            reply = rehydrate_fallback_reply(op, state)
            reply_op(op, reply)
            reply_rehydrate_waiters(op, reply)

          _ ->
            reply_op(op, {:error, :file_op_crashed})
            reply_rehydrate_waiters(op, nil)
        end

        state = clear_inflight(state, op.pane_id, ref)
        state = drain_op_queue(state, op.pane_id)
        {:noreply, maybe_notify_flush_waiters(state)}
    end
  end

  def handle_info({@topology_tag, {:updated, topology}}, state) do
    state = expire_vanished_panes(topology, state)
    {:noreply, state}
  end

  def handle_info({@topology_tag, {:session_terminated, %{session: session}}}, state) do
    pane_ids =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(fn pane_id ->
        match?(%{tmux_session: ^session}, Index.lookup(pane_id))
      end)

    if pane_ids == [] do
      {:noreply, state}
    else
      # Batch Repo close in a task, then state-first deregisters (persist?: false).
      offload_op(
        nil,
        :session_terminated_persist,
        nil,
        %{pane_ids: pane_ids},
        fn ->
          _ = Persistence.close_many(pane_ids)
          {:session_terminated_persist_done, pane_ids}
        end,
        state
      )
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Offload infrastructure -------------------------------------------------

  defp offload_op(from, kind, pane_id, plan, fun, state) do
    caller =
      case from do
        {pid, _tag} when is_pid(pid) -> pid
        _ -> self()
      end

    task =
      Task.Supervisor.async_nolink(Casein.TaskSupervisor, fn ->
        # Prepend the originating caller's pid so Ecto sandbox ownership
        # resolves to the test process (not the named FilePanes singleton).
        Process.put(:"$callers", [caller | List.wrap(Process.get(:"$callers"))])

        if kind in [:register, :deregister, :tab_persist, :session_terminated_persist] do
          maybe_test_io_delay()
        end

        if kind == :rehydrate, do: maybe_test_rehydrate_delay()

        fun.()
      end)

    grant_repo_sandbox(task.pid, [self(), caller])
    Process.monitor(task.pid)

    op = %{
      from: from,
      pid: task.pid,
      kind: kind,
      pane_id: pane_id,
      plan: plan,
      waiters: []
    }

    state = %{state | pending_ops: Map.put(state.pending_ops, task.ref, op)}

    state =
      if is_binary(pane_id) do
        %{state | inflight_panes: Map.put(state.inflight_panes, pane_id, task.ref)}
      else
        state
      end

    {:noreply, state}
  end

  defp pop_pending_op_for_pid(pending, pid) do
    Enum.find_value(pending, fn
      {ref, %{pid: ^pid} = op} -> {ref, op, Map.delete(pending, ref)}
      _ -> nil
    end)
  end

  defp grant_repo_sandbox(task_pid, parents) when is_pid(task_pid) do
    Enum.each(parents, fn parent ->
      try do
        :ok = Ecto.Adapters.SQL.Sandbox.allow(Casein.Repo, parent, task_pid)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp maybe_test_io_delay do
    case Application.get_env(:casein, :file_panes_test_io_delay_ms) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  defp maybe_test_rehydrate_delay do
    case Application.get_env(:casein, :file_panes_test_rehydrate_delay_ms) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  defp reply_op(%{from: from}, result) when not is_nil(from), do: GenServer.reply(from, result)
  defp reply_op(_op, _result), do: :ok

  defp reply_rehydrate_waiters(%{waiters: waiters}, result) when is_list(waiters) do
    Enum.each(waiters, &GenServer.reply(&1, result))
  end

  defp reply_rehydrate_waiters(_op, _result), do: :ok

  defp idle_ops?(state) do
    map_size(state.pending_ops) == 0 and
      map_size(state.inflight_panes) == 0 and
      map_size(state.op_queue) == 0 and
      map_size(state.rehydrate_keys) == 0
  end

  defp maybe_notify_flush_waiters(%{flush_waiters: []} = state), do: state

  defp maybe_notify_flush_waiters(state) do
    if idle_ops?(state) do
      Enum.each(state.flush_waiters, &GenServer.reply(&1, :ok))
      %{state | flush_waiters: []}
    else
      state
    end
  end

  defp clear_inflight(state, pane_id, ref) when is_binary(pane_id) do
    case Map.get(state.inflight_panes, pane_id) do
      ^ref -> %{state | inflight_panes: Map.delete(state.inflight_panes, pane_id)}
      _ -> state
    end
  end

  defp clear_inflight(state, _pane_id, _ref), do: state

  defp clear_rehydrate_key(state, %{plan: %{rehydrate_key: key}}) when not is_nil(key) do
    case Map.get(state.rehydrate_keys, key) do
      ref when is_reference(ref) ->
        %{state | rehydrate_keys: Map.delete(state.rehydrate_keys, key)}

      _ ->
        state
    end
  end

  defp clear_rehydrate_key(state, _op), do: state

  defp enqueue_op(state, pane_id, kind, payload, from) when is_binary(pane_id) do
    q = Map.get(state.op_queue, pane_id, :queue.new())
    q = :queue.in({kind, payload, from}, q)
    %{state | op_queue: Map.put(state.op_queue, pane_id, q)}
  end

  defp drain_op_queue(state, pane_id) when is_binary(pane_id) do
    case Map.get(state.op_queue, pane_id) do
      nil ->
        state

      q ->
        case :queue.out(q) do
          {:empty, _} ->
            %{state | op_queue: Map.delete(state.op_queue, pane_id)}

          {{:value, {kind, payload, from}}, q2} ->
            state =
              if :queue.is_empty(q2) do
                %{state | op_queue: Map.delete(state.op_queue, pane_id)}
              else
                %{state | op_queue: Map.put(state.op_queue, pane_id, q2)}
              end

            case start_queued_op(kind, payload, from, state) do
              {:noreply, next} ->
                next

              {:reply, reply, next} ->
                if from, do: GenServer.reply(from, reply)
                next
            end
        end
    end
  end

  defp drain_op_queue(state, _pane_id), do: state

  defp start_queued_op(:register, attrs, from, state) do
    pane_id = Registration.string_param(attrs, :pane_id)
    start_register(attrs, pane_id, from, state)
  end

  defp start_queued_op(:deregister, %{pane_id: pane_id, opts: opts}, from, state) do
    begin_deregister(pane_id, state, Keyword.put(opts, :from, from))
  end

  defp start_queued_op(:tab_persist, registration, _from, state) do
    pane_id = registration.pane_id
    start_tab_persist(pane_id, registration, state)
  end

  defp enqueue_or_start_register(attrs, pane_id, from, state) do
    if is_binary(pane_id) and Map.has_key?(state.inflight_panes, pane_id) do
      {:noreply, enqueue_op(state, pane_id, :register, attrs, from)}
    else
      start_register(attrs, pane_id, from, state)
    end
  end

  defp start_register(attrs, pane_id, from, state) do
    case Registration.build(attrs) do
      {:ok, registration} ->
        # Displace any existing file pane on the same tmux window (one per window).
        state = maybe_displace_window_peer(registration, pane_id, state)

        plan = %{registration: registration}

        offload_op(
          from,
          :register,
          pane_id,
          plan,
          fn ->
            case Persistence.upsert(registration) do
              {:ok, _} -> {:register_done, registration}
              {:error, reason} -> {:error, reason}
            end
          end,
          state
        )

      {:error, reason} ->
        if from do
          {:reply, {:error, reason}, state}
        else
          {:noreply, state}
        end
    end
  end

  # Displaces a COMMITTED peer pane in the same {session,window} (one file pane
  # per window). `begin_deregister` is state-first (ETS lookup), so it only
  # displaces panes that have finished registering.
  #
  # KNOWN GAP (tracked debt, low-severity, self-heals): `window_index` for the
  # NEW pane is written at commit time (`store_registration`), past the offload,
  # not here. So if a second cold register for the same window interleaves
  # between this register's start and its commit, it sees no peer to displace and
  # both commit — ETS transiently holds two panes for one window until the next
  # topology broadcast reaps the loser via `expire_vanished_panes`. The original
  # synchronous code displaced immediately. A full fix reserves the slot here and
  # adds a commit-time "is the window still ours?" check with loser self-
  # deregistration; deferred to keep this offload change low-risk. The invariant
  # is UI-only (one pane per window) and eventually-consistent, never a safety
  # or persistence hole.
  defp maybe_displace_window_peer(registration, pane_id, state) do
    session = registration.tmux_session
    window_id = registration.pane_window_id

    case is_binary(session) && is_binary(window_id) &&
           Map.get(state.window_index, {session, window_id}) do
      existing when is_binary(existing) and existing != pane_id ->
        case begin_deregister(existing, state, persist?: true, from: nil) do
          {:noreply, next} -> next
          {:reply, _, next} -> next
        end

      _ ->
        state
    end
  end

  defp enqueue_or_start_deregister(pane_id, from, state, opts) do
    if is_binary(pane_id) and Map.has_key?(state.inflight_panes, pane_id) do
      {:noreply, enqueue_op(state, pane_id, :deregister, %{pane_id: pane_id, opts: opts}, from)}
    else
      begin_deregister(pane_id, state, Keyword.put(opts, :from, from))
    end
  end

  # State-first deregister (ETS + both indexes), then offload I/O tail.
  defp begin_deregister(pane_id, state, opts) do
    from = Keyword.get(opts, :from)
    persist? = Keyword.get(opts, :persist?, true)
    reply = Keyword.get(opts, :reply, :ok)

    case Index.lookup(pane_id) do
      nil ->
        if from do
          {:reply, {:error, :not_found}, state}
        else
          {:noreply, state}
        end

      registration ->
        :ets.delete(@table, pane_id)

        state = %{
          state
          | workspace_index:
              Index.drop_workspace(
                state.workspace_index,
                pane_id,
                registration.workspace_id
              ),
            window_index: Index.drop_window(state.window_index, registration)
        }

        plan = %{
          registration: registration,
          persist?: persist?,
          reply: reply
        }

        offload_op(
          from,
          :deregister,
          pane_id,
          plan,
          fn -> run_deregister_io(plan) end,
          state
        )
    end
  end

  defp run_deregister_io(%{
         registration: registration,
         persist?: persist?
       }) do
    if persist? do
      Persistence.close(registration.pane_id)
    end

    _ = kill_pane(registration)
    {:deregister_done, registration}
  end

  defp enqueue_or_start_tab_persist(pane_id, registration, state) do
    if is_binary(pane_id) and Map.has_key?(state.inflight_panes, pane_id) do
      {:noreply, enqueue_op(state, pane_id, :tab_persist, registration, nil)}
    else
      start_tab_persist(pane_id, registration, state)
    end
  end

  defp start_tab_persist(pane_id, registration, state) do
    offload_op(
      nil,
      :tab_persist,
      pane_id,
      %{registration: registration},
      fn ->
        _ = Persistence.upsert(registration)
        {:tab_persist_done, registration.pane_id}
      end,
      state
    )
  end

  # ---- commit (server) --------------------------------------------------------

  defp commit_op(%{kind: :clear} = op, result, state) do
    reply_op(op, result)
    state
  end

  defp commit_op(%{kind: :register, pane_id: pane_id} = op, result, state) do
    state =
      case result do
        {:register_done, registration} ->
          # Atomic commit: ETS + workspace_index + window_index + subscription.
          state = store_registration(registration, state)
          Payload.broadcast(:registered, registration)
          reply_op(op, {:ok, registration})
          state

        {:error, reason} ->
          reply_op(op, {:error, reason})
          state

        other when is_tuple(other) ->
          reply_op(op, other)
          state

        other ->
          reply_op(op, {:error, other})
          state
      end

    state = %{state | inflight_panes: Map.delete(state.inflight_panes, pane_id)}
    drain_op_queue(state, pane_id)
  end

  defp commit_op(%{kind: :deregister, pane_id: pane_id, plan: plan} = op, result, state) do
    registration = plan.registration

    case result do
      {:deregister_done, _} ->
        Payload.broadcast(:removed, registration)

        case plan.reply do
          :closed -> reply_op(op, {:ok, :closed, registration})
          _ -> reply_op(op, {:ok, registration})
        end

      {:error, reason} ->
        reply_op(op, {:error, reason})

      other ->
        reply_op(op, other)
    end

    state = %{state | inflight_panes: Map.delete(state.inflight_panes, pane_id)}
    drain_op_queue(state, pane_id)
  end

  defp commit_op(%{kind: :tab_persist, pane_id: pane_id}, _result, state) do
    state = %{state | inflight_panes: Map.delete(state.inflight_panes, pane_id)}
    drain_op_queue(state, pane_id)
  end

  defp commit_op(%{kind: :rehydrate} = op, result, state) do
    state = clear_rehydrate_key(state, op)

    {reply, state} =
      case result do
        {:rehydrate_done, io_results} when is_list(io_results) ->
          {state, dead_pane_ids} =
            Enum.reduce(io_results, {state, []}, fn item, {acc, dead} ->
              case commit_rehydrate_item(item, acc) do
                {:drop_close, pane_id, next} -> {next, [pane_id | dead]}
                next -> {next, dead}
              end
            end)

          # Close dead persisted rows off-server (never from the GenServer).
          state =
            case Enum.uniq(dead_pane_ids) do
              [] ->
                state

              pane_ids ->
                {:noreply, next} =
                  offload_op(
                    nil,
                    :rehydrate_close,
                    nil,
                    %{pane_ids: pane_ids},
                    fn ->
                      _ = Persistence.close_many(pane_ids)
                      :ok
                    end,
                    state
                  )

                next
            end

          reply =
            case op.plan do
              %{list_reply: workspace_ids} when is_list(workspace_ids) ->
                Index.list_registrations(state.workspace_index, workspace_ids)

              %{rehydrate_key: {:pane, pane_id}} ->
                Index.lookup(pane_id)

              _ ->
                nil
            end

          {reply, state}

        {:error, _} ->
          {rehydrate_fallback_reply(op, state), state}

        _ ->
          {rehydrate_fallback_reply(op, state), state}
      end

    reply_op(op, reply)
    reply_rehydrate_waiters(op, reply)
    state
  end

  defp commit_op(%{kind: :session_terminated_persist} = op, result, state) do
    _ = op

    case result do
      {:session_terminated_persist_done, pane_ids} when is_list(pane_ids) ->
        Enum.reduce(pane_ids, state, fn pane_id, acc ->
          # Respect the per-pane queue: a concurrent in-flight register must not
          # have its inflight ref clobbered — queue the deregister behind it.
          if is_binary(pane_id) and Map.has_key?(acc.inflight_panes, pane_id) do
            enqueue_op(
              acc,
              pane_id,
              :deregister,
              %{pane_id: pane_id, opts: [persist?: false]},
              nil
            )
          else
            case begin_deregister(pane_id, acc, persist?: false, from: nil) do
              {:noreply, next} -> next
              {:reply, _, next} -> next
            end
          end
        end)

      _ ->
        state
    end
  end

  defp commit_op(%{kind: :rehydrate_close} = _op, _result, state), do: state

  defp commit_op(op, result, state) do
    reply_op(op, result)
    state
  end

  # Shape-correct fallback for a rehydrate op whose IO failed or crashed.
  defp rehydrate_fallback_reply(%{plan: %{list_reply: workspace_ids}}, state)
       when is_list(workspace_ids) do
    Index.list_registrations(state.workspace_index, workspace_ids)
  end

  defp rehydrate_fallback_reply(%{plan: %{rehydrate_key: {:pane, pane_id}}}, _state) do
    Index.lookup(pane_id)
  end

  defp rehydrate_fallback_reply(_op, _state), do: nil

  defp commit_rehydrate_item({:commit, registration}, state) when is_map(registration) do
    pane_id = registration.pane_id

    cond do
      Map.has_key?(state.inflight_panes, pane_id) ->
        # Lifecycle op owns this pane — skip rehydrate commit.
        state

      Index.lookup(pane_id) ->
        state

      true ->
        store_registration(registration, state)
    end
  end

  # Dead on the wire, but ETS may already hold a live registration (list rehydrate
  # races with a warm path). Never close or drop indexes for panes the server owns.
  defp commit_rehydrate_item({:drop, reg}, state) when is_map(reg) do
    pane_id = reg.pane_id

    cond do
      Map.has_key?(state.inflight_panes, pane_id) ->
        state

      Index.lookup(pane_id) ->
        state

      true ->
        next = %{
          state
          | workspace_index:
              Index.drop_workspace(state.workspace_index, pane_id, reg.workspace_id),
            window_index: Index.drop_window(state.window_index, reg)
        }

        {:drop_close, pane_id, next}
    end
  end

  defp commit_rehydrate_item(:drop, state), do: state
  defp commit_rehydrate_item(_, state), do: state

  # pane_live? runs only in offload tasks. Closing dead rows is deferred to the
  # GenServer commit so we never close_persisted a pane still live in ETS.
  defp rehydrate_io_result(%FilePaneRegistration{} = persisted) do
    reg = Registration.from_persisted(persisted)

    if pane_live?(reg) do
      {:commit, reg}
    else
      {:drop, reg}
    end
  end

  defp start_or_join_rehydrate(key, from, state, fun, opts \\ []) do
    case Map.get(state.rehydrate_keys, key) do
      ref when is_reference(ref) ->
        case Map.get(state.pending_ops, ref) do
          %{kind: :rehydrate} = op ->
            op = %{op | waiters: [from | op.waiters]}
            {:noreply, %{state | pending_ops: Map.put(state.pending_ops, ref, op)}}

          _ ->
            start_rehydrate(key, from, state, fun, opts)
        end

      _ ->
        start_rehydrate(key, from, state, fun, opts)
    end
  end

  defp start_rehydrate(key, from, state, fun, opts) do
    list_reply = Keyword.get(opts, :list_reply)

    plan = %{
      rehydrate_key: key,
      list_reply: list_reply
    }

    {:noreply, state} = offload_op(from, :rehydrate, nil, plan, fun, state)

    ref =
      Enum.find_value(state.pending_ops, fn
        {r, %{kind: :rehydrate, plan: %{rehydrate_key: ^key}}} -> r
        _ -> nil
      end)

    state =
      if is_reference(ref) do
        %{state | rehydrate_keys: Map.put(state.rehydrate_keys, key, ref)}
      else
        state
      end

    {:noreply, state}
  end

  # --- registration store -----------------------------------------------------

  # Atomic in-server commit of ETS + both indexes + topology subscription.
  defp store_registration(registration, state) do
    :ets.insert(@table, {registration.pane_id, registration})

    %{
      state
      | workspace_index:
          Index.put_workspace(
            state.workspace_index,
            registration.pane_id,
            registration.workspace_id
          ),
        window_index: Index.put_window(state.window_index, registration)
    }
    |> maybe_subscribe_topology(registration.tmux_session)
  end

  # --- open_file_in_pane helpers ------------------------------------------------

  defp split_and_register(workspace_id, loc, session, anchor, window_id, rel, line, opts) do
    placement = opts[:placement] || "right"
    direction = if placement == "bottom", do: "v", else: "h"

    with {:ok, pane_id} <-
           tmux_adapter().split_pane(session, anchor, direction,
             cwd: Registration.loc_root(loc),
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
    case opts[:tmux_session] || Registration.workspace_tmux_session(workspace) do
      session when is_binary(session) and session != "" -> {:ok, session}
      _ -> {:error, :no_tmux_session}
    end
  end

  # At most one topology snapshot: both anchors given → zero; otherwise one.
  defp resolve_anchor_window(session, opts) do
    case {opts[:anchor_pane_id], opts[:anchor_window_id]} do
      {pane, window}
      when is_binary(pane) and pane != "" and is_binary(window) and window != "" ->
        {:ok, {pane, window}}

      {pane, _} when is_binary(pane) and pane != "" ->
        topology = TmuxTopology.snapshot(session, tmux: tmux_adapter())

        case Enum.find(topology.panes || [], &(&1.id == pane)) do
          %{window_id: window_id} when is_binary(window_id) -> {:ok, {pane, window_id}}
          _ -> {:error, :window_not_found}
        end

      _ ->
        topology = TmuxTopology.snapshot(session, tmux: tmux_adapter())

        case topology.active_pane_id do
          pane when is_binary(pane) and pane != "" ->
            case Enum.find(topology.panes || [], &(&1.id == pane)) do
              %{window_id: window_id} when is_binary(window_id) -> {:ok, {pane, window_id}}
              _ -> {:error, :window_not_found}
            end

          _ ->
            {:error, :no_active_pane}
        end
    end
  end

  # --- indices / topology -------------------------------------------------------

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
    state = %{
      state
      | window_index: Index.refresh_window(state.window_index, session, panes || [])
    }

    stale =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(fn pane_id ->
        case Index.lookup(pane_id) do
          %{tmux_session: ^session} = reg -> not MapSet.member?(live_ids, reg.pane_id)
          _ -> false
        end
      end)

    if stale == [] do
      state
    else
      # Batch Repo close off-server (frequent path), then state-first deregisters.
      {:noreply, next} =
        offload_op(
          nil,
          :session_terminated_persist,
          nil,
          %{pane_ids: stale},
          fn ->
            _ = Persistence.close_many(stale)
            {:session_terminated_persist_done, stale}
          end,
          state
        )

      next
    end
  end

  # pane_live? runs only in offload tasks (rehydrate I/O) — never in the GenServer.
  defp pane_live?(%{tmux_session: session, pane_id: pane_id})
       when is_binary(session) and session != "" do
    session
    |> tmux_adapter().list_session_panes()
    |> Enum.any?(&(Map.get(&1, :id) == pane_id))
  rescue
    _ -> false
  end

  defp pane_live?(_), do: false

  # --- tmux helpers (stay here; used by split_and_register / run_deregister_io) --

  defp holder_command do
    Application.app_dir(:casein, "priv/scripts/devide-file-pane")
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

  defp tmux_adapter do
    Application.get_env(:casein, :tmux_adapter, Casein.Terminals.Tmux)
  end
end
