defmodule McpCtl.Error do
  @moduledoc """
  Normalizes agent tool errors into MCP-friendly structured payloads.
  """

  @spec format(term()) :: map()
  # Matched structurally so this app keeps no dependency on Ecto. A failed
  # changeset is the most common struct reason a tool can return, and the
  # generic struct path below would bury the one thing the caller needs — which
  # field was rejected and why — under the schema struct it carries in `:data`.
  def format(%{__struct__: Ecto.Changeset, errors: errors}) when is_list(errors) do
    details = changeset_details(errors)

    %{
      "error" => "validation_failed",
      "details" => details,
      "message" => changeset_message(details)
    }
  end

  def format(reason) when is_struct(reason) do
    reason
    |> Map.from_struct()
    |> format()
  end

  def format(reason) when is_map(reason) do
    reason
    |> Enum.map(fn {key, value} -> {normalize_key(key), sanitize_value(value)} end)
    |> Map.new()
    |> ensure_message()
  end

  def format({:missing_argument, key}) do
    key = to_string(key)

    %{
      "error" => "missing_argument",
      "argument" => key,
      "message" => "Missing required argument: #{key}"
    }
  end

  def format({:redirect_blocked, status, location}) when is_integer(status) do
    %{
      "error" => "redirect_blocked",
      "status" => status,
      "location" => sanitize_value(location),
      "message" => "Redirect blocked (#{status}) to #{location}"
    }
  end

  def format({:http_status, status, body}) when is_integer(status) do
    %{
      "error" => "http_status",
      "status" => status,
      "body" => sanitize_value(body),
      "message" => "HTTP #{status} from preview origin"
    }
  end

  def format({tag, a, b}) when is_atom(tag) do
    %{
      "error" => Atom.to_string(tag),
      "details" => sanitize_value(%{"a" => a, "b" => b}),
      "message" => tuple_message(tag, a, b)
    }
  end

  def format({key, value}) when is_atom(key) do
    %{
      "error" => Atom.to_string(key),
      "details" => sanitize_value(value),
      "message" => Atom.to_string(key)
    }
  end

  def format(reason) when is_atom(reason) do
    %{"error" => Atom.to_string(reason), "message" => Atom.to_string(reason)}
  end

  def format(reason) when is_binary(reason) do
    %{"error" => "tool_error", "message" => reason}
  end

  def format(reason) do
    %{"error" => "tool_error", "message" => inspect(reason)}
  end

  @spec summary(term()) :: String.t()
  def summary(reason) do
    case format(reason) do
      %{"message" => message} when is_binary(message) and message != "" -> message
      %{message: message} when is_binary(message) and message != "" -> message
      %{"error" => error} -> "error: " <> error
      %{error: error} -> "error: " <> inspect(error)
      other -> "error: " <> inspect(other)
    end
  end

  @spec tool_result(term()) :: map()
  def tool_result(reason) do
    %{
      content: [%{type: "text", text: summary(reason)}],
      structuredContent: format(reason),
      isError: true
    }
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp ensure_message(%{"message" => message} = map) when is_binary(message) and message != "",
    do: map

  defp ensure_message(%{"error" => error} = map) when is_binary(error) do
    Map.put_new(map, "message", error)
  end

  defp ensure_message(map), do: Map.put_new(map, "message", "tool call failed")

  # Structs are maps but not enumerable, so this clause has to precede the map
  # one — otherwise `Map.new/2` raises Protocol.UndefinedError and a tool error
  # that should have been a structured MCP result becomes an HTTP 500 instead,
  # hiding the reason it was trying to report. Bounded because a struct reached
  # here as an incidental value (an Ecto schema hanging off a changeset, say),
  # not as the thing the caller asked about.
  defp sanitize_value(value) when is_struct(value),
    do: inspect(value, limit: 5, printable_limit: 256)

  defp sanitize_value(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {normalize_key(key), sanitize_value(inner)} end)
  end

  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)

  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(value), do: inspect(value)

  # `[{field, {message, opts}}]`, where opts carries the `%{count}`-style
  # bindings Ecto leaves uninterpolated in the raw message.
  defp changeset_details(errors) do
    errors
    |> Enum.reduce(%{}, fn
      {field, {message, opts}}, acc when is_binary(message) ->
        Map.update(
          acc,
          normalize_key(field),
          [interpolate(message, opts)],
          &(&1 ++ [interpolate(message, opts)])
        )

      {field, message}, acc when is_binary(message) ->
        Map.update(acc, normalize_key(field), [message], &(&1 ++ [message]))

      other, acc ->
        Map.update(acc, "base", [inspect(other)], &(&1 ++ [inspect(other)]))
    end)
  end

  defp interpolate(message, opts) when is_list(opts) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string_safe(value))
    end)
  end

  defp interpolate(message, _opts), do: message

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp to_string_safe(value), do: inspect(value)

  defp changeset_message(details) when map_size(details) == 0, do: "validation failed"

  defp changeset_message(details) do
    summary =
      Enum.map_join(details, "; ", fn {field, messages} ->
        "#{field} #{Enum.join(messages, ", ")}"
      end)

    "validation failed: " <> summary
  end

  defp tuple_message(:redirect_blocked, status, location),
    do: "Redirect blocked (#{status}) to #{location}"

  defp tuple_message(:http_status, status, _body), do: "HTTP #{status} from preview origin"

  defp tuple_message(tag, _a, _b), do: Atom.to_string(tag)
end
