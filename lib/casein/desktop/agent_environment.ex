defmodule Casein.Desktop.AgentEnvironment do
  @moduledoc """
  Builds the workspace-scoped environment inherited by native desktop shells.

  This is the environment-materialization half of the Windows agent launcher:
  it keeps provider authentication in the user's normal agent home while
  staging workspace MCP config and Grok's session capability metadata outside
  the project checkout.
  """

  alias Casein.Agents.{MCPMaterializer, MCPUrls, WorkspaceTokens}

  @spec build(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def build(workspace, checkout) when is_map(workspace) and is_binary(checkout) do
    id = value(workspace, :id)
    name = value(workspace, :name) || id || "workspace"

    with true <- (is_binary(id) and id != "") || {:error, :workspace_id_required},
         {:ok, token} <- WorkspaceTokens.for_agent(workspace),
         {:ok, staging} <-
           MCPMaterializer.materialize(workspace,
             checkout: checkout
           ) do
      {:ok,
       %{
         "CASEIN_API_TOKEN" => token,
         "DEVIDE_API_BASE_URL" => MCPUrls.api_base_url(),
         "DEVIDE_WORKSPACE_ID" => id,
         "DEVIDE_WORKSPACE_NAME" => name,
         "DEVIDE_TERMINAL_MCP_URL" => MCPUrls.terminal_url(id),
         "DEVIDE_PREVIEW_MCP_URL" => MCPUrls.preview_url(id),
         "DEVIDE_ARTIFACT_MCP_URL" => MCPUrls.artifact_url(id),
         "DEVIDE_CHECKOUT" => checkout,
         "DEVIDE_AGENT_MCP_HOME" => staging
       }}
    end
  end

  def build(_workspace, _checkout), do: {:error, :workspace_required}

  defp value(workspace, key), do: Map.get(workspace, key) || Map.get(workspace, to_string(key))
end
