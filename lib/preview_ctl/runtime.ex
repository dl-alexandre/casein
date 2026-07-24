defmodule PreviewCtl.Runtime do
  @moduledoc """
  Adapter startup and registry wiring for preview control sessions.

  Ecto persistence, audit, and PubSub remain in host applications such as
  `Casein.Previews.Control`.
  """

  alias PreviewCtl.{Registry, Session}

  @doc "Start an adapter runtime and register it under `session_id`."
  @spec start(integer(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(session_id, session, preview, opts \\ [])
      when is_integer(session_id) and is_map(session) and is_map(preview) do
    mod = adapter_module(session, opts)

    with {:ok, adapter_state} <- mod.start_session(adapter_start_payload(session, preview)),
         :ok <- Registry.put(session_id, entry(session, preview, adapter_state, mod)) do
      {:ok, session}
    end
  end

  @doc "Ensure a registry entry exists for a persisted session."
  @spec ensure_registered(integer(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_registered(session_id, session, preview, opts \\ [])
      when is_integer(session_id) and is_map(session) and is_map(preview) do
    case Registry.get(session_id) do
      nil -> start(session_id, session, preview, opts)
      _entry -> {:ok, session}
    end
  end

  @doc "Build a registry entry map for a running adapter."
  @spec entry(map(), map(), map(), module() | nil) :: map()
  def entry(session, preview, adapter_state, adapter_module) do
    %{
      session: session,
      preview: preview,
      adapter_state: adapter_state,
      adapter_module: adapter_module || adapter_module(session, []),
      allowed_origins: allowed_origins(session)
    }
  end

  @doc "Payload passed to adapter `start_session/1`."
  @spec adapter_start_payload(map(), map()) :: map()
  def adapter_start_payload(session, preview) do
    %{
      session_id: session.id,
      workspace_id: Map.get(session, :workspace_id),
      preview_id: Map.get(preview, :id),
      current_url: session.current_url || control_url(preview),
      allowed_origins: metadata_value(session.metadata, "allowed_origins") || [],
      default_headers: metadata_value(session.metadata, "default_headers") || %{},
      storage_profile: metadata_value(session.metadata, "storage_profile") || "ephemeral",
      storage_profile_name: metadata_value(session.metadata, "storage_profile_name"),
      storage_profile_key: metadata_value(session.metadata, "storage_profile_key"),
      storage_state_path: metadata_value(session.metadata, "storage_state_path")
    }
  end

  @doc """
  Apply configured default HTTP headers when the caller did not supply any.

  `env_key` names an `Application.get_env/2` key on `:casein` (or another app
  passed via `:app` in opts).
  """
  @spec with_default_headers(keyword(), keyword()) :: keyword()
  def with_default_headers(opts, config_opts \\ []) do
    case Keyword.get(opts, :default_headers) do
      headers when is_map(headers) and map_size(headers) > 0 ->
        opts

      _ ->
        app = Keyword.get(config_opts, :app, :casein)
        key = Keyword.get(config_opts, :env_key, :preview_default_headers)

        case Application.get_env(app, key) do
          headers when is_map(headers) and map_size(headers) > 0 ->
            Keyword.put(opts, :default_headers, headers)

          _ ->
            opts
        end
    end
  end

  @doc "Whether an existing open session can be reused for the requested opts."
  @spec matches_reuse_opts?(map(), keyword()) :: boolean()
  def matches_reuse_opts?(session, opts) when is_map(session) do
    session.actor_id == Keyword.get(opts, :actor_id) and
      session.assignment_id == Keyword.get(opts, :assignment_id) and
      metadata_value(session.metadata, "isolation_key") == Keyword.get(opts, :isolation_key) and
      (metadata_value(session.metadata, "storage_profile") || "ephemeral") ==
        storage_profile(opts) and
      (metadata_value(session.metadata, "storage_profile_name") || nil) ==
        Keyword.get(opts, :storage_profile_name) and
      metadata_value(session.metadata, "default_headers") ==
        Keyword.get(opts, :default_headers, %{})
  end

  defp storage_profile(opts) do
    case Keyword.get(opts, :storage_profile) do
      value when value in [:workspace, "workspace"] -> "workspace"
      value when value in [:profile, "profile"] -> "profile"
      _ -> "ephemeral"
    end
  end

  defp adapter_module(session, opts) do
    adapter = adapter_name(session) || Keyword.get(opts, :adapter)
    Session.adapter_for(adapter)
  end

  defp adapter_name(%{adapter: name}) when is_binary(name) and name != "", do: name
  defp adapter_name(%{adapter: name}) when is_atom(name), do: name
  defp adapter_name(_), do: nil

  defp allowed_origins(session) do
    metadata_value(session.metadata, "allowed_origins") || []
  end

  defp control_url(%{metadata: %{"control_url" => url}}) when is_binary(url), do: url
  defp control_url(%{metadata: %{control_url: url}}) when is_binary(url), do: url
  defp control_url(%{url: url}), do: url
  defp control_url(_), do: nil

  defp metadata_value(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp metadata_value(_, _), do: nil
end
