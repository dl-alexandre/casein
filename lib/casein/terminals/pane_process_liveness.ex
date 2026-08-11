defmodule Casein.Terminals.PaneProcessLiveness do
  @moduledoc """
  Process/CPU liveness for a tmux pane — not the rendered spinner.

  A frozen build timer on screen is not evidence the process is dead. Supervisors
  that trusted the screen have killed live workers (observed: frozen UI while
  the pane process burned ~8% CPU). This module answers **process presence**
  from outside the TUI:

    * read `pane_pid` from tmux
    * sample cumulative CPU jiffies for that process tree from `/proc`
    * compare to the previous sample; advancing CPU ⇒ `:active`

  Advancing CPU proves the process tree is running, **not** that the agent is
  making progress (a wedged worker can burn hours of CPU with zero commits —
  see #879 for composite progress signals). Treat `:active` here as
  necessary-not-sufficient process presence.

  Absence of a prior sample is not quiet — first observation lands as
  `:unknown` with reason `:warming` after seeding the cache. A missing pid or
  vanished `/proc` entry is `:unknown` with an explicit reason, never collapsed
  into `:quiet`.
  """

  alias Casein.Terminals.TmuxRunner

  @cache_table :casein_pane_process_liveness
  # Wall time with no CPU advance before we call the tree quiet. Short enough
  # that a wedged spinner is caught quickly; long enough that a brief think
  # pause between tokens does not flap.
  @default_quiet_after_ms 15_000
  @default_cache_ttl_ms 120_000

  @type state :: :active | :quiet | :unknown

  @type sample :: %{
          pane_id: String.t(),
          pid: pos_integer() | nil,
          tree_pids: [pos_integer()],
          cpu_jiffies: non_neg_integer() | nil,
          sampled_at_ms: integer(),
          current_command: String.t() | nil
        }

  @type observation :: %{
          state: state(),
          reason: atom() | nil,
          pane_id: String.t(),
          pid: pos_integer() | nil,
          tree_pids: [pos_integer()],
          cpu_jiffies: non_neg_integer() | nil,
          cpu_jiffies_delta: non_neg_integer() | nil,
          sample_age_ms: non_neg_integer() | nil,
          current_command: String.t() | nil,
          runtime: String.t() | nil
        }

  @doc "Default quiet threshold in milliseconds."
  @spec default_quiet_after_ms() :: pos_integer()
  def default_quiet_after_ms, do: @default_quiet_after_ms

  @doc false
  @spec cache_table() :: atom()
  def cache_table,
    do: Application.get_env(:casein, :pane_process_liveness_cache_table, @cache_table)

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

  @doc """
  Observe process/CPU liveness for every pane in a tmux session.

  Returns a map of `pane_id => observation`. Options:

    * `:now_ms` — monotonic ms clock (tests)
    * `:quiet_after_ms` — wall time without CPU advance before `:quiet`
    * `:cache` — `false` skips read/write of the sample cache (still classifies
      as `:warming` on first look)
    * `:pid_reader` — `(session -> %{pane_id => sample_seed})` override
    * `:stat_reader` — `(pid -> {:ok, jiffies} | :error)` override
  """
  @spec observe_session(String.t(), keyword()) :: %{optional(String.t()) => observation()}
  def observe_session(session, opts \\ []) when is_binary(session) do
    ensure_cache_table()
    now_ms = Keyword.get(opts, :now_ms) || System.monotonic_time(:millisecond)
    seeds = pid_seeds(session, opts)

    Map.new(seeds, fn {pane_id, seed} ->
      {pane_id, observe_pane(session, pane_id, seed, now_ms, opts)}
    end)
  end

  @doc "Observe a single pane when the caller already has its pid seed."
  @spec observe_pane(String.t(), String.t(), map(), integer(), keyword()) :: observation()
  def observe_pane(session, pane_id, seed, now_ms, opts \\ [])
      when is_binary(session) and is_binary(pane_id) and is_map(seed) and is_integer(now_ms) do
    ensure_cache_table()
    pid = Map.get(seed, :pid)
    command = Map.get(seed, :current_command)

    cond do
      not is_integer(pid) or pid <= 0 ->
        unknown(pane_id, nil, command, :no_pid)

      true ->
        case read_tree_jiffies(pid, opts) do
          {:ok, tree_pids, jiffies} ->
            sample = %{
              pane_id: pane_id,
              pid: pid,
              tree_pids: tree_pids,
              cpu_jiffies: jiffies,
              sampled_at_ms: now_ms,
              current_command: command
            }

            classify_and_store(session, sample, opts)

          :error ->
            bust_cache(session, pane_id, opts)
            unknown(pane_id, pid, command, :proc_missing)
        end
    end
  end

  @doc "Infer a short runtime name from a pane's current command."
  @spec runtime_from_command(String.t() | nil) :: String.t() | nil
  def runtime_from_command(command) when is_binary(command) do
    base =
      command
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> case do
        nil -> ""
        path -> Path.basename(path)
      end
      |> String.downcase()

    cond do
      base == "" -> nil
      String.contains?(base, "opencode") -> "opencode"
      String.contains?(base, "claude") -> "claude"
      String.contains?(base, "grok") -> "grok"
      String.contains?(base, "codex") -> "codex"
      String.contains?(base, "cursor") -> "cursor"
      base in ~w(bash zsh sh fish nu) -> "shell"
      true -> base
    end
  end

  def runtime_from_command(_), do: nil

  ## Internals

  defp pid_seeds(session, opts) do
    reader = Keyword.get(opts, :pid_reader) || (&default_pid_reader/1)

    case reader.(session) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp default_pid_reader(session) do
    fmt = ~S(#{pane_id}|#{pane_pid}|#{pane_current_command})

    case TmuxRunner.run(["list-panes", "-s", "-t", session, "-F", fmt]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "|", parts: 3) do
            [pane_id, pid_s, command] ->
              Map.put(acc, pane_id, %{
                pid: parse_pid(pid_s),
                current_command: blank_to_nil(command)
              })

            [pane_id, pid_s] ->
              Map.put(acc, pane_id, %{pid: parse_pid(pid_s), current_command: nil})

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp parse_pid(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_pid(_), do: nil

  defp read_tree_jiffies(root_pid, opts) do
    stat_reader = Keyword.get(opts, :stat_reader) || (&read_proc_jiffies/1)

    # Root must still exist in /proc. A vanished pane shell is unknown, not a
    # quiet zero-jiffy tree.
    case stat_reader.(root_pid) do
      {:ok, root_jiffies} when is_integer(root_jiffies) ->
        tree = process_tree(root_pid, MapSet.new(), opts)
        pids = tree |> MapSet.to_list() |> Enum.sort()

        jiffies =
          Enum.reduce(pids, 0, fn pid, acc ->
            if pid == root_pid do
              acc + root_jiffies
            else
              case stat_reader.(pid) do
                {:ok, j} when is_integer(j) -> acc + j
                _ -> acc
              end
            end
          end)

        {:ok, pids, jiffies}

      _ ->
        :error
    end
  end

  # Breadth-first children via /proc/<pid>/task/*/children. Caps size so a
  # runaway fork bomb cannot pin the resource read.
  defp process_tree(pid, seen, opts) when is_integer(pid) do
    cond do
      MapSet.size(seen) >= 64 ->
        seen

      MapSet.member?(seen, pid) ->
        seen

      true ->
        seen = MapSet.put(seen, pid)

        Enum.reduce(child_pids(pid, opts), seen, fn child, acc ->
          process_tree(child, acc, opts)
        end)
    end
  end

  defp process_tree(_pid, seen, _opts), do: seen

  defp child_pids(pid, opts) do
    reader = Keyword.get(opts, :children_reader) || (&default_children_reader/1)
    reader.(pid)
  end

  # pid is a positive integer from tmux pane_pid / prior /proc children — never
  # attacker-controlled path input. Path is always under /proc/<pid>/task/.
  # sobelow_skip ["Traversal.FileModule"]
  defp default_children_reader(pid) when is_integer(pid) and pid > 0 do
    task_dir = "/proc/#{pid}/task"

    case File.ls(task_dir) do
      {:ok, tasks} ->
        Enum.flat_map(tasks, fn task ->
          # Task dir names are kernel tids (digits only); reject anything else
          # so a future Path.join cannot leave /proc/<pid>/task/.
          if tid?(task) do
            case File.read(Path.join([task_dir, task, "children"])) do
              {:ok, body} ->
                body
                |> String.split(~r/\s+/, trim: true)
                |> Enum.flat_map(fn tok ->
                  case Integer.parse(tok) do
                    {n, ""} when n > 0 -> [n]
                    _ -> []
                  end
                end)

              _ ->
                []
            end
          else
            []
          end
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp default_children_reader(_pid), do: []

  # /proc/<pid>/stat field 14 = utime, 15 = stime (jiffies). Comm may contain
  # spaces/parens, so split on the trailing ") " and index from there.
  # pid is a positive integer from tmux pane_pid / process-tree walk — not user
  # path input. Path is fixed-shape /proc/<pid>/stat only.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_proc_jiffies(pid) when is_integer(pid) and pid > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:ok, body} ->
        case split_stat_fields(body) do
          {:ok, fields} ->
            utime = Enum.at(fields, 11)
            stime = Enum.at(fields, 12)

            with {u, ""} <- Integer.parse(utime || ""),
                 {s, ""} <- Integer.parse(stime || "") do
              {:ok, u + s}
            else
              _ -> :error
            end

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp read_proc_jiffies(_), do: :error

  defp tid?(name) when is_binary(name) do
    byte_size(name) > 0 and match?({_, ""}, Integer.parse(name)) and
      String.match?(name, ~r/\A[1-9][0-9]*\z/)
  end

  defp tid?(_), do: false

  defp split_stat_fields(body) when is_binary(body) do
    case :binary.split(body, ") ") do
      [_prefix, rest] ->
        {:ok, String.split(rest, " ", trim: true)}

      _ ->
        :error
    end
  end

  defp classify_and_store(session, sample, opts) do
    use_cache? = Keyword.get(opts, :cache, true)
    quiet_after = Keyword.get(opts, :quiet_after_ms, @default_quiet_after_ms)
    key = cache_key(session, sample.pane_id)
    prev = if use_cache?, do: cache_lookup(key), else: :miss

    observation =
      case prev do
        {:ok, earlier} when earlier.pid == sample.pid ->
          delta = sample.cpu_jiffies - (earlier.cpu_jiffies || 0)
          age = sample.sampled_at_ms - earlier.sampled_at_ms

          cond do
            delta > 0 ->
              base_obs(sample, :active, nil, delta, age)

            age >= quiet_after ->
              base_obs(sample, :quiet, :cpu_stalled, 0, age)

            true ->
              # Too soon to call quiet — keep prior active if we had one, else unknown.
              prior_state = Map.get(earlier, :last_state, :unknown)
              state = if prior_state == :active, do: :active, else: :unknown
              reason = if state == :unknown, do: :settling, else: :cpu_stable
              base_obs(sample, state, reason, 0, age)
          end

        {:ok, _earlier} ->
          # pid recycled for this pane id
          base_obs(sample, :unknown, :pid_changed, nil, nil)

        :miss ->
          base_obs(sample, :unknown, :warming, nil, nil)
      end

    if use_cache? do
      cache_store(key, Map.put(sample, :last_state, observation.state), opts)
    end

    observation
  end

  defp base_obs(sample, state, reason, delta, age) do
    %{
      state: state,
      reason: reason,
      pane_id: sample.pane_id,
      pid: sample.pid,
      tree_pids: sample.tree_pids,
      cpu_jiffies: sample.cpu_jiffies,
      cpu_jiffies_delta: delta,
      sample_age_ms: age,
      current_command: sample.current_command,
      runtime: runtime_from_command(sample.current_command)
    }
  end

  defp unknown(pane_id, pid, command, reason) do
    %{
      state: :unknown,
      reason: reason,
      pane_id: pane_id,
      pid: pid,
      tree_pids: [],
      cpu_jiffies: nil,
      cpu_jiffies_delta: nil,
      sample_age_ms: nil,
      current_command: command,
      runtime: runtime_from_command(command)
    }
  end

  defp bust_cache(session, pane_id, opts) do
    if Keyword.get(opts, :cache, true) do
      ensure_cache_table()
      :ets.delete(cache_table(), cache_key(session, pane_id))
    end
  rescue
    ArgumentError -> :ok
  end

  defp cache_key(session, pane_id), do: {session, pane_id}

  defp cache_lookup(key) do
    case :ets.lookup(cache_table(), key) do
      [{^key, sample, stored_at}] ->
        if System.monotonic_time(:millisecond) - stored_at <= @default_cache_ttl_ms do
          {:ok, sample}
        else
          :miss
        end

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_store(key, sample, _opts) do
    :ets.insert(cache_table(), {key, sample, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end
end
