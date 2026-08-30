defmodule Casein.Terminals.HostHealth do
  @moduledoc """
  One read-only host-watchdog contract for the overflow menu and MCP.

  The milc-devbox watchdog writes `status.json` and `alerts.jsonl`. This
  module is the only normalization path: the menu row and `terminal_host_health`
  / `casein://host/health` must not classify independently.

  States: `healthy`, `warning`, `pressure`, `stuck`, `stale`, `unknown`.
  Missing, unreadable, or malformed snapshots are `unknown` — never healthy.
  A readable but expired sample is `stale`. Persistent D-state is `stuck`.
  """

  @resource_uri "casein://host/health"
  @mime "application/json"
  @default_status_path "/var/lib/casein/host-watchdog/status.json"
  @default_alerts_path "/var/lib/casein/host-watchdog/alerts.jsonl"
  @default_stale_after_seconds 720
  @default_max_alerts 5
  @default_host "milc-devbox"
  @message_limit 160

  @alert_keys [
    :timestamp,
    :severity,
    :signal,
    :message,
    :load1,
    :runnable,
    :cpu_idle_pct,
    :d_state_processes,
    :d_state_streak,
    :opencode_processes,
    :beam_processes
  ]

  @type state :: String.t()

  @type snapshot :: %{
          uri: String.t(),
          host: String.t(),
          state: state(),
          state_label: String.t(),
          sampled_at: String.t() | nil,
          observed_at: String.t(),
          age_seconds: non_neg_integer() | nil,
          fresh?: boolean(),
          reason: String.t() | nil,
          recorded_state: state() | nil,
          load1: float() | nil,
          runnable: integer() | nil,
          cpu_idle_pct: integer() | nil,
          mem_available_kb: integer() | nil,
          swap_used_kb: integer() | nil,
          opencode_processes: integer() | nil,
          beam_processes: integer() | nil,
          d_state_processes: integer() | nil,
          d_state_streak: integer() | nil,
          alert: String.t() | nil,
          latest_alert_at: String.t() | nil,
          alerts: [map()],
          alerts_available?: boolean(),
          alerts_unavailable_reason: String.t() | nil
        }

  @doc "Canonical MCP resource URI."
  @spec resource_uri() :: String.t()
  def resource_uri, do: @resource_uri

  @doc "Resource descriptor for `resources/list`."
  @spec resource_descriptor() :: map()
  def resource_descriptor do
    %{
      uri: @resource_uri,
      name: "Host health",
      description:
        "Read-only host watchdog snapshot: state, freshness, load, CPU idle, " <>
          "memory, swap, OpenCode/BEAM counts, and bounded recent alerts. " <>
          "Unknown/stale is never treated as healthy.",
      mimeType: @mime
    }
  end

  @doc "JSON-encode the snapshot for `resources/read`."
  @spec to_json(snapshot()) :: String.t()
  def to_json(payload) when is_map(payload) do
    payload
    |> jsonable()
    |> Jason.encode!()
  end

  @doc "Read and classify the current watchdog snapshot without mutating the host."
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    host = resolve_host(opts)
    stale_after = resolve_stale_after(opts)
    max_alerts = resolve_max_alerts(opts)

    {sample, sample_error} = read_sample(opts)
    {alerts, alerts_available?, alerts_reason} = read_alerts(opts, max_alerts)

    sample
    |> build_snapshot(sample_error, alerts, alerts_available?, host, now, stale_after)
    |> Map.put(:alerts_unavailable_reason, if(alerts_available?, do: nil, else: alerts_reason))
  end

  defp build_snapshot(nil, sample_error, alerts, alerts_available?, host, now, _stale_after) do
    reason =
      case sample_error do
        :malformed -> "status snapshot is malformed"
        _ -> "status snapshot is unavailable"
      end

    empty_snapshot(host, now, "unknown", reason, alerts, alerts_available?)
  end

  defp build_snapshot(sample, _error, alerts, alerts_available?, host, now, stale_after) do
    sampled_at = parse_timestamp(Map.get(sample, "timestamp") || Map.get(sample, :timestamp))

    cond do
      is_nil(sampled_at) ->
        empty_snapshot(
          host,
          now,
          "unknown",
          "status snapshot is malformed",
          alerts,
          alerts_available?
        )

      true ->
        age_seconds = max(DateTime.diff(now, sampled_at, :second), 0)
        recorded_state = classify_sample(sample)
        stale? = age_seconds > stale_after
        state = if stale?, do: "stale", else: recorded_state

        reason =
          cond do
            stale? -> "status snapshot is stale"
            state == "unknown" -> "status snapshot is malformed"
            true -> nil
          end

        fields = sample_fields(sample)
        latest_alert_at = latest_alert_at(alerts, fields.alert, sampled_at)

        %{
          uri: @resource_uri,
          host: host,
          state: state,
          state_label: state_label(state),
          sampled_at: DateTime.to_iso8601(sampled_at),
          observed_at: DateTime.to_iso8601(now),
          age_seconds: age_seconds,
          fresh?: not stale?,
          reason: reason,
          recorded_state: if(stale?, do: recorded_state),
          load1: fields.load1,
          runnable: fields.runnable,
          cpu_idle_pct: fields.cpu_idle_pct,
          mem_available_kb: fields.mem_available_kb,
          swap_used_kb: fields.swap_used_kb,
          opencode_processes: fields.opencode_processes,
          beam_processes: fields.beam_processes,
          d_state_processes: fields.d_state_processes,
          d_state_streak: fields.d_state_streak,
          alert: fields.alert,
          latest_alert_at: latest_alert_at,
          alerts: alerts,
          alerts_available?: alerts_available?
        }
    end
  end

  defp empty_snapshot(host, now, state, reason, alerts, alerts_available?) do
    %{
      uri: @resource_uri,
      host: host,
      state: state,
      state_label: state_label(state),
      sampled_at: nil,
      observed_at: DateTime.to_iso8601(now),
      age_seconds: nil,
      fresh?: false,
      reason: reason,
      recorded_state: nil,
      load1: nil,
      runnable: nil,
      cpu_idle_pct: nil,
      mem_available_kb: nil,
      swap_used_kb: nil,
      opencode_processes: nil,
      beam_processes: nil,
      d_state_processes: nil,
      d_state_streak: nil,
      alert: nil,
      latest_alert_at: nil,
      alerts: alerts,
      alerts_available?: alerts_available?
    }
  end

  defp classify_sample(sample) do
    alert = normalize_alert(Map.get(sample, "alert") || Map.get(sample, :alert))
    warning? = truthy?(Map.get(sample, "warning") || Map.get(sample, :warning))

    d_streak =
      parse_integer(Map.get(sample, "d_state_streak") || Map.get(sample, :d_state_streak))

    cond do
      alert in ["d_state", "pressure_and_d_state"] -> "stuck"
      is_integer(d_streak) and d_streak >= 2 -> "stuck"
      alert == "pressure" -> "pressure"
      warning? -> "warning"
      alert in [nil, "none"] -> "healthy"
      true -> "unknown"
    end
  end

  defp sample_fields(sample) do
    %{
      load1: parse_float(Map.get(sample, "load1") || Map.get(sample, :load1)),
      runnable: parse_integer(Map.get(sample, "runnable") || Map.get(sample, :runnable)),
      cpu_idle_pct:
        parse_integer(Map.get(sample, "cpu_idle_pct") || Map.get(sample, :cpu_idle_pct)),
      mem_available_kb:
        parse_integer(Map.get(sample, "mem_available_kb") || Map.get(sample, :mem_available_kb)),
      swap_used_kb:
        parse_integer(Map.get(sample, "swap_used_kb") || Map.get(sample, :swap_used_kb)),
      opencode_processes:
        parse_integer(
          Map.get(sample, "opencode_processes") || Map.get(sample, :opencode_processes)
        ),
      beam_processes:
        parse_integer(Map.get(sample, "beam_processes") || Map.get(sample, :beam_processes)),
      d_state_processes:
        parse_integer(Map.get(sample, "d_state_processes") || Map.get(sample, :d_state_processes)),
      d_state_streak:
        parse_integer(Map.get(sample, "d_state_streak") || Map.get(sample, :d_state_streak)),
      alert: normalize_alert(Map.get(sample, "alert") || Map.get(sample, :alert))
    }
  end

  defp latest_alert_at([], alert, sampled_at) when alert not in [nil, "none"] do
    DateTime.to_iso8601(sampled_at)
  end

  defp latest_alert_at([], _alert, _sampled_at), do: nil

  defp latest_alert_at(alerts, alert, sampled_at) do
    case List.last(alerts) do
      %{timestamp: ts} when is_binary(ts) -> ts
      _ -> latest_alert_at([], alert, sampled_at)
    end
  end

  # Path is operator config / env / hardcoded watchdog file, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_sample(opts) do
    cond do
      Keyword.has_key?(opts, :status) ->
        decode_status(Keyword.get(opts, :status))

      Keyword.has_key?(opts, :status_raw) ->
        decode_status_raw(Keyword.get(opts, :status_raw))

      true ->
        case File.read(resolve_status_path(opts)) do
          {:ok, contents} -> decode_status_raw(contents)
          {:error, _} -> {nil, :unavailable}
        end
    end
  end

  defp decode_status(status) when is_map(status), do: {stringify_keys(status), nil}
  defp decode_status(_), do: {nil, :malformed}

  defp decode_status_raw(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) -> {map, nil}
      _ -> {nil, :malformed}
    end
  end

  defp decode_status_raw(_), do: {nil, :malformed}

  # `{alerts, available?, unavailable_reason}`. The reason matters: on
  # 2026-08-30 `alerts_available?` was false for three days because the
  # watchdog wrote alerts.jsonl root-only, and nothing said so (#20165).
  # Path is operator config / env / hardcoded watchdog file, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_alerts(opts, max_alerts) do
    cond do
      Keyword.has_key?(opts, :alerts) ->
        {sanitize_alerts(Keyword.get(opts, :alerts), max_alerts), true, nil}

      Keyword.has_key?(opts, :alerts_raw) ->
        with_unavailable_reason(parse_alerts_raw(Keyword.get(opts, :alerts_raw), max_alerts))

      true ->
        case File.read(resolve_alerts_path(opts)) do
          {:ok, contents} ->
            with_unavailable_reason(parse_alerts_raw(contents, max_alerts))

          {:error, reason} ->
            {[], false, "alert log unreadable (#{reason})"}
        end
    end
  end

  defp with_unavailable_reason({alerts, true}), do: {alerts, true, nil}
  defp with_unavailable_reason({alerts, false}), do: {alerts, false, "alert log malformed"}

  defp parse_alerts_raw(contents, max_alerts) when is_binary(contents) do
    alerts =
      contents
      |> String.split("\n", trim: true)
      |> Enum.take(-max_alerts)
      |> Enum.flat_map(&decode_alert_line/1)

    {alerts, true}
  end

  defp parse_alerts_raw(_, _), do: {[], false}

  defp decode_alert_line(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) ->
        case sanitize_alert(map) do
          nil -> []
          alert -> [alert]
        end

      _ ->
        []
    end
  end

  defp sanitize_alerts(list, max_alerts) when is_list(list) do
    list
    |> Enum.flat_map(fn
      map when is_map(map) ->
        case sanitize_alert(stringify_keys(map)) do
          nil -> []
          alert -> [alert]
        end

      _ ->
        []
    end)
    |> Enum.take(-max_alerts)
  end

  defp sanitize_alerts(_, _), do: []

  defp sanitize_alert(map) when is_map(map) do
    alert = %{
      timestamp: string_or_nil(Map.get(map, "timestamp")),
      severity: string_or_nil(Map.get(map, "severity")),
      signal: normalize_alert(Map.get(map, "signal") || Map.get(map, "alert")),
      message: sanitize_message(Map.get(map, "message")),
      load1: parse_float(Map.get(map, "load1")),
      runnable: parse_integer(Map.get(map, "runnable")),
      cpu_idle_pct: parse_integer(Map.get(map, "cpu_idle_pct")),
      d_state_processes: parse_integer(Map.get(map, "d_state_processes")),
      d_state_streak: parse_integer(Map.get(map, "d_state_streak")),
      opencode_processes: parse_integer(Map.get(map, "opencode_processes")),
      beam_processes: parse_integer(Map.get(map, "beam_processes"))
    }

    if alert.timestamp || alert.signal || alert.message do
      alert
      |> Map.take(@alert_keys)
      |> reject_nil()
    end
  end

  defp sanitize_message(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
    |> String.trim()
    |> String.slice(0, @message_limit)
    |> case do
      "" -> nil
      message -> message
    end
  end

  defp sanitize_message(_), do: nil

  defp resolve_status_path(opts) do
    Keyword.get(opts, :status_path) ||
      config(:status_path) ||
      System.get_env("CASEIN_HOST_WATCHDOG_STATUS") ||
      @default_status_path
  end

  defp resolve_alerts_path(opts) do
    Keyword.get(opts, :alerts_path) ||
      config(:alerts_path) ||
      System.get_env("CASEIN_HOST_WATCHDOG_ALERTS") ||
      @default_alerts_path
  end

  defp resolve_host(opts) do
    Keyword.get(opts, :host) ||
      config(:host) ||
      System.get_env("CASEIN_HOST_HEALTH_ID") ||
      hostname() ||
      @default_host
  end

  defp resolve_stale_after(opts) do
    parse_positive_integer(Keyword.get(opts, :stale_after_seconds)) ||
      parse_positive_integer(config(:stale_after_seconds)) ||
      @default_stale_after_seconds
  end

  defp resolve_max_alerts(opts) do
    parse_positive_integer(Keyword.get(opts, :max_alerts)) ||
      parse_positive_integer(config(:max_alerts)) ||
      @default_max_alerts
  end

  defp config(key) do
    :casein
    |> Application.get_env(:host_health, [])
    |> Keyword.get(key)
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} ->
        name
        |> to_string()
        |> String.split(".")
        |> List.first()

      _ ->
        nil
    end
  end

  defp state_label("healthy"), do: "Healthy"
  defp state_label("warning"), do: "Warning"
  defp state_label("pressure"), do: "Pressure"
  defp state_label("stuck"), do: "Stuck"
  defp state_label("stale"), do: "Stale"
  defp state_label(_), do: "Unknown"

  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp normalize_alert(value)
       when value in ["none", "pressure", "d_state", "pressure_and_d_state"],
       do: value

  defp normalize_alert(value) when value in [:none, :pressure, :d_state, :pressure_and_d_state],
    do: Atom.to_string(value)

  defp normalize_alert(_), do: nil

  defp truthy?(1), do: true
  defp truthy?(true), do: true
  defp truthy?("1"), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

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

  defp parse_integer(value) when is_float(value) and value == trunc(value), do: trunc(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp reject_nil(map) do
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
