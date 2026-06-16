defmodule McpCtl.Error do
  @moduledoc """
  Normalizes agent tool errors into MCP-friendly structured payloads.
  """

  @spec format(term()) :: map()
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

  defp sanitize_value(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {normalize_key(key), sanitize_value(inner)} end)
  end

  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)

  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(value), do: inspect(value)

  defp tuple_message(:redirect_blocked, status, location),
    do: "Redirect blocked (#{status}) to #{location}"

  defp tuple_message(:http_status, status, _body), do: "HTTP #{status} from preview origin"

  defp tuple_message(tag, _a, _b), do: Atom.to_string(tag)
end
