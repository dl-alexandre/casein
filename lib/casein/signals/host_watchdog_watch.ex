defmodule Casein.Signals.HostWatchdogWatch do
  @moduledoc """
  Makes a dead host watchdog announce itself.

  `Casein.Terminals.HostHealth` already classifies an old `status.json` as
  `stale` and never as healthy — but nothing *acted* on that. After the
  2026-08-27 crash the watchdog timer missed its boot trigger and stayed dead
  for 66 hours; the Host row kept serving the crash-time numbers (load 781 on
  a box at load 11) with `alerts_available?: false`, so the one channel that
  could have said "the watchdog is down" was down with it
  (OneBackend-v3#20165).

  This watcher samples `HostHealth.snapshot/0` on a timer. When the snapshot is
  not fresh (`stale` or `unknown`) for `confirm_samples` consecutive samples it
  emits `host.watchdog_stale` on the box-global `"_ops"` workspace — operator
  drawer plus OS push via `Casein.Alerts` — and broadcasts
  `{:ops_health, :host_watchdog, :raised, risk}` on `"ops:health"`. The first
  fresh sample afterwards emits `host.watchdog_recovered` / `:cleared`. Only
  transitions emit, so a dead watchdog is one alert, not one per sample.
  """

  use GenServer
  require Logger

  alias Casein.Audit

  @pubsub Casein.PubSub
  @ops_topic "ops:health"
  @workspace_id "_ops"
  @stale_action "host.watchdog_stale"
  @recovered_action "host.watchdog_recovered"

  @type level :: :fresh | :stale

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Audit action emitted when the watchdog has stopped sampling."
  def stale_action, do: @stale_action

  @doc "Audit action emitted when a fresh sample appears again."
  def recovered_action, do: @recovered_action

  @doc false
  def sample_now(server \\ __MODULE__), do: GenServer.call(server, :sample_now)

  @doc false
  @spec classify(map()) :: level()
  def classify(%{fresh?: true}), do: :fresh
  def classify(_snapshot), do: :stale

  @impl true
  def init(opts) do
    cfg = Application.fetch_env!(:casein, :host_watchdog_watch)

    state = %{
      interval_ms: setting(opts, cfg, :interval_ms),
      confirm_samples: setting(opts, cfg, :confirm_samples),
      sampler: setting(opts, cfg, :sampler),
      schedule?: Keyword.get(opts, :schedule?, true),
      level: :fresh,
      stale_streak: 0,
      timer: nil
    }

    if state.schedule?, do: send(self(), :sample)
    {:ok, state}
  end

  @impl true
  def handle_call(:sample_now, _from, state) do
    {reply, state} = take_sample(state)
    {:reply, reply, state}
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
    snapshot = invoke_sampler(state.sampler)

    streak =
      case classify(snapshot) do
        :stale -> state.stale_streak + 1
        :fresh -> 0
      end

    # Raising waits for `confirm_samples` misses so one slow watchdog run is
    # not an alert; clearing is immediate — a fresh sample is proof.
    level = if streak >= state.confirm_samples, do: :stale, else: :fresh
    state = %{state | stale_streak: streak}

    state =
      if level == state.level do
        state
      else
        announce(level, snapshot)
        %{state | level: level}
      end

    {{:ok, %{level: level, streak: streak, snapshot: snapshot}}, state}
  rescue
    error ->
      Logger.warning("host watchdog sample failed: #{inspect(error)}")
      {{:error, error}, state}
  end

  defp announce(level, snapshot) do
    evidence = %{
      state: Map.get(snapshot, :state),
      recorded_state: Map.get(snapshot, :recorded_state),
      sampled_at: Map.get(snapshot, :sampled_at),
      age_seconds: Map.get(snapshot, :age_seconds),
      reason: Map.get(snapshot, :reason),
      alerts_available: Map.get(snapshot, :alerts_available?),
      alerts_unavailable_reason: Map.get(snapshot, :alerts_unavailable_reason),
      host: Map.get(snapshot, :host)
    }

    log_transition(level, evidence)

    :telemetry.execute(
      [:casein, :signals, :host_watchdog],
      %{age_seconds: evidence.age_seconds || 0},
      %{kind: level}
    )

    risk = %{
      id: :host_watchdog,
      severity: severity_for(level),
      subject: "host watchdog",
      detected_at: DateTime.utc_now(),
      evidence: evidence,
      suggestion: suggestion_for(level, evidence)
    }

    _ =
      Audit.emit!(%{
        workspace_id: @workspace_id,
        actor_id: "host_watchdog_watch",
        action: action_for(level),
        source: "ops",
        target_type: "host",
        target_ref: "watchdog",
        metadata: Map.new(evidence, fn {k, v} -> {Atom.to_string(k), v} end)
      })

    Phoenix.PubSub.broadcast(
      @pubsub,
      @ops_topic,
      {:ops_health, :host_watchdog, event_kind(level), risk}
    )
  end

  defp schedule_next(%{schedule?: false} = state), do: state

  defp schedule_next(state) do
    %{state | timer: Process.send_after(self(), :sample, state.interval_ms)}
  end

  defp setting(opts, cfg, key), do: Keyword.get(opts, key, Keyword.fetch!(cfg, key))

  defp invoke_sampler(fun) when is_function(fun, 0), do: fun.()
  defp invoke_sampler({module, function}), do: apply(module, function, [])
  defp invoke_sampler({module, function, args}), do: apply(module, function, args)

  defp action_for(:stale), do: @stale_action
  defp action_for(:fresh), do: @recovered_action

  defp event_kind(:stale), do: :raised
  defp event_kind(:fresh), do: :cleared

  defp severity_for(:stale), do: :warn
  defp severity_for(:fresh), do: :info

  defp log_transition(:fresh, evidence) do
    Logger.info("host watchdog recovered: sampled_at=#{evidence.sampled_at}")
  end

  defp log_transition(:stale, evidence) do
    Logger.warning(
      "host watchdog stale: state=#{evidence.state} last sample #{evidence.sampled_at || "never"} " <>
        "(#{evidence.age_seconds || "?"}s ago) alerts_available=#{evidence.alerts_available}"
    )
  end

  defp suggestion_for(:fresh, _evidence), do: "The host watchdog is sampling again."

  defp suggestion_for(:stale, evidence) do
    age =
      case evidence.age_seconds do
        s when is_integer(s) and s >= 3600 -> "#{div(s, 3600)}h"
        s when is_integer(s) and s >= 60 -> "#{div(s, 60)}m"
        s when is_integer(s) -> "#{s}s"
        _ -> "an unknown time"
      end

    "The host watchdog has not written a sample for #{age}; the Host row's numbers are " <>
      "that old, not current. On the devbox: `systemctl list-timers casein-host-watchdog.timer` " <>
      "and `sudo systemctl start casein-host-watchdog.service`; trust terminal_host_capacity " <>
      "for live load/memory meanwhile."
  end
end
