defmodule Casein.Agents.JidoLifecycle.Envelope do
  @moduledoc """
  Stable, redacted event envelope for headless Jido (and OpenCode) projection.

  Identity fields are workspace, task, attempt, worker, action, correlation,
  sequence, and timestamp. Payloads are scrubbed and capped before persist.
  """

  alias Casein.Export.Sanitizer

  @max_payload_bytes 8 * 1024
  @max_summary 200
  @max_string 500

  @dropped ~w(
    password token api_key secret authorization bearer cookie session_id
    command keys text prompt question content input output code patch diff
    thoughts raw body DATABASE_URL database_url
  )

  @type t :: %{
          workspace_id: String.t(),
          task_id: String.t() | nil,
          attempt_id: String.t() | nil,
          worker_id: String.t() | nil,
          action: String.t() | nil,
          correlation_id: String.t() | nil,
          sequence: non_neg_integer(),
          timestamp: DateTime.t(),
          event_type: String.t(),
          runtime: :jido | :opencode,
          headless: boolean(),
          payload: map()
        }

  @spec build(map()) :: t()
  def build(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    workspace_id = required_string(attrs, :workspace_id)
    attempt_id = optional_string(attrs, :attempt_id)
    worker_id = optional_string(attrs, :worker_id) || attempt_id
    correlation_id = optional_string(attrs, :correlation_id) || attempt_id

    %{
      workspace_id: workspace_id,
      task_id: optional_string(attrs, :task_id),
      attempt_id: attempt_id,
      worker_id: worker_id,
      action: optional_string(attrs, :action),
      correlation_id: correlation_id,
      sequence: sequence(attrs),
      timestamp: timestamp(attrs, now),
      event_type: event_type(attrs),
      runtime: runtime(attrs),
      headless: headless?(attrs),
      payload: redact(Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{})
    }
  end

  @spec redact(term()) :: map()
  def redact(payload) when is_map(payload) do
    payload
    |> stringify_keys()
    |> drop_sensitive()
    |> Sanitizer.scrub()
    |> bound_values()
    |> cap_bytes()
  end

  def redact(_payload), do: %{}

  @spec resume_token(t() | map()) :: String.t() | nil
  def resume_token(%{workspace_id: workspace_id, attempt_id: attempt_id})
      when is_binary(workspace_id) and is_binary(attempt_id) do
    "jido:#{workspace_id}:#{attempt_id}"
  end

  def resume_token(_), do: nil

  @spec source_event_id(t(), String.t()) :: String.t()
  def source_event_id(envelope, suffix) when is_binary(suffix) do
    worker = envelope.worker_id || envelope.attempt_id || "unknown"
    "#{envelope.event_type}:#{worker}:#{suffix}"
  end

  defp required_string(attrs, key) do
    case optional_string(attrs, key) do
      nil -> raise ArgumentError, "Jido lifecycle envelope requires #{key}"
      value -> value
    end
  end

  defp optional_string(attrs, key) do
    case fetch(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      _ ->
        nil
    end
  end

  defp fetch(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp sequence(attrs) do
    case fetch(attrs, :sequence) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp timestamp(attrs, default) do
    case fetch(attrs, :timestamp) || fetch(attrs, :occurred_at) do
      %DateTime{} = datetime ->
        datetime

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _} -> datetime
          _ -> default
        end

      _ ->
        default
    end
  end

  defp event_type(attrs) do
    optional_string(attrs, :event_type) || "jido.lifecycle"
  end

  defp runtime(attrs) do
    case fetch(attrs, :runtime) do
      :opencode -> :opencode
      "opencode" -> :opencode
      _ -> :jido
    end
  end

  defp headless?(attrs) do
    case fetch(attrs, :headless) do
      false -> false
      "false" -> false
      _ -> runtime(attrs) == :jido
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp drop_sensitive(map) do
    Map.reject(map, fn {key, _value} -> String.downcase(key) in @dropped end)
  end

  defp bound_values(map) do
    Map.new(map, fn {key, value} -> {key, bound_value(value)} end)
  end

  defp bound_value(value) when is_binary(value) do
    value |> Sanitizer.redact_text() |> String.slice(0, @max_string)
  end

  defp bound_value(list) when is_list(list) do
    list
    |> Enum.take(32)
    |> Enum.map(&bound_value/1)
  end

  defp bound_value(map) when is_map(map) and not is_struct(map) do
    map
    |> stringify_keys()
    |> drop_sensitive()
    |> Map.new(fn {key, value} -> {key, bound_value(value)} end)
  end

  defp bound_value(value)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp bound_value(_value), do: nil

  defp cap_bytes(payload) do
    encoded = Jason.encode!(payload)

    if byte_size(encoded) > @max_payload_bytes do
      %{
        "truncated" => true,
        "schema_version" => 1,
        "keys" => Map.keys(payload) |> Enum.take(16)
      }
    else
      payload
    end
  rescue
    _ -> %{"truncated" => true}
  end

  @spec bound_summary(term()) :: String.t()
  def bound_summary(value) when is_binary(value) do
    value |> Sanitizer.redact_text() |> String.trim() |> String.slice(0, @max_summary)
  end

  def bound_summary(_value), do: ""
end
