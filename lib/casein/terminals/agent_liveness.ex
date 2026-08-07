defmodule Casein.Terminals.AgentLiveness do
  @moduledoc """
  Externally observed liveness for an agent, derived from its worktree.

  Every other agent signal Casein has is *cooperative*: `AgentState` reports
  arrive over MCP or hooks, and the `PaneState` title heuristic reads a spinner
  the agent itself draws. Both describe an agent that is well enough to describe
  itself. A wedged agent — one whose provider rejects every request, or whose TUI
  has stopped processing input — reports nothing and leaves its last spinner on
  screen, so it is indistinguishable from an idle one.

  This module answers the same question from the outside: *has this agent's
  worktree changed on disk recently, and has it committed anything?* An agent
  that cannot write files is not working, whatever its pane says.

  ## Absence is not evidence

  The trap this module exists to close is that "no writes found" and "the scan
  did not run" are the same empty result to a caller, and a silent zero reads as
  a confident stall. `observe/2` therefore never collapses the two:

    * `{:error, reason}` — the worktree could not be scanned. Says nothing about
      the agent.
    * `{:ok, %{last_write_at: nil}}` — the scan ran and found no files at all.
    * `{:ok, %{last_write_at: %DateTime{}}}` — the scan ran and this is the
      newest write.

  `classify/2` collapses an observation to `:active | :quiet`, and callers with
  an `{:error, _}` must render `:unknown` rather than "quiet".

  ## Cost

  One pruned walk per worktree, capped at `@scan_limit` entries and cached for
  `cache_ttl_ms`. Build and dependency directories dominate a checkout's file
  count and never reflect agent thinking, so they are pruned; `.git` is pruned
  because git's own bookkeeping writes would make every repo look active.
  """

  @scan_limit 20_000
  @default_activity_window_seconds 180
  @default_cache_ttl_ms 10_000
  @cache_table :casein_agent_liveness_cache

  # Pruned from the walk: their mtimes track compilation and package management,
  # not the agent. `.git` in particular is written by any `git status` a shell
  # prompt runs, which would make an abandoned worktree look permanently active.
  @pruned_dirs ~w(.git _build deps node_modules .elixir_ls .lexical cover priv/static/assets)

  @type observation :: %{
          worktree_path: String.t(),
          observed_at: DateTime.t(),
          last_write_at: DateTime.t() | nil,
          quiet_for_seconds: non_neg_integer() | nil,
          files_scanned: non_neg_integer(),
          truncated?: boolean(),
          head_sha: String.t() | nil,
          commit_count: non_neg_integer() | nil
        }

  @type error_reason :: :enoent | :not_a_directory | :no_path

  @doc """
  Observe a worktree's on-disk activity.

  Returns `{:error, reason}` when the path cannot be scanned — callers must not
  treat that as "no activity". Options:

    * `:now` — the reference time (defaults to `DateTime.utc_now/0`)
    * `:cache` — set `false` to force a fresh scan
    * `:git` — set `false` to skip the git half (mtimes only)
  """
  @spec observe(String.t() | nil, keyword()) :: {:ok, observation()} | {:error, error_reason()}
  def observe(worktree_path, opts \\ [])

  def observe(worktree_path, opts) when is_binary(worktree_path) and worktree_path != "" do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    if Keyword.get(opts, :cache, true) do
      case cache_lookup(worktree_path) do
        {:ok, cached} -> {:ok, refresh_quiet_for(cached, now)}
        :miss -> observe_uncached(worktree_path, now, opts)
      end
    else
      observe_uncached(worktree_path, now, opts)
    end
  end

  def observe(_worktree_path, _opts), do: {:error, :no_path}

  @doc """
  Collapse an observation into `:active` or `:quiet`.

  `:active` means the worktree was written to within the activity window
  (`:window_seconds`, default #{@default_activity_window_seconds}s). A worktree
  with no files at all is `:quiet` — it scanned fine, there is just nothing
  there.

  There is deliberately no `classify/2` clause for an error: an unscannable
  worktree tells you nothing, and callers must reach `:unknown` themselves
  rather than have it hidden behind a default here.
  """
  @spec classify(observation(), keyword()) :: :active | :quiet
  def classify(%{quiet_for_seconds: nil}, _opts), do: :quiet

  def classify(%{quiet_for_seconds: quiet_for}, opts) when is_integer(quiet_for) do
    window = Keyword.get(opts, :window_seconds, @default_activity_window_seconds)
    if quiet_for <= window, do: :active, else: :quiet
  end

  @doc "The default activity window, in seconds."
  @spec default_activity_window_seconds() :: pos_integer()
  def default_activity_window_seconds, do: @default_activity_window_seconds

  @doc """
  Whether two observations of the same worktree show forward progress.

  Commit count is the strongest signal — an agent that committed since the last
  look is unambiguously working, even if it is now between file writes. A newer
  `last_write_at` is the weaker one.
  """
  @spec progressed?(observation() | nil, observation() | nil) :: boolean()
  def progressed?(%{} = earlier, %{} = later) do
    commits_advanced?(earlier, later) or wrote_since?(earlier, later)
  end

  def progressed?(_earlier, _later), do: false

  @doc false
  @spec cache_table() :: atom()
  def cache_table, do: Application.get_env(:casein, :agent_liveness_cache_table, @cache_table)

  @doc false
  @spec ensure_cache_table() :: :ok
  def ensure_cache_table do
    table = cache_table()

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  ## Scanning

  defp observe_uncached(worktree_path, now, opts) do
    with :ok <- ensure_directory(worktree_path) do
      {latest_mtime, files_scanned, truncated?} = scan(worktree_path)
      last_write_at = to_datetime(latest_mtime)

      {head_sha, commit_count} =
        if Keyword.get(opts, :git, true), do: git_facts(worktree_path), else: {nil, nil}

      observation =
        %{
          worktree_path: worktree_path,
          observed_at: now,
          last_write_at: last_write_at,
          quiet_for_seconds: quiet_for(last_write_at, now),
          files_scanned: files_scanned,
          truncated?: truncated?,
          head_sha: head_sha,
          commit_count: commit_count
        }

      cache_store(worktree_path, observation)
      {:ok, observation}
    end
  end

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :not_a_directory}
      {:error, _} -> {:error, :enoent}
    end
  end

  # Breadth-first so the cap, when hit, spends its budget near the top of the
  # tree rather than deep inside one branch.
  defp scan(root) do
    scan_queue([root], root, nil, 0, false)
  end

  defp scan_queue([], _root, latest, count, truncated?), do: {latest, count, truncated?}

  defp scan_queue(_queue, _root, latest, count, _truncated?) when count >= @scan_limit,
    do: {latest, count, true}

  defp scan_queue([dir | rest], root, latest, count, truncated?) do
    case File.ls(dir) do
      {:ok, entries} ->
        {next_dirs, latest, count} =
          Enum.reduce(entries, {[], latest, count}, fn entry, {dirs, latest, count} ->
            path = Path.join(dir, entry)

            cond do
              count >= @scan_limit ->
                {dirs, latest, count}

              pruned?(path, root) ->
                {dirs, latest, count}

              true ->
                visit(path, dirs, latest, count)
            end
          end)

        scan_queue(rest ++ next_dirs, root, latest, count, truncated? or count >= @scan_limit)

      {:error, _reason} ->
        # An unreadable subdirectory is not a failed scan — skip it and keep the
        # rest of the tree's evidence.
        scan_queue(rest, root, latest, count, truncated?)
    end
  end

  defp visit(path, dirs, latest, count) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        {[path | dirs], latest, count}

      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        {dirs, max_mtime(latest, mtime), count + 1}

      # Symlinks are not followed: a link into a shared tree would attribute
      # another agent's writes to this worktree.
      _ ->
        {dirs, latest, count}
    end
  end

  defp pruned?(path, root) do
    relative = Path.relative_to(path, root)
    base = Path.basename(path)

    base in @pruned_dirs or relative in @pruned_dirs
  end

  defp max_mtime(nil, mtime), do: mtime
  defp max_mtime(current, mtime) when mtime > current, do: mtime
  defp max_mtime(current, _mtime), do: current

  defp to_datetime(nil), do: nil
  defp to_datetime(mtime) when is_integer(mtime), do: DateTime.from_unix!(mtime)

  defp quiet_for(nil, _now), do: nil
  defp quiet_for(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :second), 0)

  # The cached observation keeps its scan results but must not keep its staleness
  # arithmetic — a worktree gets quieter while the cache entry sits there.
  defp refresh_quiet_for(observation, now) do
    %{
      observation
      | observed_at: now,
        quiet_for_seconds: quiet_for(observation.last_write_at, now)
    }
  end

  ## Git

  defp git_facts(worktree_path) do
    {git_output(worktree_path, ["rev-parse", "HEAD"]),
     worktree_path |> git_output(["rev-list", "--count", "HEAD"]) |> to_integer()}
  end

  defp git_output(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _status} -> nil
    end
  rescue
    # git missing, or cwd vanished between the stat and here.
    ErlangError -> nil
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp commits_advanced?(%{commit_count: earlier}, %{commit_count: later})
       when is_integer(earlier) and is_integer(later),
       do: later > earlier

  defp commits_advanced?(_earlier, _later), do: false

  defp wrote_since?(%{last_write_at: %DateTime{} = earlier}, %{last_write_at: %DateTime{} = later}),
       do: DateTime.compare(later, earlier) == :gt

  defp wrote_since?(_earlier, _later), do: false

  ## Cache

  defp cache_lookup(worktree_path) do
    ensure_cache_table()
    ttl = Application.get_env(:casein, :agent_liveness_cache_ttl_ms, @default_cache_ttl_ms)

    case :ets.lookup(cache_table(), worktree_path) do
      [{^worktree_path, observation, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at <= ttl do
          {:ok, observation}
        else
          :miss
        end

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_store(worktree_path, observation) do
    ensure_cache_table()

    :ets.insert(
      cache_table(),
      {worktree_path, observation, System.monotonic_time(:millisecond)}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end
end
