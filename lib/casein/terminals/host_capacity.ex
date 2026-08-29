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

  # What counts as an agent — keep in sync with agent-budget.sh: argv[0]
  # basename in this set, or node/bun running a codex(.js) entry point.
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

    reasons =
      []
      |> maybe_reason(is_nil(load1) or is_nil(nproc), "load probe unavailable")
      |> maybe_reason(load_ok? == false, "load exceeds configured limit")
      |> maybe_reason(is_nil(mem_available_kb), "memory probe unavailable")
      |> maybe_reason(memory_ok? == false, "available memory is below configured minimum")
      |> maybe_reason(is_nil(agent_processes), "agent process probe unavailable")
      |> maybe_reason(agents_ok? == false, "resident agent count is at the configured budget")

    available? =
      not is_nil(load1) and not is_nil(nproc) and not is_nil(mem_available_kb) and
        not is_nil(agent_processes)

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
      reasons: reasons
    }
  end

  @doc """
  Count resident agent processes in a `ps -eo user=,args=` listing. Exposed so
  the launch scripts and this module cannot drift on what "an agent" is.
  """
  @spec count_agents(String.t()) :: non_neg_integer()
  def count_agents(listing) when is_binary(listing) do
    listing
    |> String.split("\n", trim: true)
    |> Enum.count(&agent_line?/1)
  end

  defp agent_line?(line) do
    case String.split(line, ~r/\s+/, trim: true) do
      [_user, cmd | rest] ->
        base = Path.basename(cmd)

        cond do
          base in @agent_bins -> true
          base in ["node", "bun"] -> rest != [] and codex_script?(hd(rest))
          true -> false
        end

      _ ->
        false
    end
  end

  defp codex_script?(path), do: Path.basename(path) in ["codex", "codex.js"]

  defp read_agent_processes(opts) do
    case Keyword.get(opts, :agents_reader) do
      reader when is_function(reader, 0) -> normalize_count(reader.())
      _ -> read_agent_processes_ps()
    end
  end

  # `ps` is the one probe here that is a subprocess rather than a file read;
  # it is argv-only (no shell) and a failure is reported as unknown, never as
  # zero agents.
  defp read_agent_processes_ps do
    case System.cmd("ps", ["-eo", "user=,args="], stderr_to_stdout: true) do
      {out, 0} -> count_agents(out)
      _ -> nil
    end
  rescue
    _ -> nil
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
