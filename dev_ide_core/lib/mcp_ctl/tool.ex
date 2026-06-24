defmodule McpCtl.Tool do
  @moduledoc """
  Helpers for building MCP JSON tool definition maps.
  """

  @type t :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map(),
          optional(:metadata) => metadata()
        }

  @type danger_level :: :low | :medium | :high

  @type metadata :: %{
          optional(:mutation?) => boolean(),
          optional(:danger_level) => danger_level(),
          optional(:capabilities) => [atom()],
          optional(:policy_tags) => [atom()],
          optional(:examples) => [map()],
          optional(:recovery_hints) => [String.t()]
        }

  @spec define(String.t(), String.t(), map()) :: t()
  @spec define(String.t(), String.t(), map(), metadata()) :: t()
  def define(name, description, parameters, metadata \\ %{})
      when is_binary(name) and is_binary(description) and is_map(parameters) do
    tool = %{name: name, description: description, parameters: parameters}

    case normalize_metadata(metadata) do
      meta when meta == %{} -> tool
      meta -> Map.put(tool, :metadata, meta)
    end
  end

  @spec object(map(), list()) :: map()
  def object(properties, required \\ []) when is_map(properties) and is_list(required) do
    %{
      type: "object",
      properties: properties,
      required: Enum.map(required, &to_string/1)
    }
  end

  @spec put_metadata(t(), metadata()) :: t()
  def put_metadata(
        %{name: name, description: description, parameters: parameters} = tool,
        metadata
      )
      when is_binary(name) and is_binary(description) and is_map(parameters) and is_map(metadata) do
    existing = Map.get(tool, :metadata, %{})

    case normalize_metadata(Map.merge(existing, metadata)) do
      meta when meta == %{} -> Map.delete(tool, :metadata)
      meta -> Map.put(tool, :metadata, meta)
    end
  end

  @spec public_metadata(t() | map()) :: map() | nil
  def public_metadata(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {public_key(key), public_value(value)} end)
    |> Map.new()
  end

  def public_metadata(_tool), do: nil

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> empty_metadata_value?(value) end)
    |> Map.new()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp empty_metadata_value?(nil), do: true
  defp empty_metadata_value?([]), do: true
  defp empty_metadata_value?(%{}), do: true
  defp empty_metadata_value?(_value), do: false

  defp public_key(:mutation?), do: "mutation"
  defp public_key(key) when is_atom(key), do: Atom.to_string(key)
  defp public_key(key) when is_binary(key), do: key
  defp public_key(key), do: to_string(key)

  defp public_value(value) when is_boolean(value) or is_nil(value), do: value
  defp public_value(value) when is_atom(value), do: Atom.to_string(value)
  defp public_value(value) when is_list(value), do: Enum.map(value, &public_value/1)

  defp public_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> {public_key(key), public_value(inner)} end)
    |> Map.new()
  end

  defp public_value(value), do: value
end
