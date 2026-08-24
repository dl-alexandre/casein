defmodule Casein.Agents.MCPUrls do
  @moduledoc """
  Builds Casein terminal/preview/artifact MCP endpoint URLs from app config or env,
  optionally pre-scoping a `workspace_id` query param onto them.
  """

  alias Casein.Origin

  @doc "Base URL intended for same-host MCP clients."
  def base_url do
    (Application.get_env(:casein, :agent_mcp_base_url) ||
       non_empty_env("CASEIN_AGENT_MCP_BASE_URL") ||
       non_empty_env("CASEIN_API_BASE_URL") ||
       non_empty_env("CASEIN_URL") ||
       "http://127.0.0.1:#{System.get_env("PORT", "4000")}")
    |> Origin.canonicalize_known_base_url()
  end

  @doc "Base URL for plain Casein API calls from pane-local shims."
  def api_base_url do
    (Application.get_env(:casein, :api_base_url) ||
       non_empty_env("CASEIN_API_BASE_URL") ||
       base_url())
    |> Origin.canonicalize_known_base_url()
  end

  def preview_url(workspace_id \\ nil, opts \\ []) do
    url_base(opts)
    |> endpoint_url("/api/preview/mcp")
    |> with_query_param("workspace_id", workspace_id)
    |> with_query_param("tmux_session", Keyword.get(opts, :tmux_session))
  end

  def terminal_url(workspace_id \\ nil, opts \\ []) do
    url_base(opts)
    |> endpoint_url("/api/terminals/mcp")
    |> with_query_param("workspace_id", workspace_id)
    |> with_query_param("tmux_session", Keyword.get(opts, :tmux_session))
  end

  def artifact_url(workspace_id \\ nil, opts \\ []) do
    url_base(opts)
    |> endpoint_url("/api/artifacts/mcp")
    |> with_query_param("workspace_id", workspace_id)
  end

  @doc """
  OpenCode/Claude server keys matching in-workspace materialization
  (`casein-terminal-<workspace-slug>`).
  """
  def server_keys(workspace) when is_map(workspace) do
    slug =
      workspace
      |> workspace_name()
      |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
      |> String.trim("-")
      |> String.downcase()

    slug = if slug == "", do: "workspace", else: slug
    {"casein-terminal-#{slug}", "casein-preview-#{slug}", "casein-artifact-#{slug}"}
  end

  def server_keys(name) when is_binary(name), do: server_keys(%{name: name})

  @doc """
  Ready-to-paste `.mcp.json` for an external client: workspace-named servers
  and `?workspace_id=` on every URL.
  """
  def client_mcp_json(workspace, token, opts \\ []) when is_binary(token) do
    id = workspace_id(workspace)
    url_opts = url_opts(opts)
    {terminal_key, preview_key, artifact_key} = server_keys(workspace)
    auth = %{"Authorization" => "Bearer " <> token}

    Jason.encode!(
      %{
        "mcpServers" => %{
          terminal_key => %{"url" => terminal_url(id, url_opts), "headers" => auth},
          preview_key => %{"url" => preview_url(id, url_opts), "headers" => auth},
          artifact_key => %{"url" => artifact_url(id, url_opts), "headers" => auth}
        }
      },
      pretty: true
    )
  end

  @doc "Build an MCP URL carrying a short-lived ticket for its bound surface."
  def ticket_url(surface, workspace_id, tmux_session, ticket)
      when surface in ~w(terminal preview artifact) and is_binary(ticket) do
    url =
      case surface do
        "terminal" -> terminal_url(workspace_id, tmux_session: tmux_session)
        "preview" -> preview_url(workspace_id, tmux_session: tmux_session)
        "artifact" -> artifact_url(workspace_id)
      end

    with_query_param(url, "ticket", ticket)
  end

  @doc "Canonicalizes only recognized retired managed origins."
  def canonicalize_known_base_url(base_url) when is_binary(base_url),
    do: Origin.canonicalize_known_base_url(base_url)

  defp url_base(opts) do
    case Keyword.get(opts, :base_url) do
      base when is_binary(base) and base != "" -> Origin.canonicalize_known_base_url(base)
      _ -> base_url()
    end
  end

  defp url_opts(opts) do
    case Keyword.get(opts, :base_url) do
      base when is_binary(base) and base != "" -> [base_url: base]
      _ -> []
    end
  end

  defp workspace_id(workspace) when is_map(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  defp workspace_name(workspace) when is_map(workspace) do
    Map.get(workspace, :name) || Map.get(workspace, "name") ||
      Map.get(workspace, :id) || Map.get(workspace, "id") ||
      "workspace"
  end

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
