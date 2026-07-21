defmodule DevIDE.Signals.DegradationWatch do
  @moduledoc """
  Second consumer on `DevIDE.SignalBus`: watches audit-derived signals for
  *degradation storms* — the same signal firing repeatedly with an identical
  degraded payload — and raises one loud alert per episode.

  Motivated by the live db_isolation bug: `workspace.db_isolation_detected`
  fired 15× with an identical `{isolation: unknown, source: none}` classification
  and nothing noticed until an operator read the bus by hand. A healthy detector
  varies its output; a *stuck* one repeats the same degraded payload. So the
  general signal is: one fingerprint (action + workspace + the classification
  metadata that should vary) repeating past a threshold inside a window.

  Config-driven so new signal types are a config entry, not code:

      config :dev_ide, :degradation_watch_rules, [
        %{action: "workspace.db_isolation_detected",
          fingerprint: ["isolation", "source"], threshold: 5, window_ms: 60_000}
      ]

  On a breach it emits a `signal.degradation_storm` audit event — which flows
  back through the audit spine (visible in the audit drawer, routed to OS push
  by `AlertsRouter` via the `Alerts` definition) — plus telemetry and a log.
  The storm action matches no watch rule, so the emission cannot re-trigger the
  watcher: no feedback loop.

  This is the bus's second distinct consumer (alert routing vs. health/pattern
  watching), which is what justifies the fan-out over a direct call.
  """

  use GenServer
  require Logger

  alias DevIDE.Audit
  alias DevIDE.Audit.Event
  alias DevIDE.SignalBus
  alias DevIDE.Signals.Publish
  alias Jido.Signal
  alias Jido.Signal.Bus

  @storm_action "signal.degradation_storm"

  @default_rules [
    %{
      action: "workspace.db_isolation_detected",
      fingerprint: ["isolation", "source"],
      threshold: 5,
      window_ms: 60_000
    },
    # Domain events published on the bus by #184 (devide.<event> namespace, not
    # devide.audit.*). A run of failures = a degradation storm worth surfacing.
    # Domain-event data is flat, so metadata-key fingerprints don't apply here;
    # fingerprint on action + workspace only (empty key list).
    %{
      action: "devide.deploy.failed",
      fingerprint: [],
      threshold: 3,
      window_ms: 300_000
    },
    %{
      action: "devide.runtime.preview_failed",
      fingerprint: [],
      threshold: 3,
      window_ms: 300_000
    },
    # Host tmux control-listener degraded (Slice 3). Primary thresholding lives
    # in TmuxEventsFlapWatch; this rule turns repeated degraded audits into a
    # signal.degradation_storm if an episode re-fires without recovery.
    %{
      action: "tmux.events_listener_degraded",
      fingerprint: ["label"],
      threshold: 2,
      window_ms: 300_000
    }
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The audit action emitted when a storm is detected."
  @spec storm_action() :: String.t()
  def storm_action, do: @storm_action

  @impl true
  def init(opts) do
    rules =
      opts
      |> Keyword.get(
        :rules,
        Application.get_env(:dev_ide, :degradation_watch_rules, @default_rules)
      )
      |> Map.new(fn rule -> {rule.action, rule} end)

    if signal_bus_enabled?() and Keyword.get(opts, :subscribe?, true) do
      for pattern <- subscription_patterns(rules) do
        {:ok, _sub_id} =
          Bus.subscribe(SignalBus.name(), pattern, dispatch: {:pid, target: self()})
      end
    end

    {:ok, %{rules: rules, windows: %{}, alerted: MapSet.new()}}
  end

  # Audit rules are covered by the audit wildcard (`devide.audit.**`). Domain
  # rules key on a full CloudEvents type (`devide.<event>`), which lives outside
  # the audit prefix — subscribe to each exactly so audit signals are never
  # double-delivered (which would halve their effective threshold).
  @doc false
  def subscription_patterns(rules) do
    domain =
      for {action, _rule} <- rules, String.starts_with?(action, "devide."), do: action

    [Publish.audit_subscription_pattern() | Enum.uniq(domain)]
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    {:noreply, observe(state, Event.from_signal(signal))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- core -----------------------------------------------------------------

  defp observe(%{rules: rules} = state, %Event{action: action} = event) do
    case Map.get(rules, action) do
      nil -> state
      rule -> tally(state, rule, event)
    end
  end

  defp tally(state, rule, event) do
    fp = fingerprint(rule, event)
    now = System.monotonic_time(:millisecond)
    cutoff = now - rule.window_ms

    times = [now | Enum.filter(Map.get(state.windows, fp, []), &(&1 > cutoff))]
    count = length(times)
    state = put_in(state.windows[fp], times)

    cond do
      count >= rule.threshold and not MapSet.member?(state.alerted, fp) ->
        fire_storm(rule, event, count)
        %{state | alerted: MapSet.put(state.alerted, fp)}

      count < rule.threshold and MapSet.member?(state.alerted, fp) ->
        # Episode subsided; re-arm so a fresh storm alerts again.
        %{state | alerted: MapSet.delete(state.alerted, fp)}

      true ->
        state
    end
  end

  # action + workspace + the classification values that a healthy detector
  # would vary. Identical degraded payloads collapse to one fingerprint.
  defp fingerprint(rule, %Event{action: action, workspace_id: ws, metadata: metadata}) do
    md = metadata || %{}
    {action, ws, Enum.map(rule.fingerprint, fn key -> md[key] || md[to_string(key)] end)}
  end

  defp fire_storm(rule, %Event{workspace_id: ws} = event, count) do
    {_action, _ws, values} = fingerprint(rule, event)

    Logger.warning(
      "degradation storm: #{rule.action} repeated #{count}x with identical payload " <>
        "#{inspect(values)} in #{rule.window_ms}ms (workspace #{ws})"
    )

    :telemetry.execute(
      [:dev_ide, :signals, :degradation_storm],
      %{count: count},
      %{action: rule.action, workspace_id: ws}
    )

    Audit.emit!(%{
      action: @storm_action,
      workspace_id: ws,
      actor_id: "system",
      target_type: "signal",
      target_ref: rule.action,
      metadata: %{
        "watched_action" => rule.action,
        "fingerprint" => Enum.map(values, &to_string/1),
        "count" => count,
        "window_ms" => rule.window_ms
      }
    })
  end

  defp signal_bus_enabled? do
    Application.get_env(:dev_ide, :signal_bus_enabled, true)
  end
end
