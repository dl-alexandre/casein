defmodule Casein.Agents.TidewaveMCP do
  @moduledoc """
  Resolves an optional Tidewave MCP URL for agent client materialization.

  Tidewave is dev-only and never ships in the prod release. Resolution order:

  1. `DEVIDE_TIDEWAVE_MCP_URL` (explicit override, e.g. preview-env pairing)
  2. Self-hosted Tidewave on this BEAM node (`MIX_ENV=dev` / preview-env port)
  3. Workspace metadata (manager `ports.tidewave`, socket-fingerprinted ports)
  4. Latest running ephemeral preview environment from the registry
  """

  alias Casein.Agents.TidewaveCapability
  alias Casein.Previews.EnvRegistry

  @doc "MCP server key for agent client configs."
  @spec server_key(map() | nil) :: String.t()
  def server_key(workspace) do
    "devide-tidewave-#{workspace_slug(workspace)}"
  end

  @doc """
  Resolve a Tidewave MCP URL, or `nil` when unavailable.

  Options:

    * `:tidewave_mcp_url` — explicit override (wins over env)
    * `:preview_env_fallback` — consult preview registry when true (default)
  """
  @spec resolve_url(map() | nil, keyword()) :: String.t() | nil
  def resolve_url(workspace \\ nil, opts \\ []) do
    env_override(opts) ||
      self_hosted_url() ||
      workspace_url(workspace) ||
      preview_registry_url(opts)
  end

  @doc "Normalize a Tidewave UI or MCP URL to the MCP endpoint."
  @spec normalize_mcp_url(String.t()) :: String.t()
  def normalize_mcp_url(url) when is_binary(url) do
    base = String.trim_trailing(url, "/")

    cond do
      String.ends_with?(base, "/tidewave/mcp") -> base
      String.ends_with?(base, "/tidewave") -> base <> "/mcp"
      true -> base <> "/tidewave/mcp"
    end
  end

  defp env_override(opts) do
    case Keyword.get(opts, :tidewave_mcp_url) || non_empty_env("DEVIDE_TIDEWAVE_MCP_URL") do
      url when is_binary(url) and url != "" -> normalize_mcp_url(url)
      _ -> nil
    end
  end

  defp self_hosted_url do
    case TidewaveCapability.detect() do
      %{status: :detected, details: %{mcp_url: url}} when is_binary(url) and url != "" ->
        normalize_mcp_url(url)

      _ ->
        nil
    end
  end

  defp workspace_url(workspace) when is_map(workspace) do
    metadata = workspace_metadata(workspace)

    manager_tidewave_url(metadata) ||
      fingerprint_tidewave_url(metadata)
  end

  defp workspace_url(_), do: nil

  defp manager_tidewave_url(metadata) do
    if is_map(metadata) do
      domain_base = metadata_value(metadata, :domain_base)
      ports = metadata_value(metadata, :ports) || %{}

      with port when is_integer(port) <- Map.get(ports, "tidewave") || Map.get(ports, :tidewave),
           base when is_binary(base) and base != "" <- domain_base do
        normalize_mcp_url("https://tidewave.#{base}")
      else
        _ -> nil
      end
    end
  end

  defp fingerprint_tidewave_url(metadata) do
    if is_map(metadata) do
      metadata
      |> metadata_value(:tidewave_ports)
      |> List.wrap()
      |> Enum.find_value(&fingerprint_entry_mcp_url/1)
    end
  end

  defp fingerprint_entry_mcp_url(%{"mcp_url" => url}) when is_binary(url) and url != "",
    do: normalize_mcp_url(url)

  defp fingerprint_entry_mcp_url(%{mcp_url: url}) when is_binary(url) and url != "",
    do: normalize_mcp_url(url)

  defp fingerprint_entry_mcp_url(%{"url" => url}) when is_binary(url) and url != "",
    do: normalize_mcp_url(url)

  defp fingerprint_entry_mcp_url(%{url: url}) when is_binary(url) and url != "",
    do: normalize_mcp_url(url)

  defp fingerprint_entry_mcp_url(%{"port" => port}) when is_integer(port),
    do: normalize_mcp_url("http://127.0.0.1:#{port}")

  defp fingerprint_entry_mcp_url(%{port: port}) when is_integer(port),
    do: normalize_mcp_url("http://127.0.0.1:#{port}")

  defp fingerprint_entry_mcp_url(_), do: nil

  defp preview_registry_url(opts) do
    if Keyword.get(opts, :preview_env_fallback, true) do
      preview_env_id = non_empty_env("DEVIDE_PREVIEW_ENV_ID")

      instance =
        if is_binary(preview_env_id) do
          EnvRegistry.get(preview_env_id)
        else
          List.first(EnvRegistry.running_instances())
        end

      case instance do
        inst when is_map(inst) ->
          EnvRegistry.tidewave_mcp_url(inst)

        _ ->
          nil
      end
    end
  end

  defp workspace_metadata(workspace) do
    case Map.get(workspace, :metadata) || Map.get(workspace, "metadata") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  defp workspace_slug(workspace) when is_map(workspace) do
    workspace
    |> Map.get(
      :name,
      Map.get(workspace, "name", Map.get(workspace, :id, Map.get(workspace, "id")))
    )
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
    |> case do
      "" -> "workspace"
      slug -> slug
    end
  end

  defp workspace_slug(_), do: "workspace"

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
