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
          optional(:recovery_hints) => [String.t()],
          optional(:read_only_hint) => boolean(),
          optional(:destructive_hint) => boolean(),
          optional(:open_world_hint) => boolean(),
          optional(:idempotent_hint) => boolean(),
          optional(:output_schema) => map()
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
    |> Map.drop([
      :read_only_hint,
      :destructive_hint,
      :open_world_hint,
      :idempotent_hint,
      :output_schema
    ])
    |> Enum.map(fn {key, value} -> {public_key(key), public_value(value)} end)
    |> Map.new()
  end

  def public_metadata(_tool), do: nil

  @doc "Build the standard MCP tools/list definition, including safety annotations."
  @spec mcp_spec(t()) :: map()
  def mcp_spec(tool) do
    %{
      name: tool.name,
      description: tool.description,
      inputSchema: tool.parameters,
      outputSchema: output_schema(tool),
      annotations: annotations(tool)
    }
    |> maybe_put_public_metadata(tool)
  end

  @doc "Derive standard MCP safety hints from Casein's richer tool metadata."
  @spec annotations(t()) :: map()
  def annotations(tool) do
    metadata = Map.get(tool, :metadata, %{})
    mutating? = Map.get(metadata, :mutation?, false)
    danger = Map.get(metadata, :danger_level, :low)
    capabilities = Map.get(metadata, :capabilities, [])

    %{
      readOnlyHint: Map.get(metadata, :read_only_hint, not mutating?),
      destructiveHint:
        Map.get(metadata, :destructive_hint, mutating? and danger == :high),
      idempotentHint: Map.get(metadata, :idempotent_hint, not mutating?),
      openWorldHint:
        Map.get(metadata, :open_world_hint, :terminal_mutation in capabilities)
    }
  end

  @doc "Return a JSON Schema for structured tool results."
  @spec output_schema(t()) :: map()
  def output_schema(tool) do
    tool
    |> Map.get(:metadata, %{})
    |> Map.get(:output_schema, %{type: "object", additionalProperties: true})
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> empty_metadata_value?(value) end)
    |> Map.new()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp maybe_put_public_metadata(spec, tool) do
    case public_metadata(tool) do
      nil -> spec
      metadata -> Map.put(spec, :metadata, metadata)
    end
  end

  defp empty_metadata_value?(nil), do: true
  defp empty_metadata_value?([]), do: true
  defp empty_metadata_value?(value) when is_map(value), do: map_size(value) == 0
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
