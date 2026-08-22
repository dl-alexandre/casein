defmodule Casein.HostHealth do
  @moduledoc """
  Shared server-side host-watchdog normalizer for the menu and MCP.

  Reads the configured watchdog snapshot (`status.json`) and bounded alert
  history (`alerts.jsonl`). Missing, unreadable, stale, or malformed data is
  **Unknown** — never Healthy. Menu and MCP must call `snapshot/1` so they
  cannot disagree.
  """

  alias McpCtl.{Params, Tool}

  @resource_uri "casein://host/health"
  @mime "application/json"
  @tool_name "host_health"

  @states [:healthy, :warning, :pressure, :stuck, :unknown]
  @alert_signals ~w(none pressure d_state pressure_and_d_state)
  @alert_severities ~w(info warning error)
  @alert_fields ~w(
    timestamp severity signal message load1 runnable cpu_idle_pct
    d_state_processes d_state_streak opencode_processes beam_processes
  )
  @secret_key_fragments ~w(prompt secret token password authorization source content)

  @default_status_path "/var/lib/casein/host-watchdog/status.json"
  @default_alerts_path "/var/lib/casein/host-watchdog/alerts.jsonl"
  @default_stale_after_seconds 900
  @default_alert_limit 8
  @max_alert_limit 20
  @max_alerts_bytes 262_144
  @max_message_bytes 200

  @type state :: :healthy | :warning | :pressure | :stuck | :unknown

  @type snapshot :: %{
          uri: String.t(),
          host: String.t(),
          state: String.t(),
          reason: String.t() | nil,
          sampled_at: String.t() | nil,
          sample_age_seconds: non_neg_integer() | nil,
          fresh?: boolean(),
          stale_after_seconds: pos_integer(),
          metrics: map() | nil,
          alert: map(),
          alerts: [map()],
          generated_at: String.t()
        }

  @doc "Canonical MCP resource URI."
  @spec resource_uri() :: String.t()
  def resource_uri, do: @resource_uri

  @doc "MCP tool name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Resource descriptor for `resources/list`."
  @spec resource_descriptor() :: map()
  def resource_descriptor do
    %{
      uri: @resource_uri,
      name: "Host health",
      description:
        "Read-only host watchdog health: state (healthy/warning/pressure/stuck/unknown), " <>
          "freshness, host identity, bounded metrics, and recent sanitized alerts. " <>
          "Missing or stale snapshots are unknown, never healthy. No mutations.",
      mimeType: @mime
    }
  end

  @doc "MCP tool definition for `tools/list`."
  @spec tool_definition() :: Tool.t()
  def tool_definition do
    Tool.define(
      @tool_name,
      "Read-only host watchdog health. Returns the same normalized snapshot the " <>
        "workspace menu displays: state, freshness, host, bounded metrics, and " <>
        "recent sanitized alerts. Missing or stale snapshots are unknown, never " <>
        "healthy. No kill/cancel/scale. Optional workspace_id is audit scope only.",
      Tool.object(Params.terminal_workspace_props(), []),
      %{
        mutation?: false,
        danger_level: :low,
        capabilities: [:terminal_metadata, :terminal_read],
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
        idempotent_hint: true,
        recovery_hints: [
          "state=unknown with reason=stale means the watchdog sample is older than stale_after_seconds.",
          "state=unknown with reason=unavailable means the configured snapshot is missing or unreadable.",
          "state=unknown with reason=malformed means the snapshot JSON is not a valid watchdog sample.",
          "Menu and this tool share Casein.HostHealth.snapshot/1 — they cannot disagree."
        ]
      }
    )
  end

  @doc "JSON-encode a snapshot for `resources/read`."
  @spec to_json(snapshot()) :: String.t()
  def to_json(payload) when is_map(payload) do
    payload
    |> jsonable()
    |> Jason.encode!()
  end

  @doc """
  Normalize the configured watchdog snapshot.

  Options override Application config (`:casein, :host_health`):

    * `:status_path` / `:alerts_path`
    * `:stale_after_seconds`
    * `:alert_limit`
    * `:host`
    * `:now` — `DateTime` used for age and generated_at
    * `:pressure` / `:warning` threshold keyword lists
    * `:stuck_d_state_streak`
  """
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) do
    cfg = config(opts)
    now = Keyword.get(opts, :now) || DateTime.utc_now() |> DateTime.truncate(:second)

    {status, status_error} = read_status(cfg.status_path)
    alerts = read_alerts(cfg.alerts_path, cfg.alert_limit)

    build(status, status_error, alerts, now, cfg)
  end

  @doc "Human label for a normalized state atom or string."
  @spec state_label(state() | String.t()) :: String.t()
  def state_label(state) when state in @states,
    do: state |> Atom.to_string() |> String.capitalize()

  def state_label("healthy"), do: "Healthy"
  def state_label("warning"), do: "Warning"
  def state_label("pressure"), do: "Pressure"
  def state_label("stuck"), do: "Stuck"
  def state_label(_), do: "Unknown"

  @doc "Compact age label such as `12s` or `3m`."
  @spec age_label(nil | integer()) :: String.t()
  def age_label(nil), do: "unknown age"
  def age_label(seconds) when is_integer(seconds) and seconds < 0, do: "0s"
  def age_label(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"
  def age_label(seconds) when is_integer(seconds) and seconds < 3600, do: "#{div(seconds, 60)}m"
  def age_label(seconds) when is_integer(seconds), do: "#{div(seconds, 3600)}h"
  def age_label(_), do: "unknown age"

  @doc "Human available-memory label from kilobytes."
  @spec mem_label(nil | number()) :: String.t()
  def mem_label(kb) when is_number(kb) and kb >= 0 do
    gb = kb / 1_048_576
    :erlang.float_to_binary(gb / 1, decimals: 1) <> " GiB"
  end

  def mem_label(_), do: "—"

  ## Config

  defp config(opts) do
    app = Application.get_env(:casein, :host_health, [])

    %{
      status_path: opt_path(opts, app, :status_path, @default_status_path),
      alerts_path: opt_path(opts, app, :alerts_path, @default_alerts_path),
      stale_after_seconds:
        opt_pos_int(opts, app, :stale_after_seconds, @default_stale_after_seconds),
      alert_limit:
        min(opt_pos_int(opts, app, :alert_limit, @default_alert_limit), @max_alert_limit),
      host: opt_host(opts, app),
      pressure:
        default_pressure()
        |> Keyword.merge(Keyword.get(app, :pressure, []))
        |> Keyword.merge(Keyword.get(opts, :pressure, [])),
      warning:
        default_warning()
        |> Keyword.merge(Keyword.get(app, :warning, []))
        |> Keyword.merge(Keyword.get(opts, :warning, [])),
      stuck_d_state_streak:
        Keyword.get(opts, :stuck_d_state_streak, Keyword.get(app, :stuck_d_state_streak, 2))
    }
  end

  defp default_pressure, do: [load1: 32, runnable: 32, cpu_idle_pct: 20]
  defp default_warning, do: [load1: 24, runnable: 24, cpu_idle_pct: 30]

  defp opt_path(opts, app, key, default) do
    case Keyword.get(opts, key) || Keyword.get(app, key) || default do
      path when is_binary(path) and path != "" -> path
      _ -> default
    end
  end

  defp opt_pos_int(opts, app, key, default) do
    case Keyword.get(opts, key, Keyword.get(app, key, default)) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp opt_host(opts, app) do
    case Keyword.get(opts, :host) || Keyword.get(app, :host) do
      host when is_binary(host) and host != "" -> host
      _ -> local_host()
    end
  end

  defp local_host do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "unknown"
    end
  end

  ## IO

  defp read_status(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> decode_status(body)
      {:error, :enoent} -> {nil, :unavailable}
      {:error, _} -> {nil, :unavailable}
    end
  end

  defp decode_status(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        case extract_status(map) do
          {:ok, status} -> {status, nil}
          :error -> {nil, :malformed}
        end

      _ ->
        {nil, :malformed}
    end
  end

  defp extract_status(map) do
    timestamp = string_field(map, "timestamp") || string_field(map, :timestamp)

    cond do
      not is_binary(timestamp) ->
        :error

      parse_time(timestamp) == nil ->
        :error

      true ->
        {:ok,
         %{
           timestamp: timestamp,
           load1: number_field(map, "load1"),
           runnable: int_field(map, "runnable"),
           cpu_idle_pct: int_field(map, "cpu_idle_pct"),
           mem_available_kb: int_field(map, "mem_available_kb"),
           swap_used_kb: int_field(map, "swap_used_kb"),
           d_state_processes: int_field(map, "d_state_processes") || 0,
           d_state_streak: int_field(map, "d_state_streak") || 0,
           opencode_processes: int_field(map, "opencode_processes"),
           beam_processes: int_field(map, "beam_processes"),
           warning?: truthy_field(map, "warning"),
           alert: alert_signal_field(map)
         }}
    end
  end

  defp read_alerts(path, limit) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_alerts_bytes ->
        tail_alerts(path, limit)

      {:ok, _} ->
        case File.read(path) do
          {:ok, body} -> parse_alert_lines(body, limit)
          {:error, _} -> []
        end

      {:error, _} ->
        []
    end
  end

  defp tail_alerts(path, limit) do
    case File.open(path, [:read]) do
      {:ok, io} ->
        try do
          _ = :file.position(io, {:eof, -@max_alerts_bytes})
          io |> IO.read(:eof) |> parse_alert_lines(limit)
        after
          File.close(io)
        end

      {:error, _} ->
        []
    end
  end

  defp parse_alert_lines(body, limit) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.reduce_while([], fn line, acc ->
      if length(acc) >= limit do
        {:halt, acc}
      else
        case sanitize_alert(line) do
          {:ok, alert} -> {:cont, [alert | acc]}
          :error -> {:cont, acc}
        end
      end
    end)
  end

  defp parse_alert_lines(_, _), do: []

  defp sanitize_alert(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) ->
        if secret_keys?(map) do
          :error
        else
          alert =
            map
            |> Map.take(@alert_fields)
            |> then(&Map.merge(stringify_atom_keys(map), &1))
            |> Map.take(@alert_fields)
            |> normalize_alert()

          if is_map(alert), do: {:ok, alert}, else: :error
        end

      _ ->
        :error
    end
  end

  defp sanitize_alert(_), do: :error

  defp stringify_atom_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp secret_keys?(map) do
    Enum.any?(Map.keys(map), fn key ->
      name = key |> to_string() |> String.downcase()
      Enum.any?(@secret_key_fragments, &String.contains?(name, &1))
    end)
  end

  defp normalize_alert(map) do
    timestamp = string_field(map, "timestamp")
    signal = alert_signal_field(map)
    severity = severity_field(map)
    message = bound_message(string_field(map, "message"))

    if is_binary(timestamp) and parse_time(timestamp) != nil do
      %{
        timestamp: timestamp,
        severity: severity,
        signal: signal,
        message: message,
        load1: number_field(map, "load1"),
        runnable: int_field(map, "runnable"),
        cpu_idle_pct: int_field(map, "cpu_idle_pct"),
        d_state_processes: int_field(map, "d_state_processes"),
        d_state_streak: int_field(map, "d_state_streak"),
        opencode_processes: int_field(map, "opencode_processes"),
        beam_processes: int_field(map, "beam_processes")
      }
      |> reject_nil()
    else
      nil
    end
  end

  defp bound_message(message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" ->
        nil

      byte_size(message) > @max_message_bytes ->
        binary_part(message, 0, @max_message_bytes)

      true ->
        message
    end
  end

  defp bound_message(_message), do: nil

  ## Classification

  defp build(nil, error, alerts, now, cfg) do
    reason = if error == :malformed, do: "malformed", else: "unavailable"

    base_snapshot(now, cfg, :unknown, reason, nil, false, nil, alerts)
  end

  defp build(status, _error, alerts, now, cfg) do
    sampled_at = parse_time(status.timestamp)
    age = age_seconds(sampled_at, now)
    stale? = is_nil(age) or age > cfg.stale_after_seconds

    {state, reason} =
      cond do
        stale? -> {:unknown, "stale"}
        true -> {classify(status, cfg), nil}
      end

    metrics = %{
      load1: status.load1,
      runnable: status.runnable,
      cpu_idle_pct: status.cpu_idle_pct,
      mem_available_kb: status.mem_available_kb,
      swap_used_kb: status.swap_used_kb,
      opencode_processes: status.opencode_processes,
      beam_processes: status.beam_processes,
      d_state_processes: status.d_state_processes,
      d_state_streak: status.d_state_streak
    }

    alert = %{
      signal: status.alert,
      warning?: status.warning?,
      at: latest_alert_at(status, alerts)
    }

    base_snapshot(now, cfg, state, reason, sampled_at, not stale?, metrics, alerts)
    |> Map.put(:alert, alert)
    |> Map.put(:sample_age_seconds, age)
  end

  defp base_snapshot(now, cfg, state, reason, sampled_at, fresh?, metrics, alerts) do
    %{
      uri: @resource_uri,
      host: cfg.host,
      state: Atom.to_string(state),
      reason: reason,
      sampled_at: encode_time(sampled_at),
      sample_age_seconds: nil,
      fresh?: fresh?,
      stale_after_seconds: cfg.stale_after_seconds,
      metrics: metrics,
      alert: %{signal: "none", warning?: false, at: nil},
      alerts: alerts,
      generated_at: DateTime.to_iso8601(now)
    }
  end

  defp classify(status, cfg) do
    cond do
      stuck?(status, cfg) -> :stuck
      pressure?(status, cfg) -> :pressure
      warning?(status, cfg) -> :warning
      true -> :healthy
    end
  end

  defp stuck?(status, cfg) do
    streak = status.d_state_streak || 0
    threshold = cfg.stuck_d_state_streak

    streak >= threshold or status.alert in ["d_state", "pressure_and_d_state"]
  end

  defp pressure?(status, cfg) do
    status.alert == "pressure" or
      threshold_hit?(status, cfg.pressure)
  end

  defp warning?(status, cfg) do
    status.warning? or threshold_hit?(status, cfg.warning)
  end

  defp threshold_hit?(status, thresholds) do
    load1 = Keyword.get(thresholds, :load1)
    runnable = Keyword.get(thresholds, :runnable)
    idle = Keyword.get(thresholds, :cpu_idle_pct)

    (is_number(status.load1) and is_number(load1) and status.load1 >= load1) or
      (is_integer(status.runnable) and is_integer(runnable) and status.runnable > runnable) or
      (is_integer(status.cpu_idle_pct) and is_integer(idle) and status.cpu_idle_pct < idle)
  end

  defp latest_alert_at(status, alerts) do
    case List.last(alerts) do
      %{timestamp: ts} -> ts
      _ -> status.timestamp
    end
  end

  ## Fields

  defp string_field(map, key) do
    case map_get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp number_field(map, key) do
    case map_get(map, key) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      value when is_binary(value) -> parse_float(value)
      _ -> nil
    end
  end

  defp int_field(map, key) do
    case map_get(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end

  defp truthy_field(map, key) do
    case map_get(map, key) do
      value when value in [1, true, "1", "true"] -> true
      _ -> false
    end
  end

  defp alert_signal_field(map) do
    case string_field(map, "alert") || string_field(map, "signal") do
      signal when signal in @alert_signals -> signal
      _ -> "none"
    end
  end

  defp severity_field(map) do
    case string_field(map, "severity") do
      severity when severity in @alert_severities -> severity
      _ -> "info"
    end
  end

  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(map, key) when is_binary(key) do
    Map.get(map, key) ||
      try do
        Map.get(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp age_seconds(nil, _now), do: nil

  defp age_seconds(%DateTime{} = sampled_at, %DateTime{} = now) do
    max(DateTime.diff(now, sampled_at, :second), 0)
  end

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp jsonable(value) when is_struct(value), do: jsonable(Map.from_struct(value))

  defp jsonable(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {jsonable_key(k), jsonable(v)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(other), do: other

  defp jsonable_key(k) when is_atom(k), do: Atom.to_string(k)
  defp jsonable_key(k) when is_binary(k), do: k
  defp jsonable_key(k), do: to_string(k)
end
