defmodule Casein.Signals.MemoryPressureWatch do
  @moduledoc """
  Always-on host memory pressure watcher — the sibling of
  `Casein.Signals.DiskPressureWatch`.

  Motivation: on 2026-08-27 the devbox ran out of memory under ~66 resident
  agent processes and had to be hard-reset. The host watchdog *sampled*
  `MemAvailable` the whole time but never alerted on it, and its alerts only
  went to a file nobody reads. This watcher reads `/proc/meminfo` itself (no
  dependency on the external watchdog), classifies used memory into healthy /
  warning / alarm, and on each *transition* emits an audit event on the
  box-global `"_ops"` workspace — visible in the operator drawer, routed to OS
  push at alarm level by `Casein.Signals.AlertsRouter` via `Casein.Alerts` —
  and an `{:ops_health, :memory_pressure, :raised | :cleared, risk}` broadcast
  on `"ops:health"` for `Casein.Operator.SituationServer`.

  When readable, each sample also carries the agent slice's own usage
  (`casein-agents.slice`: `memory.current` against `memory.high`) so the alert
  says whether it is the agent fleet or something else eating the box.

  A notification is emitted only when the level changes, so a sustained
  pressure episode does not produce one alarm per sample.
  """

  use GenServer
  require Logger

  alias Casein.Audit

  @pubsub Casein.PubSub
  @ops_topic "ops:health"
  @workspace_id "_ops"
  @warning_action "memory.pressure_warning"
  @alarm_action "memory.pressure_alarm"
  @recovered_action "memory.pressure_recovered"

  @meminfo_path "/proc/meminfo"

  @type level :: :healthy | :warning | :alarm

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Audit action emitted when usage crosses the warning threshold."
  def warning_action, do: @warning_action

  @doc "Audit action emitted when usage crosses the alarm threshold."
  def alarm_action, do: @alarm_action

  @doc "Audit action emitted when usage returns below the warning threshold."
  def recovered_action, do: @recovered_action

  @doc false
  def sample_now(server \\ __MODULE__), do: GenServer.call(server, :sample_now)

  @doc "Recent samples, newest first. Retained only in the watcher process."
  def recent_samples(server \\ __MODULE__), do: GenServer.call(server, :recent_samples)

  @doc """
  Read host memory from `/proc/meminfo` (and the agent slice's cgroup memory
  files when present). `used_percent` is `100 - MemAvailable/MemTotal`, i.e.
  it treats reclaimable page cache as free — the number that actually predicts
  an OOM. Returns `{:error, _}` on any host without a readable meminfo.
  """
  @spec sample_memory(keyword()) :: {:ok, map()} | {:error, term()}
  def sample_memory(opts \\ []) do
    path = Keyword.get(opts, :meminfo_path, @meminfo_path)
    slice_dir = Keyword.get(opts, :agent_slice_dir) || agent_slice_dir()

    with {:ok, contents} <- File.read(path),
         %{"MemTotal" => total, "MemAvailable" => available} <- parse_meminfo(contents),
         true <- total > 0 do
      used_percent = Float.round((total - available) / total * 100, 1)

      {:ok,
       %{
         used_percent: used_percent,
         mem_total_kb: total,
         mem_available_kb: available
       }
       |> Map.merge(agent_slice_usage(slice_dir))}
    else
      {:error, reason} -> {:error, {:meminfo_unreadable, reason}}
      _ -> {:error, :meminfo_malformed}
    end
  end

  @doc false
  @spec classify(number(), number(), number()) :: level()
  def classify(used_percent, warning_percent, alarm_percent)
      when is_number(used_percent) and is_number(warning_percent) and
             is_number(alarm_percent) do
    cond do
      used_percent >= alarm_percent -> :alarm
      used_percent >= warning_percent -> :warning
      true -> :healthy
    end
  end

  @doc false
  @spec transition(level(), level()) :: :noop | {:emit, level()}
  def transition(level, level), do: :noop
  def transition(_previous, current), do: {:emit, current}

  @impl true
  def init(opts) do
    cfg = Application.fetch_env!(:casein, :memory_pressure_watch)

    state = %{
      warning_percent: setting(opts, cfg, :warning_percent),
      alarm_percent: setting(opts, cfg, :alarm_percent),
      healthy_interval_ms: setting(opts, cfg, :healthy_interval_ms),
      warning_interval_ms: setting(opts, cfg, :warning_interval_ms),
      alarm_interval_ms: setting(opts, cfg, :alarm_interval_ms),
      sampler: setting(opts, cfg, :sampler),
      clock: setting(opts, cfg, :clock),
      sample_cap: setting(opts, cfg, :sample_cap),
      sample_retention_ms: setting(opts, cfg, :sample_retention_ms),
      schedule?: Keyword.get(opts, :schedule?, true),
      level: :healthy,
      samples: [],
      timer: nil
    }

    if state.warning_percent >= state.alarm_percent do
      raise ArgumentError, "memory warning threshold must be below alarm threshold"
    end

    if state.schedule?, do: send(self(), :sample)
    {:ok, state}
  end

  @impl true
  def handle_call(:sample_now, _from, state) do
    {reply, state} = take_sample(state)
    {:reply, reply, state}
  end

  def handle_call(:recent_samples, _from, state) do
    {:reply, state.samples, state}
  end

  @impl true
  def handle_info(:sample, state) do
    {_reply, state} = take_sample(%{state | timer: nil})
    {:noreply, schedule_next(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{timer: timer}) do
    if timer, do: Process.cancel_timer(timer)
    :ok
  end

  defp take_sample(state) do
    case invoke_sampler(state.sampler) do
      {:ok, %{used_percent: used_percent} = sample} ->
        level = classify(used_percent, state.warning_percent, state.alarm_percent)
        action = transition(state.level, level)
        sample = Map.put(sample, :sampled_at_ms, invoke_clock(state.clock))
        state = %{state | level: level, samples: retain_sample(state, sample)}
        state = apply_transition(state, action, sample)
        {{:ok, sample}, state}

      {:error, reason} ->
        Logger.warning("memory pressure sample failed: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  defp apply_transition(state, :noop, _sample), do: state

  defp apply_transition(state, {:emit, level}, sample) do
    announce(level, state, sample)
    state
  end

  defp announce(level, state, sample) do
    action = action_for(level)
    used_percent = sample.used_percent

    log_transition(level, sample)

    :telemetry.execute(
      [:casein, :signals, :memory_pressure],
      %{used_percent: used_percent},
      %{
        kind: level,
        warning_percent: state.warning_percent,
        alarm_percent: state.alarm_percent
      }
    )

    evidence =
      sample
      |> Map.take([
        :used_percent,
        :mem_total_kb,
        :mem_available_kb,
        :agent_slice_used_percent,
        :agent_slice_current_kb,
        :agent_slice_high_kb
      ])
      |> Map.merge(%{
        level: level,
        warning_percent: state.warning_percent,
        alarm_percent: state.alarm_percent
      })

    risk = %{
      id: :memory_pressure,
      severity: severity_for(level),
      subject: "host memory",
      detected_at: DateTime.utc_now(),
      evidence: evidence,
      suggestion: suggestion_for(level, sample)
    }

    _ =
      Audit.emit!(%{
        workspace_id: @workspace_id,
        actor_id: "memory_pressure_watch",
        action: action,
        source: "ops",
        target_type: "host",
        target_ref: "memory",
        metadata:
          evidence
          |> Map.new(fn {k, v} -> {Atom.to_string(k), stringify(v)} end)
      })

    Phoenix.PubSub.broadcast(
      @pubsub,
      @ops_topic,
      {:ops_health, :memory_pressure, event_kind(level), risk}
    )
  end

  defp schedule_next(%{schedule?: false} = state), do: state

  defp schedule_next(state) do
    interval = Map.fetch!(state, interval_key(state.level))
    %{state | timer: Process.send_after(self(), :sample, interval)}
  end

  # Retention is bounded by both age and count; whichever bound is reached
  # first wins. Samples never leave process memory and are never persisted.
  defp retain_sample(state, sample) do
    cutoff = sample.sampled_at_ms - state.sample_retention_ms

    [sample | state.samples]
    |> Enum.take_while(&(&1.sampled_at_ms >= cutoff))
    |> Enum.take(state.sample_cap)
  end

  defp setting(opts, cfg, key), do: Keyword.get(opts, key, Keyword.fetch!(cfg, key))

  defp invoke_sampler(fun) when is_function(fun, 0), do: fun.()
  defp invoke_sampler({module, function}), do: apply(module, function, [])
  defp invoke_sampler({module, function, args}), do: apply(module, function, args)

  defp invoke_clock(fun) when is_function(fun, 0), do: fun.()
  defp invoke_clock({module, function, args}), do: apply(module, function, args)

  defp action_for(:warning), do: @warning_action
  defp action_for(:alarm), do: @alarm_action
  defp action_for(:healthy), do: @recovered_action

  defp event_kind(:healthy), do: :cleared
  defp event_kind(_level), do: :raised

  defp severity_for(:healthy), do: :info
  defp severity_for(:warning), do: :warn
  defp severity_for(:alarm), do: :alarm

  defp interval_key(:healthy), do: :healthy_interval_ms
  defp interval_key(:warning), do: :warning_interval_ms
  defp interval_key(:alarm), do: :alarm_interval_ms

  defp log_transition(:healthy, sample) do
    Logger.info("memory pressure recovered: #{describe(sample)}")
  end

  defp log_transition(level, sample) do
    Logger.warning("memory pressure #{level}: #{describe(sample)}")
  end

  defp describe(sample) do
    base = "#{sample.used_percent}% used"

    case sample do
      %{agent_slice_used_percent: pct} when is_number(pct) ->
        base <> ", agent slice at #{pct}% of its memory.high"

      _ ->
        base
    end
  end

  defp suggestion_for(:healthy, _sample),
    do: "Host memory usage returned below the warning threshold."

  defp suggestion_for(level, sample) do
    where =
      case sample do
        %{agent_slice_used_percent: pct} when is_number(pct) and pct >= 70 ->
          "The agent fleet (casein-agents.slice) is the main consumer — reap idle agent " <>
            "panes or stop launching new ones."

        %{agent_slice_used_percent: pct} when is_number(pct) ->
          "The agent slice is only at #{pct}% of its cap; look outside it " <>
            "(app, postgres, docker) for the growth."

        _ ->
          "Check the largest resident processes."
      end

    case level do
      :warning -> "Host memory is elevated. " <> where
      :alarm -> "Host memory is critical — the OOM killer is close. " <> where
    end
  end

  defp parse_meminfo(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/\A(MemTotal|MemAvailable|MemFree):\s+(\d+)/, line) do
        [_, key, value] -> Map.put(acc, key, String.to_integer(value))
        _ -> acc
      end
    end)
    |> then(fn map ->
      # Kernels without MemAvailable (pre-3.14) — fall back to MemFree so the
      # watcher still reports something rather than nothing.
      case map do
        %{"MemAvailable" => _} -> map
        %{"MemFree" => free} -> Map.put(map, "MemAvailable", free)
        _ -> map
      end
    end)
  end

  # Resolve the realised cgroup of casein-agents.slice. systemd nests slices by
  # name, so this is normally /sys/fs/cgroup/casein.slice/casein-agents.slice;
  # never hard-code it. Returns nil when systemd/cgroup v2 is not there.
  defp agent_slice_dir do
    Application.get_env(:casein, :agent_slice_cgroup_dir) ||
      Enum.find(
        [
          "/sys/fs/cgroup/casein.slice/casein-agents.slice",
          "/sys/fs/cgroup/casein-agents.slice"
        ],
        &File.dir?/1
      )
  end

  defp agent_slice_usage(nil), do: %{}

  defp agent_slice_usage(dir) do
    with {:ok, current} <- read_cgroup_bytes(Path.join(dir, "memory.current")),
         {:ok, high} <- read_cgroup_bytes(Path.join(dir, "memory.high")) do
      %{
        agent_slice_current_kb: div(current, 1024),
        agent_slice_high_kb: if(is_integer(high), do: div(high, 1024)),
        agent_slice_used_percent:
          if(is_integer(high) and high > 0, do: Float.round(current / high * 100, 1))
      }
    else
      _ -> %{}
    end
  end

  # cgroup v2 memory files hold either an integer of bytes or the word "max".
  defp read_cgroup_bytes(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "max" -> {:ok, :max}
          digits -> {:ok, String.to_integer(digits)}
        end

      error ->
        error
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp stringify(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp stringify(value), do: value
end
