defmodule Casein.Agents.JidoActions.Compatibility do
  @moduledoc """
  OpenCode / MCP compatibility adapter for the typed Jido catalog.

  OpenCode keeps using Code MCP (`POST /api/code/mcp`) and Terminal MCP while
  the Jido path is behind `CASEIN_JIDO_HEADLESS`. This module never opens an
  HTTP loopback: when the flag is on it dispatches the same tool names through
  `Casein.Agents.JidoActions`; when it is off it returns `legacy_opencode` so
  callers stay on the existing MCP servers.
  """

  alias Casein.Agents.JidoActions
  alias Casein.Agents.JidoPod

  @mcp_names ~w(code_read code_search code_apply_patch code_exec)

  @spec mcp_names() :: [String.t()]
  def mcp_names, do: @mcp_names

  @spec path(String.t()) :: :jido_actions | :legacy_opencode
  def path(workspace_id) when is_binary(workspace_id) do
    if JidoPod.enabled?(workspace_id, runtime: :jido), do: :jido_actions, else: :legacy_opencode
  end

  def path(_), do: :legacy_opencode

  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def invoke(name, args, context \\ %{})

  def invoke(name, args, context) when is_binary(name) and is_map(args) and is_map(context) do
    JidoActions.invoke(name, args, context)
  end

  def invoke(_name, _args, context) do
    JidoActions.invoke("unknown", %{}, context || %{})
  end
end
