defmodule Casein.Signals.DiskPressureWatch do
  @moduledoc """
  Always-on host filesystem pressure watcher.

  Usage is classified into healthy, warning, and alarm levels. A notification
  is emitted only when the level changes, so a sustained pressure episode does
  not produce one alarm per sample.
  """

  use GenServer
  require Logger

  alias Casein.Audit

  @pubsub Casein.PubSub
  @ops_topic "ops:health"
  @workspace_id "_ops"
  @warning_action "disk.pressure_warning"
  @alarm_action "disk.pressure_alarm"
  @recovered_action "disk.pressure_recovered"

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

  @doc "Read the latest cached filesystem usage from OTP `:disksup`."
  @spec sample_disk_usage(String.t()) :: {:ok, map()} | {:error, term()}
  def sample_disk_usage(mount) when is_binary(mount) do
    # `:disksup` is maintained by OTP's `:os_mon` application. Reading its
    # latest data is a local GenServer call, so this watcher never shells out
    # or parses `df` on each sample.
    case Enum.find(:disksup.get_disk_data(), fn {mounted_on, _total_kb, _capacity} ->
           List.to_string(mounted_on) == mount
         end) do
      {mounted_on, total_kb, used_percent} ->
        {:ok,
         %{
           mount: List.to_string(mounted_on),
           total_kb: total_kb,
           used_percent: used_percent
         }}

      nil ->
        {:error, {:mount_not_found, mount}}
    end
  catch
    :exit, reason -> {:error, {:disksup_exit, reason}}
  end

  @doc "Recent samples, newest first. Retained only in the watcher process."
  def recent_samples(server \\ __MODULE__), do: GenServer.call(server, :recent_samples)

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
    cfg = Application.fetch_env!(:casein, :disk_pressure_watch)

    state = %{
      mount: setting(opts, cfg, :mount),
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
      raise ArgumentError, "disk warning threshold must be below alarm threshold"
    end

    if state.schedule?, do: tighten_disksup_interval()
    if state.schedule?, do: send(self(), :sample)
    {:ok, state}
  end

  # `:disksup.get_disk_data/0` returns a CACHE, and OTP refreshes it every 30
  # minutes by default. Without this, polling every 10s at alarm level just
  # re-reads data that can be half an hour old — the adaptive intervals would be
  # decorative and the alarm would lag by up to 30 minutes, which is exactly the
  # delay this watcher exists to remove.
  #
  # One minute is OTP's floor (`set_check_interval/1` takes whole minutes), so no
  # sub-minute tier can be fresher than that. The tiers below a minute still
  # serve a purpose — they re-evaluate promptly after the cache refreshes — but
  # they cannot outrun the source.
  defp tighten_disksup_interval do
    :disksup.set_check_interval(1)
    :ok
  catch
    # os_mon may be absent (e.g. a trimmed release or a test node). A watcher
    # that cannot tighten the interval is degraded, not broken — it still
    # samples, just against OTP's default refresh.
    :exit, reason ->
      require Logger
      Logger.warning("disk_pressure_watch: could not set :disksup interval: #{inspect(reason)}")
      :ok
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
    case invoke_sampler(state.sampler, state.mount) do
      {:ok, %{used_percent: used_percent} = sample} ->
        level = classify(used_percent, state.warning_percent, state.alarm_percent)
        action = transition(state.level, level)
        sample = Map.put(sample, :sampled_at_ms, invoke_clock(state.clock))
        state = %{state | level: level, samples: retain_sample(state, sample)}
        state = apply_transition(state, action, sample)
        {{:ok, sample}, state}

      {:error, reason} ->
        Logger.warning("disk pressure sample failed for #{state.mount}: #{inspect(reason)}")
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

    log_transition(level, state.mount, used_percent)

    :telemetry.execute(
      [:casein, :signals, :disk_pressure],
      %{used_percent: used_percent},
      %{
        kind: level,
        mount: state.mount,
        warning_percent: state.warning_percent,
        alarm_percent: state.alarm_percent
      }
    )

    risk = %{
      id: :disk_pressure,
      severity: severity_for(level),
      subject: state.mount,
      detected_at: DateTime.utc_now(),
      evidence: %{
        level: level,
        used_percent: used_percent,
        warning_percent: state.warning_percent,
        alarm_percent: state.alarm_percent,
        mount: state.mount
      },
      suggestion: suggestion_for(level)
    }

    _ =
      Audit.emit!(%{
        workspace_id: @workspace_id,
        actor_id: "disk_pressure_watch",
        action: action,
        source: "ops",
        target_type: "filesystem",
        target_ref: state.mount,
        metadata: %{
          "kind" => Atom.to_string(level),
          "used_percent" => used_percent,
          "warning_percent" => state.warning_percent,
          "alarm_percent" => state.alarm_percent,
          "mount" => state.mount
        }
      })

    Phoenix.PubSub.broadcast(
      @pubsub,
      @ops_topic,
      {:ops_health, :disk_pressure, event_kind(level), risk}
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

  defp invoke_sampler(fun, mount) when is_function(fun, 1), do: fun.(mount)
  defp invoke_sampler({module, function}, mount), do: apply(module, function, [mount])

  defp invoke_sampler({module, function, args}, mount),
    do: apply(module, function, args ++ [mount])

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

  defp log_transition(:healthy, mount, used_percent) do
    Logger.info("disk pressure recovered on #{mount}: #{used_percent}% used")
  end

  defp log_transition(level, mount, used_percent) do
    Logger.warning("disk pressure #{level} on #{mount}: #{used_percent}% used")
  end

  defp suggestion_for(:healthy), do: "Filesystem usage returned below the warning threshold."

  defp suggestion_for(:warning) do
    "Filesystem usage is elevated. Inspect growth and cleanup jobs before it reaches alarm."
  end

  defp suggestion_for(:alarm) do
    "Filesystem usage is critical. Stop avoidable writes and reclaim space immediately."
  end
end
