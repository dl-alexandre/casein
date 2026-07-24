defmodule Casein.FilePanes.SuffixIndex do
  @moduledoc """
  Basename-keyed index of a local workspace's files, for terminal file-link
  fallback resolution.

  `Casein.FilePanes.LinkResolver` resolves candidates root-relatively; paths
  that miss — bare `foo.ex` names, subdir-relative `js/app.js` printed from a
  pane cd'd below the root, absolute stacktrace paths from a linked worktree —
  fall back to this index. A candidate resolves only when exactly one indexed
  file's workspace-relative path ends with it, so the fallback can never link
  to the wrong one of two plausible files.

  The index is built lazily per root by a background task owned by this
  GenServer and served from a public ETS table. Lookups before the first build
  completes return `{:error, :pending}` (LinkResolver drops those candidates
  uncached, so they linkify on a later frame). A completed index older than
  `:dev_ide, :file_link_index_ttl_ms` (default 60s) keeps answering while a
  rebuild runs in the background.

  Build cost controls: symlinks are never followed (file or directory), VCS
  and build/dependency directories are skipped, the walk is depth- and
  file-capped, and a basename accumulating too many paths overflows — its
  lookups fail as ambiguous rather than guessing.
  """

  use GenServer

  require Logger

  @table :dev_ide_file_link_suffix_index

  @ignored_dirs MapSet.new(
                  ~w(.git .hg .svn _build deps node_modules cover .elixir_ls .lexical .hex)
                )
  @max_files 50_000
  @max_depth 20
  @max_paths_per_basename 32

  # --- lifecycle ------------------------------------------------------------

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

    {:ok, %{building: %{}}}
  end

  # --- public API -------------------------------------------------------------

  @doc """
  Look up `candidate` (a relative path or bare file name) in `root`'s index.

  Returns `{:ok, workspace_relative_path}` when exactly one indexed file's
  path equals the candidate or ends with `"/" <> candidate`. `:ambiguous`
  (several matches / basename overflow) and `:not_found` are terminal;
  `:pending` means no index exists yet — a build was just scheduled and the
  caller should retry later rather than cache the miss.
  """
  @spec lookup(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :ambiguous | :not_found | :pending}
  def lookup(root, candidate) when is_binary(root) and is_binary(candidate) do
    root_key = Path.expand(root)

    case meta(root_key) do
      :missing ->
        GenServer.cast(__MODULE__, {:ensure, root_key})
        {:error, :pending}

      {:ok, built_at} ->
        if stale?(built_at), do: GenServer.cast(__MODULE__, {:ensure, root_key})
        match_candidate(root_key, candidate)
    end
  catch
    # Table missing (minimal test trees without this server): behave as an
    # always-empty index rather than crashing the frame path.
    :error, :badarg -> {:error, :not_found}
  end

  def lookup(_root, _candidate), do: {:error, :not_found}

  @doc """
  Build (or rebuild) `root`'s index synchronously. Test/ops helper — the
  render path only ever triggers background builds via `lookup/2`.
  """
  @spec rebuild(String.t()) :: :ok
  def rebuild(root) when is_binary(root) do
    GenServer.call(__MODULE__, {:rebuild, Path.expand(root)}, 30_000)
  end

  @doc "Index TTL in milliseconds (config: `:dev_ide, :file_link_index_ttl_ms`)."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: Application.get_env(:dev_ide, :file_link_index_ttl_ms, 60_000)

  @doc false
  # Test helper: drop every root's index.
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  catch
    :error, :badarg -> :ok
  end

  # --- GenServer --------------------------------------------------------------

  @impl true
  def handle_cast({:ensure, root_key}, state) do
    fresh? =
      case meta(root_key) do
        {:ok, built_at} -> not stale?(built_at)
        :missing -> false
      end

    if fresh? or Map.has_key?(state.building, root_key) do
      {:noreply, state}
    else
      server = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(server, {:index_built, root_key, walk(root_key)})
        end)

      {:noreply, put_in(state.building[root_key], {pid, ref})}
    end
  end

  @impl true
  def handle_call({:rebuild, root_key}, _from, state) do
    install(root_key, walk(root_key))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:index_built, root_key, entries}, state) do
    install(root_key, entries)

    case Map.pop(state.building, root_key) do
      {{_pid, ref}, building} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | building: building}}

      {nil, _building} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # A build task died before reporting. Drop the in-flight marker so the
    # next lookup can schedule a fresh attempt.
    case Enum.find(state.building, fn {_root, {_pid, r}} -> r == ref end) do
      {root_key, _} ->
        if reason != :normal do
          Logger.warning("SuffixIndex build for #{root_key} failed: #{inspect(reason)}")
        end

        {:noreply, %{state | building: Map.delete(state.building, root_key)}}

      nil ->
        {:noreply, state}
    end
  end

  # --- index storage ----------------------------------------------------------

  # Rows: {{root_key, basename}, generation, [rel_path] | :overflow}
  # Meta:  {{:meta, root_key}, generation, built_at_ms}
  # New generations are inserted over the old rows first, then stale rows
  # (older generation) are swept — readers see at worst a briefly mixed index,
  # never an empty one.

  defp meta(root_key) do
    case :ets.lookup(@table, {:meta, root_key}) do
      [{_key, _gen, built_at}] -> {:ok, built_at}
      [] -> :missing
    end
  end

  defp stale?(built_at), do: System.monotonic_time(:millisecond) - built_at > ttl_ms()

  defp install(root_key, entries) do
    gen =
      case :ets.lookup(@table, {:meta, root_key}) do
        [{_key, gen, _built_at}] -> gen + 1
        [] -> 1
      end

    rows = for {basename, paths} <- entries, do: {{root_key, basename}, gen, paths}
    :ets.insert(@table, rows)
    :ets.insert(@table, {{:meta, root_key}, gen, System.monotonic_time(:millisecond)})

    :ets.select_delete(@table, [
      {{{root_key, :_}, :"$1", :_}, [{:<, :"$1", gen}], [true]}
    ])

    :ok
  catch
    :error, :badarg -> :ok
  end

  defp match_candidate(root_key, candidate) do
    case :ets.lookup(@table, {root_key, Path.basename(candidate)}) do
      [{_key, _gen, :overflow}] ->
        {:error, :ambiguous}

      [{_key, _gen, paths}] ->
        suffix = "/" <> candidate

        case Enum.filter(paths, &(&1 == candidate or String.ends_with?(&1, suffix))) do
          [rel] -> {:ok, rel}
          [] -> {:error, :not_found}
          _many -> {:error, :ambiguous}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # --- filesystem walk --------------------------------------------------------

  # Breadth-first, symlink-refusing walk of the root. Returns
  # %{basename => [rel_path] | :overflow}; caps keep pathological trees from
  # holding the build task (and the ETS table) hostage.
  defp walk(root_key) do
    do_walk([{root_key, "", 0}], %{}, 0)
  end

  defp do_walk([], acc, _count), do: acc

  defp do_walk([{abs_dir, rel_prefix, depth} | rest], acc, count) do
    if count >= @max_files or depth > @max_depth do
      do_walk(rest, acc, count)
    else
      entries =
        case File.ls(abs_dir) do
          {:ok, names} -> names
          {:error, _reason} -> []
        end

      {rest, acc, count} =
        Enum.reduce(entries, {rest, acc, count}, fn name, {queue, acc, count} ->
          walk_entry(abs_dir, rel_prefix, depth, name, queue, acc, count)
        end)

      do_walk(rest, acc, count)
    end
  end

  defp walk_entry(abs_dir, rel_prefix, depth, name, queue, acc, count) do
    abs = Path.join(abs_dir, name)
    rel = if rel_prefix == "", do: name, else: rel_prefix <> "/" <> name

    case File.lstat(abs) do
      {:ok, %File.Stat{type: :directory}} ->
        if MapSet.member?(@ignored_dirs, name) do
          {queue, acc, count}
        else
          {queue ++ [{abs, rel, depth + 1}], acc, count}
        end

      {:ok, %File.Stat{type: :regular}} when count < @max_files ->
        {queue, add_path(acc, name, rel), count + 1}

      # Symlinks (never followed), devices, vanished entries, over-cap files.
      _other ->
        {queue, acc, count}
    end
  end

  defp add_path(acc, basename, rel) do
    case acc do
      %{^basename => :overflow} ->
        acc

      %{^basename => paths} when length(paths) >= @max_paths_per_basename ->
        Map.put(acc, basename, :overflow)

      %{^basename => paths} ->
        Map.put(acc, basename, [rel | paths])

      _ ->
        Map.put(acc, basename, [rel])
    end
  end
end
