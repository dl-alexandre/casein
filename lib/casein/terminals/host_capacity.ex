defmodule Casein.Terminals.HostCapacity do
  @moduledoc """
  One read-only host-capacity contract for worker coordinators.

  Worker spawning is still guarded by `spawn-agent-worker.sh`, but coordinators
  also need the same live facts before deciding whether to fill the next wave.
  This module deliberately reports `unknown` when a probe cannot be read; an
  unavailable measurement must never be interpreted as spare capacity.
  """

  @default_max_load_ratio 1.0
  @default_min_mem_available_kb 2_097_152
  # Resident agent processes host-wide before the next launch is refused.
  # Mirrors scripts/lib/agent-budget.sh (CASEIN_AGENT_MAX_TOTAL); 0 disables.
  @default_max_agents 32

  # Processes in uninterruptible sleep. Headcount, load and memory all read
  # healthy right up to the 2026-08-28 failure while D-state climbed
  # 5 -> 9 -> 55 -> 224 (OneBackend-v3#20698), so a capacity probe that omits
  # it cannot see the one signal that predicted the crash. 0 disables.
  @default_max_d_state 32

  # Filesystem headroom on the workspace root. A worker wave's main cost is
  # disk, and the probe reported nothing about it (OneBackend-v3#19569).
  @default_min_disk_available_kb 10_485_760
  @default_disk_path "/data"

  # What counts as an agent — keep in sync with agent-budget.sh: argv[0]
  # basename in this set, or node/bun running a codex(.js) entry point. One
  # session can be two such processes (the npm codex wrapper execs a vendored
  # native codex), so a match whose parent also matched is that session's own
  # child and is not counted twice.
  @agent_bins ~w(opencode claude claude.exe claude_exe grok codex)

  @type snapshot :: %{
          observed_at: String.t(),
          available?: boolean(),
          healthy?: boolean(),
          status: String.t(),
          load1: float() | nil,
          nproc: pos_integer() | nil,
          max_load_ratio: float(),
          load_limit: float() | nil,
          load_ok?: boolean() | nil,
          mem_available_kb: non_neg_integer() | nil,
          min_mem_available_kb: non_neg_integer(),
          memory_ok?: boolean() | nil,
          agent_processes: non_neg_integer() | nil,
          max_agents: non_neg_integer(),
          agents_ok?: boolean() | nil,
          d_state_processes: non_neg_integer() | nil,
          max_d_state: non_neg_integer(),
          d_state_ok?: boolean() | nil,
          disk_path: String.t(),
          disk_available_kb: non_neg_integer() | nil,
          min_disk_available_kb: non_neg_integer(),
          disk_ok?: boolean() | nil,
          reasons: [String.t()]
        }

  @doc "Read the current host capacity without mutating the host or opening workers."
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) when is_list(opts) do
    load1 = read_load1(opts)
    nproc = read_nproc(opts)
    mem_available_kb = read_mem_available_kb(opts)
    max_load_ratio = read_ratio(Keyword.get(opts, :max_load_ratio), :max_load_ratio)
    min_mem_available_kb = read_mem_floor(Keyword.get(opts, :min_mem_available_kb))
    load_limit = if is_float(load1) and is_integer(nproc), do: nproc * max_load_ratio
    load_ok? = if is_float(load_limit) and is_float(load1), do: load1 <= load_limit

    memory_ok? =
      if is_integer(mem_available_kb),
        do: mem_available_kb >= min_mem_available_kb

    agent_processes = read_agent_processes(opts)
    max_agents = read_max_agents(Keyword.get(opts, :max_agents))

    agents_ok? =
      if is_integer(agent_processes),
        do: max_agents == 0 or agent_processes < max_agents

    d_state_processes = read_d_state(opts)

    max_d_state =
      read_limit(Keyword.get(opts, :max_d_state), "CASEIN_MAX_D_STATE", @default_max_d_state)

    d_state_ok? =
      if is_integer(d_state_processes),
        do: max_d_state == 0 or d_state_processes < max_d_state

    disk_path =
      Keyword.get(opts, :disk_path) || System.get_env("CASEIN_DISK_PATH") || @default_disk_path

    min_disk_available_kb =
      read_limit(
        Keyword.get(opts, :min_disk_available_kb),
        "CASEIN_MIN_DISK_AVAILABLE_KB",
        @default_min_disk_available_kb
      )

    # A path that does not exist is "not applicable" (dev boxes, CI), not
    # "unknown" — only a path we should be able to read and cannot is unknown.
    disk_applicable? = disk_applicable?(opts, disk_path)
    disk_available_kb = if disk_applicable?, do: read_disk_available_kb(opts, disk_path)

    disk_ok? =
      cond do
        not disk_applicable? -> nil
        is_integer(disk_available_kb) -> disk_available_kb >= min_disk_available_kb
        true -> nil
      end

    reasons =
      []
      |> maybe_reason(is_nil(load1) or is_nil(nproc), "load probe unavailable")
      |> maybe_reason(load_ok? == false, "load exceeds configured limit")
      |> maybe_reason(is_nil(mem_available_kb), "memory probe unavailable")
      |> maybe_reason(memory_ok? == false, "available memory is below configured minimum")
      |> maybe_reason(is_nil(agent_processes), "agent process probe unavailable")
      |> maybe_reason(agents_ok? == false, "resident agent count is at the configured budget")
      |> maybe_reason(is_nil(d_state_processes), "uninterruptible-sleep probe unavailable")
      |> maybe_reason(
        d_state_ok? == false,
        "processes in uninterruptible sleep exceed the configured limit"
      )
      |> maybe_reason(
        disk_applicable? and is_nil(disk_available_kb),
        "filesystem probe unavailable for #{disk_path}"
      )
      |> maybe_reason(
        disk_ok? == false,
        "available disk on #{disk_path} is below configured minimum"
      )

    available? =
      not is_nil(load1) and not is_nil(nproc) and not is_nil(mem_available_kb) and
        not is_nil(agent_processes) and not is_nil(d_state_processes) and
        (not disk_applicable? or not is_nil(disk_available_kb))

    healthy? = available? and reasons == []

    %{
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      available?: available?,
      healthy?: healthy?,
      status: status(available?, healthy?),
      load1: load1,
      nproc: nproc,
      max_load_ratio: max_load_ratio,
      load_limit: load_limit,
      load_ok?: load_ok?,
      mem_available_kb: mem_available_kb,
      min_mem_available_kb: min_mem_available_kb,
      memory_ok?: memory_ok?,
      agent_processes: agent_processes,
      max_agents: max_agents,
      agents_ok?: agents_ok?,
      d_state_processes: d_state_processes,
      max_d_state: max_d_state,
      d_state_ok?: d_state_ok?,
      disk_path: disk_path,
      disk_available_kb: disk_available_kb,
      min_disk_available_kb: min_disk_available_kb,
      disk_ok?: disk_ok?,
      reasons: reasons
    }
  end

  @doc """
  Count resident agent sessions in a `ps -eo user=,pid=,ppid=,args=` listing.
  Exposed so the launch scripts and this module cannot drift on what "an agent"
  is. A matched process whose parent also matched is a wrapper's own child and
  counts once with its parent, not twice.
  """
  @spec count_agents(String.t()) :: non_neg_integer()
  def count_agents(listing) when is_binary(listing), do: length(agent_sessions(listing))

  @doc """
  The agent sessions `count_agents/1` counts, as `%{pid, ppid, command}` maps.

  Same dedupe rule: a matched process whose parent also matched is a wrapper's
  own child and is dropped, so one session appears once. Exposed so a caller
  that needs to say something *about* each resident agent — which pane holds
  it, or that none does — cannot drift from what the budget counts.
  """
  @spec agent_sessions(String.t()) :: [%{pid: String.t(), ppid: String.t(), command: String.t()}]
  def agent_sessions(listing) when is_binary(listing) do
    matches =
      listing
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&agent_match/1)

    pids = MapSet.new(matches, fn {pid, _ppid, _cmd} -> pid end)

    for {pid, ppid, command} <- matches,
        not MapSet.member?(pids, ppid),
        do: %{pid: pid, ppid: ppid, command: command}
  end

  @doc """
  The raw `ps` listing agent counting reads from, or `nil` if the probe failed.

  `ps` is the one probe here that is a subprocess rather than a file read; it
  is argv-only (no shell) and a failure is reported as unknown, never as zero
  agents. Public so a caller that needs to say something about the *same*
  processes reads them the same way rather than shelling out again.
  """
  @spec process_listing() :: String.t() | nil
  def process_listing do
    case System.cmd("ps", ["-eo", "user=,pid=,ppid=,args="], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  `%{pid => ppid}` for every process in a `ps -eo user=,pid=,ppid=,args=`
  listing, so a caller can walk a process back to its ancestors.
  """
  @spec process_parents(String.t()) :: %{optional(String.t()) => String.t()}
  def process_parents(listing) when is_binary(listing) do
    listing
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/, trim: true) do
        [_user, pid, ppid | _] -> Map.put(acc, pid, ppid)
        _ -> acc
      end
    end)
  end

  # `[{pid, ppid, command}]` for an agent line, `[]` for anything else.
  defp agent_match(line) do
    case String.split(line, ~r/\s+/, trim: true) do
      [_user, pid, ppid, cmd | rest] ->
        base = Path.basename(cmd)

        agent? =
          cond do
            base in @agent_bins -> true
            base in ["node", "bun"] -> rest != [] and codex_script?(hd(rest))
            true -> false
          end

        if agent?, do: [{pid, ppid, base}], else: []

      _ ->
        []
    end
  end

  defp codex_script?(path), do: Path.basename(path) in ["codex", "codex.js"]

  @doc """
  Count processes in uninterruptible sleep in a `ps -eo stat=` listing.

  A `D` anywhere but the first character is a different flag (`R+`, `Ss`), so
  only the leading code counts.
  """
  @spec count_d_state(String.t()) :: non_neg_integer()
  def count_d_state(listing) when is_binary(listing) do
    listing
    |> String.split("\n", trim: true)
    |> Enum.count(&String.starts_with?(String.trim(&1), "D"))
  end

  @doc """
  Available kilobytes from a `df -Pk <path>` listing, or `nil` when the output
  is not parseable. POSIX format keeps the columns stable.
  """
  @spec parse_df_available_kb(String.t()) :: non_neg_integer() | nil
  def parse_df_available_kb(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.find_value(fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [_fs, _blocks, _used, avail | _] -> parse_integer(avail)
        _ -> nil
      end
    end)
  end

  defp read_d_state(opts) do
    case Keyword.get(opts, :d_state_reader) do
      reader when is_function(reader, 0) -> normalize_d_state(reader.())
      _ -> read_d_state_ps()
    end
  end

  defp read_d_state_ps do
    case System.cmd("ps", ["-eo", "stat="], stderr_to_stdout: true) do
      {out, 0} -> count_d_state(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_d_state(value) when is_integer(value) and value >= 0, do: value
  defp normalize_d_state(value) when is_binary(value), do: count_d_state(value)
  defp normalize_d_state(_), do: nil

  defp disk_applicable?(opts, path) do
    case Keyword.get(opts, :disk_reader) do
      reader when is_function(reader, 1) -> true
      _ -> File.dir?(path)
    end
  end

  defp read_disk_available_kb(opts, path) do
    case Keyword.get(opts, :disk_reader) do
      reader when is_function(reader, 1) -> normalize_disk(reader.(path))
      _ -> read_disk_available_kb_df(path)
    end
  end

  defp read_disk_available_kb_df(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {out, 0} -> parse_df_available_kb(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_disk(value) when is_integer(value) and value >= 0, do: value
  defp normalize_disk(value) when is_binary(value), do: parse_df_available_kb(value)
  defp normalize_disk(_), do: nil

  # Shared shape for "explicit opt, else env var, else compiled default".
  defp read_limit(explicit, env_var, default) do
    cond do
      is_integer(n = parse_integer(explicit)) and n >= 0 -> n
      is_integer(n = parse_integer(System.get_env(env_var))) and n >= 0 -> n
      true -> default
    end
  end

  defp read_agent_processes(opts) do
    case Keyword.get(opts, :agents_reader) do
      reader when is_function(reader, 0) -> normalize_count(reader.())
      _ -> read_agent_processes_ps()
    end
  end

  defp read_agent_processes_ps do
    case process_listing() do
      listing when is_binary(listing) -> count_agents(listing)
      nil -> nil
    end
  end

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(value) when is_binary(value), do: count_agents(value)
  defp normalize_count(_), do: nil

  defp read_max_agents(nil) do
    env = System.get_env("CASEIN_AGENT_MAX_TOTAL")

    case parse_integer(env) do
      n when is_integer(n) and n >= 0 -> n
      _ -> configured_max_agents()
    end
  end

  defp read_max_agents(value) do
    case parse_integer(value) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_agents
    end
  end

  defp configured_max_agents do
    case Application.get_env(:casein, :host_capacity_max_agents, @default_max_agents) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_agents
    end
  end

  defp status(false, _healthy?), do: "unknown"
  defp status(true, true), do: "healthy"
  defp status(true, false), do: "constrained"

  defp read_load1(opts) do
    case Keyword.get(opts, :load_reader) do
      reader when is_function(reader, 0) -> parse_float(reader.())
      _ -> read_load1_file()
    end
  end

  defp read_load1_file do
    with {:ok, contents} <- File.read("/proc/loadavg"),
         [load | _] <- String.split(contents, ~r/\s+/, trim: true) do
      parse_float(load)
    else
      _ -> nil
    end
  end

  defp read_nproc(opts) do
    case Keyword.get(opts, :nproc_reader) do
      reader when is_function(reader, 0) -> parse_integer(reader.())
      _ -> Keyword.get(opts, :nproc) || :erlang.system_info(:logical_processors_available)
    end
    |> normalize_positive_integer()
  end

  defp read_mem_available_kb(opts) do
    case Keyword.get(opts, :mem_reader) do
      reader when is_function(reader, 0) -> parse_integer(reader.())
      _ -> read_meminfo()
    end
  end

  defp read_meminfo do
    with {:ok, contents} <- File.read("/proc/meminfo") do
      values =
        contents
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/\A(MemAvailable|MemFree):\s+(\d+)/, line) do
            [_, key, value] -> Map.put(acc, key, String.to_integer(value))
            _ -> acc
          end
        end)

      Map.get(values, "MemAvailable") || Map.get(values, "MemFree")
    else
      _ -> nil
    end
  end

  defp read_ratio(nil, key) do
    env = System.get_env("CASEIN_SPAWN_MAX_LOAD_RATIO")
    parse_float(env) || configured_ratio(key)
  end

  defp read_ratio(value, _key), do: parse_float(value) || @default_max_load_ratio

  defp configured_ratio(:max_load_ratio) do
    case Application.get_env(:casein, :host_capacity_max_load_ratio, @default_max_load_ratio) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) and value >= 0 -> value
      _ -> @default_max_load_ratio
    end
  end

  defp read_mem_floor(nil) do
    case Application.get_env(
           :casein,
           :host_capacity_min_mem_available_kb,
           @default_min_mem_available_kb
         ) do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_min_mem_available_kb
    end
  end

  defp read_mem_floor(value), do: parse_integer(value) || @default_min_mem_available_kb

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_), do: nil

  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons
end
