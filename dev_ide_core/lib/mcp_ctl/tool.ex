defmodule McpCtl.Tool do
  @moduledoc """
  Helpers for building MCP JSON tool definition maps.
  """

  @type t :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:parameters) => map()
        }

  @spec define(String.t(), String.t(), map()) :: t()
  def define(name, description, parameters)
      when is_binary(name) and is_binary(description) and is_map(parameters) do
    %{name: name, description: description, parameters: parameters}
  end

  @spec object(map(), list()) :: map()
  def object(properties, required \\ []) when is_map(properties) and is_list(required) do
    %{
      type: "object",
      properties: properties,
      required: Enum.map(required, &to_string/1)
    }
  end
end
