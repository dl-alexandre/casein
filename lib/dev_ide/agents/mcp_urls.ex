defmodule Casein.Agents.MCPUrls do
  @moduledoc """
  Builds Casein terminal/preview/artifact MCP endpoint URLs from app config or env,
  optionally pre-scoping a `workspace_id` query param onto them.
  """

  @doc "Base URL intended for same-host MCP clients."
  def base_url do
    Application.get_env(:dev_ide, :agent_mcp_base_url) ||
      non_empty_env("DEVIDE_AGENT_MCP_BASE_URL") ||
      non_empty_env("DEVIDE_API_BASE_URL") ||
      non_empty_env("DEVIDE_URL") ||
      "http://127.0.0.1:#{System.get_env("PORT", "4000")}"
  end

  @doc "Base URL for plain Casein API calls from pane-local shims."
  def api_base_url do
    Application.get_env(:dev_ide, :api_base_url) ||
      non_empty_env("DEVIDE_API_BASE_URL") ||
      base_url()
  end

  def preview_url(workspace_id \\ nil, opts \\ []),
    do:
      base_url()
      |> endpoint_url("/api/preview/mcp")
      |> with_query_param("workspace_id", workspace_id)
      |> with_query_param("tmux_session", Keyword.get(opts, :tmux_session))

  def terminal_url(workspace_id \\ nil, opts \\ []),
    do:
      base_url()
      |> endpoint_url("/api/terminals/mcp")
      |> with_query_param("workspace_id", workspace_id)
      |> with_query_param("tmux_session", Keyword.get(opts, :tmux_session))

  def artifact_url(workspace_id \\ nil),
    do:
      base_url()
      |> endpoint_url("/api/artifacts/mcp")
      |> with_query_param("workspace_id", workspace_id)

  defp endpoint_url(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  defp with_query_param(url, _key, value) when value in [nil, ""], do: url

  defp with_query_param(url, key, value) when is_binary(key) and is_binary(value) do
    uri = URI.parse(url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put(key, value)
      |> URI.encode_query()

    %{uri | query: query}
    |> URI.to_string()
  end

  defp with_query_param(url, _key, _value), do: url

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
