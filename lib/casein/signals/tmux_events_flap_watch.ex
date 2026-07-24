defmodule Casein.Signals.TmuxEventsFlapWatch do
  @moduledoc """
  DegradationWatch-family consumer for the host-tmux control listener.

  Attaches to `[:tmux_ctl, :events, :listener]` telemetry (emitted by
  `TmuxCtl.Events.ControlListener`) and raises one loud platform signal when
  the listener **flaps** more than **N** times (default **3**) within **M**
  minutes (default **5**), or stays **down** (including never connecting after
  boot — the likeliest canary failure, e.g. a missing anchor session) for
  longer than `down_ms` (default **60s**). Clears the episode after a
  **sustained** connection (default **60s** continuous `:up`).

  Surfaces exactly like sibling degradation consumers:

  * audit row `tmux.events_listener_degraded` / `tmux.events_listener_recovered`
    (box-global workspace `"_ops"`, same sentinel pattern as `PgProbe`)
  * telemetry `[:casein, :signals, :tmux_events_flap]` with `%{kind: :raised|:cleared}`
  * `{:ops_health, :tmux_events_listener, :raised|:cleared, risk}` on `"ops:health"`

  Thresholds are config opts (also accepted on `start_link/1` for tests):

      config :casein, :tmux_events_flap_watch,
        threshold: 3,
        window_ms: 300_000,
        sustained_ms: 60_000,
        down_ms: 60_000

  Inert when `:tmux_events` is off — no false alarms on the pure-poll path.

  ## Rollout / soak checklist (Slice 3)

  **Ladder:** dev default ON (this PR) → canary soak via this telemetry → prod
  default later (operational; not code here). `runtime.exs` env
  `DEVIDE_TMUX_EVENTS` still overrides both ways.

  **Watch during canary soak (≈48h):**

  | Signal | Healthy | Investigate |
  |--------|---------|-------------|
  | `tmux_ctl.events.listener.count` tags `event=up/down/reconnect_attempt` | rare down/reconnect | continuous reconnect_attempt / down storms |
  | `ControlListener.status/0` `reconnects_in_window` | 0–1 | ≥3 in 5 min (this alarm threshold) |
  | `tmux_ctl.topology.watcher.refresh.count` `source=event` | dominates while idle topology is quiet | stuck `poll_fallback` with flag on |
  | `source=reconcile` | ~1/10s per watched session | much higher (event path dead) |
  | `source=poll_fallback` | only when listener down / flag off | high while flag on = permanent fallback |
  | `events_absorbed` on event refreshes | >1 during storms = coalescing works | always 0 with event floods = no coalesce |
  | Drift / `session_terminated` anomalies | unchanged vs pre-flip baseline | spike after enable |

  **What this flap alarm means:** the control client is cycling
  connect/disconnect faster than a healthy host tmux should. Typical causes:
  keepalive/anchor session missing, tmux server crash-loop, canary socket
  fights, or attach target wrong. Topology still falls back to 300ms polling
  (correctness), but you lose the event-driven latency win until the listener
  stays up.

  **Flip / rollback commands:**

      # Enable on a host (canary / prod soak) — no restart required if already
      # compiled with the flag; restart the release so the listener child starts.
      # /etc/casein/devide.env:
      DEVIDE_TMUX_EVENTS=1

      # Kill switch (immediate poll path on next watcher tick / resubscribe):
      DEVIDE_TMUX_EVENTS=0

      # Dev (compile-time default after this PR):
      # config/dev.exs → config :casein, :tmux_events, true
      # Override: DEVIDE_TMUX_EVENTS=0 in the shell before mix phx.server

  **Do not flip prod default** until soak shows zero flap alarms, no
  session_terminated regression, and watcher refresh mix dominated by
  `event`+`reconcile` rather than `poll_fallback`.
  """

  use GenServer
  require Logger

  alias Casein.Audit

  @pubsub Casein.PubSub
  @ops_topic "ops:health"
  @workspace_id "_ops"
  @telemetry_event [:tmux_ctl, :events, :listener]
  @handler_id_prefix "dev_ide.tmux_events_flap_watch"

  @degraded_action "tmux.events_listener_degraded"
  @recovered_action "tmux.events_listener_recovered"

  @default_threshold 3
  @default_window_ms 300_000
  @default_sustained_ms 60_000
  @default_down_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Audit action emitted when the flap threshold is breached."
  @spec degraded_action() :: String.t()
  def degraded_action, do: @degraded_action

  @doc "Audit action emitted when a raised episode clears after sustained uptime."
  @spec recovered_action() :: String.t()
  def recovered_action, do: @recovered_action

  @doc """
  Test / injection seam: feed a listener lifecycle event without going through
  `:telemetry` (mirrors `DegradationWatch` tests that `send` synthetic signals).
  """
  @spec notify(GenServer.server(), :up | :down | :reconnect_attempt, map()) :: :ok
  def notify(server \\ __MODULE__, event, meta \\ %{})
      when event in [:up, :down, :reconnect_attempt] and is_map(meta) do
    GenServer.cast(server, {:listener_event, event, meta, now_ms()})
  end

  @doc false
  @spec reduce(map(), :up | :down | :reconnect_attempt, non_neg_integer()) ::
          {map(), :raise | :clear | :noop}
  def reduce(state, event, now_ms) when is_map(state) and is_integer(now_ms) do
    case event do
      :down -> reduce_down(state, now_ms)
      :up -> reduce_up(state, now_ms)
      :reconnect_attempt -> {state, :noop}
    end
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:casein, :tmux_events_flap_watch, [])

    state = %{
      threshold: Keyword.get(opts, :threshold, cfg[:threshold] || @default_threshold),
      window_ms: Keyword.get(opts, :window_ms, cfg[:window_ms] || @default_window_ms),
      sustained_ms: Keyword.get(opts, :sustained_ms, cfg[:sustained_ms] || @default_sustained_ms),
      down_ms: Keyword.get(opts, :down_ms, cfg[:down_ms] || @default_down_ms),
      attach?: Keyword.get(opts, :attach?, true),
      flap_times: [],
      raised?: false,
      connected_since: nil,
      sustained_timer: nil,
      down_since: nil,
      down_timer: nil,
      label: nil,
      handler_id: nil
    }

    state =
      if state.attach? do
        handler_id = {@handler_id_prefix, self()}

        :ok =
          :telemetry.attach(
            handler_id,
            @telemetry_event,
            &__MODULE__.__telemetry_handler__/4,
            self()
          )

        %{state | handler_id: handler_id}
      else
        state
      end

    {:ok, state}
  end

  @doc false
  def __telemetry_handler__(_event, _measurements, metadata, pid) do
    case metadata do
      %{event: event} when event in [:up, :down, :reconnect_attempt] ->
        GenServer.cast(pid, {:listener_event, event, metadata, now_ms()})

      _ ->
        :ok
    end
  end

  @impl true
  def handle_cast({:listener_event, event, meta, now_ms}, state) do
    # Flag-off path is pure polling — never raise listener flaps.
    if tmux_events_enabled?() do
      label = Map.get(meta, :label) || state.label
      state = %{state | label: label}
      {state, action} = reduce(state, event, now_ms)
      state = apply_action(state, action, now_ms)

      state =
        state
        |> maybe_arm_sustained(event, now_ms)
        |> track_down(event, now_ms)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:sustained_check, connected_since}, state) do
    state = %{state | sustained_timer: nil}

    cond do
      not state.raised? ->
        {:noreply, state}

      state.connected_since != connected_since ->
        {:noreply, state}

      true ->
        now = now_ms()
        uptime = now - connected_since

        if uptime >= state.sustained_ms do
          {:noreply, apply_action(state, :clear, now)}
        else
          {:noreply, arm_sustained_timer(state, connected_since, state.sustained_ms - uptime)}
        end
    end
  end

  def handle_info({:down_check, down_since}, state) do
    state = %{state | down_timer: nil}

    cond do
      state.raised? or state.down_since != down_since or not tmux_events_enabled?() ->
        {:noreply, state}

      true ->
        downtime = now_ms() - down_since
        {:noreply, apply_action(state, {:raise_down, downtime}, now_ms())}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.handler_id, do: :telemetry.detach(state.handler_id)
    cancel_sustained_timer(state)
    cancel_down_timer(state)
    :ok
  end

  # --- pure reduce ----------------------------------------------------------

  defp reduce_down(state, now_ms) do
    state = cancel_sustained_timer(%{state | connected_since: nil})
    times = [now_ms | Enum.filter(state.flap_times, &(&1 > now_ms - state.window_ms))]
    state = %{state | flap_times: times}
    count = length(times)

    if count >= state.threshold and not state.raised? do
      {state, :raise}
    else
      {state, :noop}
    end
  end

  defp reduce_up(state, now_ms) do
    {%{state | connected_since: now_ms}, :noop}
  end

  defp maybe_arm_sustained(state, :up, _now_ms) when state.raised? do
    arm_sustained_timer(state, state.connected_since, state.sustained_ms)
  end

  defp maybe_arm_sustained(state, _event, _now_ms), do: state

  # Down-duration tracking: a listener that goes down and stays down — or
  # never connects after boot (only :reconnect_attempt events, no :up) — must
  # raise after down_ms even though it never "flaps".
  defp track_down(state, :up, _now_ms) do
    %{cancel_down_timer(state) | down_since: nil}
  end

  defp track_down(%{down_since: nil} = state, event, now_ms)
       when event in [:down, :reconnect_attempt] do
    state = %{state | down_since: now_ms}
    ref = Process.send_after(self(), {:down_check, now_ms}, state.down_ms)
    %{state | down_timer: ref}
  end

  defp track_down(state, _event, _now_ms), do: state

  defp cancel_down_timer(%{down_timer: nil} = state), do: state

  defp cancel_down_timer(%{down_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | down_timer: nil}
  end

  defp arm_sustained_timer(state, connected_since, delay_ms)
       when is_integer(connected_since) and is_integer(delay_ms) do
    state = cancel_sustained_timer(state)
    ref = Process.send_after(self(), {:sustained_check, connected_since}, max(delay_ms, 0))
    %{state | sustained_timer: ref}
  end

  defp arm_sustained_timer(state, _connected_since, _delay_ms), do: state

  defp cancel_sustained_timer(%{sustained_timer: nil} = state), do: state

  defp cancel_sustained_timer(%{sustained_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | sustained_timer: nil}
  end

  defp apply_action(state, :noop, _now), do: state

  defp apply_action(state, :raise, _now) do
    count = length(state.flap_times)

    Logger.warning(
      "tmux events listener flap: #{count} disconnects within #{state.window_ms}ms " <>
        "(label=#{inspect(state.label)}); raising degradation signal"
    )

    announce(:raised, state, count)
    %{state | raised?: true}
  end

  defp apply_action(state, {:raise_down, downtime_ms}, _now) do
    Logger.warning(
      "tmux events listener down for #{downtime_ms}ms (label=#{inspect(state.label)}); " <>
        "raising degradation signal"
    )

    announce(:raised, state, length(state.flap_times), %{
      reason: :listener_down,
      down_ms: downtime_ms
    })

    %{state | raised?: true}
  end

  defp apply_action(state, :clear, _now) do
    Logger.info(
      "tmux events listener recovered after sustained connection " <>
        "(label=#{inspect(state.label)}); clearing degradation signal"
    )

    announce(:cleared, state, length(state.flap_times))
    %{state | raised?: false, flap_times: []}
  end

  defp announce(kind, state, count, extra \\ %{}) do
    action = if kind == :raised, do: @degraded_action, else: @recovered_action
    reason = Map.get(extra, :reason, :flapping)

    :telemetry.execute(
      [:casein, :signals, :tmux_events_flap],
      %{count: count},
      %{
        kind: kind,
        reason: reason,
        label: state.label,
        threshold: state.threshold,
        window_ms: state.window_ms
      }
    )

    risk = %{
      id: :tmux_events_listener,
      severity: if(kind == :raised, do: :warn, else: :info),
      subject: state.label || "host",
      detected_at: DateTime.utc_now(),
      evidence:
        Map.merge(
          %{
            reason: reason,
            flaps: count,
            threshold: state.threshold,
            window_ms: state.window_ms,
            sustained_ms: state.sustained_ms,
            label: state.label
          },
          extra
        ),
      suggestion:
        cond do
          kind != :raised ->
            "Listener has stayed connected past the sustained threshold."

          reason == :listener_down ->
            "Host tmux control listener is down / never connected. Check the anchor " <>
              "session (`__casein_keepalive`), tmux server health " <>
              "(`tmux -L <label> list-sessions`), and DEVIDE_TMUX_EVENTS. Topology " <>
              "falls back to polling automatically."

          true ->
            "Host tmux control listener is flapping. Check the anchor session " <>
              "(`__casein_keepalive`), tmux server health (`tmux -L <label> list-sessions`), " <>
              "and DEVIDE_TMUX_EVENTS. Topology falls back to polling automatically."
        end
    }

    _ =
      Audit.emit!(%{
        workspace_id: @workspace_id,
        actor_id: "tmux_events_flap_watch",
        action: action,
        source: "ops",
        target_type: "tmux_events_listener",
        target_ref: to_string(state.label || "host"),
        metadata: %{
          "kind" => Atom.to_string(kind),
          "reason" => Atom.to_string(reason),
          "flaps" => count,
          "threshold" => state.threshold,
          "window_ms" => state.window_ms,
          "label" => state.label
        }
      })

    Phoenix.PubSub.broadcast(
      @pubsub,
      @ops_topic,
      {:ops_health, :tmux_events_listener, kind, risk}
    )

    :ok
  end

  defp tmux_events_enabled? do
    case Application.get_env(:casein, :tmux_events, false) do
      true -> true
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
