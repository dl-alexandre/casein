defmodule Casein.Agents.WorkspaceTokens do
  @moduledoc """
  Resolves the workspace-scoped API bearer token external agents must use.

  `CaseinWeb.Endpoint.reject_global_mcp_tool_calls/2` rejects MCP `tools/call`
  requests made with the global admin token, so every path that hands a token
  to an agent (materialized `env.sh`, tmux session env) must resolve a
  workspace-scoped token here — never `:api_token` / `CASEIN_API_TOKEN`.
  (An operator may opt a trusted single-tenant box out of that rejection with
  `CASEIN_ALLOW_GLOBAL_MCP_TOOL_CALLS=1` for a full-box orchestrator token;
  agents materialized here should still use workspace-scoped tokens regardless.)

  Tokens live in the `:workspace_api_tokens` registry (token → workspace_id or
  list of ids), seeded at boot from `CASEIN_WORKSPACE_API_TOKENS` and the
  store file. When a workspace has no token yet, one is minted, registered in
  the application env (both auth plugs read it per-request, so it is valid
  immediately), and persisted to the store file so it survives restarts —
  `config/runtime.exs` merges the store back into the registry at boot.
  """

  require Logger

  @doc """
  Resolve the token to hand to an external agent for `workspace`: the scoped
  token (minted on first use), or the global token as a last resort when the
  workspace has no id to scope to — those tool calls will be rejected, so it
  logs a warning.
  """
  @spec for_agent(map()) :: {:ok, String.t()} | {:error, :api_token_missing}
  def for_agent(workspace) when is_map(workspace) do
    workspace_id = Map.get(workspace, :id) || Map.get(workspace, "id")

    case ensure_for(workspace_id) do
      {:ok, token} ->
        {:ok, token}

      {:error, :workspace_id_missing} ->
        name = Map.get(workspace, :name) || Map.get(workspace, "name") || "workspace"

        Logger.warning(
          "resolving agent API token for #{name} to the global token: workspace " <>
            "has no id to scope a token to; MCP tool calls with it will be rejected"
        )

        case global_token() do
          nil -> {:error, :api_token_missing}
          token -> {:ok, token}
        end
    end
  end

  @doc """
  Return the scoped token for `workspace_id`, minting and persisting one when
  the registry has none. `{:error, :workspace_id_missing}` when the workspace
  has no id to scope to.
  """
  @spec ensure_for(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def ensure_for(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case token_for(workspace_id) do
      nil -> mint_for(workspace_id)
      token -> {:ok, token}
    end
  end

  def ensure_for(_workspace_id), do: {:error, :workspace_id_missing}

  @doc "Return the registered scoped token for `workspace_id`, or nil."
  @spec token_for(String.t()) :: String.t() | nil
  def token_for(workspace_id) when is_binary(workspace_id) do
    registry()
    |> Enum.find_value(fn
      {token, ^workspace_id} when is_binary(token) ->
        token

      {token, ids} when is_binary(token) and is_list(ids) ->
        if workspace_id in ids, do: token

      _ ->
        nil
    end)
  end

  @doc """
  Rotate the scoped bearer for `workspace_id`.

  Mints a fresh token, registers it, drops the previous token from the live
  registry and store, and records the previous value in the retired set so
  `stale_grant?/1` can tell a rotated pane from a never-valid bearer.

  Returns `{:ok, new_token, old_token | nil}`.
  """
  @spec rotate_for(String.t()) :: {:ok, String.t(), String.t() | nil} | {:error, term()}
  def rotate_for(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    :global.trans({__MODULE__, self()}, fn ->
      old = token_for(workspace_id)
      token = mint_token()
      register(token, workspace_id)
      drop_token(old)
      retire_token(old, workspace_id)
      persist_rotation(token, old, workspace_id)
      {:ok, token, old}
    end)
  end

  def rotate_for(_workspace_id), do: {:error, :workspace_id_missing}

  @doc """
  True when `token` was a valid workspace bearer that has since been rotated
  out. Used by auth to return an explicit `stale_grant` instead of a generic
  unauthorized for live panes still holding the previous value.
  """
  @spec stale_grant?(String.t()) :: boolean()
  def stale_grant?(token) when is_binary(token) and token != "" do
    case retired_registry() do
      %{^token => _} -> true
      _ -> false
    end
  end

  def stale_grant?(_), do: false

  @doc "Workspace id a retired token used to scope, if any."
  @spec stale_workspace_id(String.t()) :: String.t() | nil
  def stale_workspace_id(token) when is_binary(token) do
    case retired_registry() do
      %{^token => workspace_id} when is_binary(workspace_id) -> workspace_id
      _ -> nil
    end
  end

  def stale_workspace_id(_), do: nil

  defp mint_for(workspace_id) do
    # Serialized so concurrent agent launches for a fresh workspace agree on
    # one token instead of last-write-wins clobbering the registry merge.
    :global.trans({__MODULE__, self()}, fn ->
      case token_for(workspace_id) do
        nil ->
          token = mint_token()
          register(token, workspace_id)
          persist(token, workspace_id)
          {:ok, token}

        token ->
          {:ok, token}
      end
    end)
  end

  defp mint_token, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp register(token, workspace_id) do
    updated =
      :casein
      |> Application.get_env(:workspace_api_tokens, %{})
      |> Map.put(token, workspace_id)

    Application.put_env(:casein, :workspace_api_tokens, updated)
  end

  defp drop_token(nil), do: :ok

  defp drop_token(token) when is_binary(token) do
    updated =
      :casein
      |> Application.get_env(:workspace_api_tokens, %{})
      |> Map.delete(token)

    Application.put_env(:casein, :workspace_api_tokens, updated)
  end

  defp retire_token(nil, _workspace_id), do: :ok

  defp retire_token(token, workspace_id) when is_binary(token) do
    updated =
      :casein
      |> Application.get_env(:workspace_api_tokens_retired, %{})
      |> Map.put(token, workspace_id)

    Application.put_env(:casein, :workspace_api_tokens_retired, updated)
  end

  defp retired_registry do
    case Application.get_env(:casein, :workspace_api_tokens_retired, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # Best effort: a persist failure still leaves the minted token valid in the
  # running node; the next boot or pairing refresh re-mints and re-registers.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(token, workspace_id) do
    path = store_path()
    stored = read_store(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(Map.put(stored, token, workspace_id))),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "workspace token for #{workspace_id} minted but not persisted " <>
            "to #{path}: #{inspect(reason)}; it will not survive a restart"
        )

        :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp persist_rotation(token, old, workspace_id) do
    path = store_path()
    stored = read_store(path)

    stored =
      stored
      |> Map.put(token, workspace_id)
      |> then(fn map -> if is_binary(old), do: Map.delete(map, old), else: map end)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(stored)),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "workspace token rotation for #{workspace_id} not fully persisted " <>
            "to #{path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc "Read the persisted token store (token → workspace_id). Used at boot."
  @spec read_store(Path.t()) :: map()
  # sobelow_skip ["Traversal.FileModule"]
  def read_store(path \\ store_path()) do
    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Path of the persisted token store file."
  @spec store_path() :: Path.t()
  def store_path do
    Application.get_env(:casein, :workspace_tokens_store) ||
      Path.join(home_dir(), ".casein/workspace-api-tokens.json")
  end

  defp registry do
    app_tokens = Application.get_env(:casein, :workspace_api_tokens, %{})
    env_tokens = tokens_from_env(System.get_env("CASEIN_WORKSPACE_API_TOKENS"))

    [app_tokens, env_tokens]
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&Map.to_list/1)
  end

  defp tokens_from_env(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp tokens_from_env(_), do: %{}

  defp global_token do
    case Application.get_env(:casein, :api_token) || System.get_env("CASEIN_API_TOKEN") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp home_dir, do: Casein.Paths.home!()
end
