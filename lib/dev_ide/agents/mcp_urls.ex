defmodule DevIDE.Agents.MCPUrls do
  @moduledoc """
  Builds DevIDE terminal/preview MCP endpoint URLs from app config or env,
  optionally pre-scoping a `workspace_id` query param onto them.
  """

  @doc "Base URL intended for same-host MCP clients."
  def base_url do
    Application.get_env(:dev_ide, :agent_mcp_base_url) ||
      non_empty_env("DEVIDE_AGENT_MCP_BASE_URL") ||
      non_empty_env("DEVIDE_URL") ||
      "http://127.0.0.1:#{System.get_env("PORT", "4000")}"
  end

  def preview_url(workspace_id \\ nil),
    do: base_url() |> endpoint_url("/api/preview/mcp") |> with_workspace_id(workspace_id)

  def terminal_url(workspace_id \\ nil),
    do: base_url() |> endpoint_url("/api/terminals/mcp") |> with_workspace_id(workspace_id)

  defp endpoint_url(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  defp with_workspace_id(url, workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    uri = URI.parse(url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("workspace_id", workspace_id)
      |> URI.encode_query()

    %{uri | query: query}
    |> URI.to_string()
  end

  defp with_workspace_id(url, _workspace_id), do: url

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
