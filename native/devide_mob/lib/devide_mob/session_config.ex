defmodule DevideMob.SessionConfig do
  @moduledoc """
  Device-local settings for the session companion. Multiple host profiles are
  retained, while exactly one profile supplies the active `{url, token}`,
  pinned workspaces, and resume context used by the live socket.

  Backed by `Mob.State` so it survives screen navigation. The pairing is
  provisioned by QR scan (web cockpit → camera bridge) or manual entry; see
  `DevideMob.SessionClient`. A `config :devide_mob, :session` block can seed a
  dev default so the app connects without pairing on the emulator.

  Simulator/dev launches may also pass `DEVIDE_MOB_DEV_PAIRING_URL` and
  `DEVIDE_MOB_DEV_PAIRING_TOKEN` (plus optional
  `DEVIDE_MOB_DEV_PINNED_WORKSPACES`, comma-separated) as runtime environment
  overrides. This is deliberately prefixed as a dev hook; real pairing state
  still comes from QR/manual pairing.
  """

  @pairing_key :session_pairing
  @pinned_key :session_pinned_workspaces
  @resume_key :session_resume_context
  @profiles_key :session_host_profiles
  @active_profile_key :session_active_host

  @doc "Returns `{:ok, url, token}` if a pairing exists, else `:error`."
  @spec pairing() :: {:ok, String.t(), String.t()} | :error
  def pairing do
    case runtime_default_pairing() || active_profile() || legacy_pairing() do
      %{url: url, token: token} when is_binary(url) and is_binary(token) -> {:ok, url, token}
      _ -> :error
    end
  end

  @doc "Saved host profiles, with credentials omitted."
  @spec host_profiles() :: [
          %{url: String.t(), active?: boolean(), last_workspace_id: String.t() | nil}
        ]
  def host_profiles do
    active_url = active_profile_url()

    profiles()
    |> Map.values()
    |> Enum.map(fn profile ->
      %{
        url: profile.url,
        active?: profile.url == active_url,
        last_workspace_id: last_workspace_id(profile)
      }
    end)
    |> Enum.sort_by(& &1.url)
  end

  @spec put_pairing(String.t(), String.t()) :: :ok
  def put_pairing(url, token) when is_binary(url) and is_binary(token) do
    url = normalize_url(url)
    existing = Map.get(profiles(), url, %{pinned_workspaces: [], resume_context: nil})
    profile = Map.merge(existing, %{url: url, token: token})

    Mob.State.put(@profiles_key, Map.put(profiles(), url, profile))
    activate_profile(profile)
    :ok
  end

  @doc "Make a saved host the active profile."
  @spec activate_host(String.t()) :: {:ok, String.t(), String.t()} | :error
  def activate_host(url) when is_binary(url) do
    case Map.get(profiles(), normalize_url(url)) do
      %{url: active_url, token: token} = profile ->
        activate_profile(profile)
        {:ok, active_url, token}

      _ ->
        :error
    end
  end

  @spec clear_pairing() :: :ok
  def clear_pairing do
    active_url = active_profile_url()

    if active_url do
      Mob.State.put(@profiles_key, Map.delete(profiles(), active_url))
    end

    Mob.State.put(@active_profile_key, nil)
    Mob.State.put(@pairing_key, nil)
    Mob.State.put(@pinned_key, [])
    Mob.State.put(@resume_key, nil)
    :ok
  end

  @doc "Clear all session companion state stored on this device."
  @spec clear_all() :: :ok
  def clear_all do
    Mob.State.put(@profiles_key, %{})
    Mob.State.put(@active_profile_key, nil)
    Mob.State.put(@pairing_key, nil)
    Mob.State.put(@pinned_key, [])
    Mob.State.put(@resume_key, nil)
    :ok
  end

  @doc "Workspace ids pinned to the dashboard."
  @spec pinned_workspaces() :: [String.t()]
  def pinned_workspaces do
    runtime_default_pinned() ||
      profile_value(:pinned_workspaces, Mob.State.get(@pinned_key, config_default_pinned()))
  end

  @spec pin_workspace(String.t()) :: :ok
  def pin_workspace(workspace_id) when is_binary(workspace_id) do
    pinned = pinned_workspaces()

    unless workspace_id in pinned do
      put_profile_value(:pinned_workspaces, pinned ++ [workspace_id])
    end

    :ok
  end

  @spec pinned?(String.t()) :: boolean()
  def pinned?(workspace_id) when is_binary(workspace_id) do
    workspace_id in pinned_workspaces()
  end

  @spec unpin_workspace(String.t()) :: :ok
  def unpin_workspace(workspace_id) when is_binary(workspace_id) do
    put_profile_value(:pinned_workspaces, pinned_workspaces() -- [workspace_id])
    clear_resume_context(workspace_id)
    :ok
  end

  @doc "Last workspace/session context the dashboard can offer to resume."
  @spec resume_context() :: map() | nil
  def resume_context do
    case profile_value(:resume_context, Mob.State.get(@resume_key, nil)) do
      %{workspace_id: workspace_id} = context
      when is_binary(workspace_id) and workspace_id != "" ->
        context

      %{"workspace_id" => workspace_id} = context
      when is_binary(workspace_id) and workspace_id != "" ->
        Map.new(context, fn {key, value} -> {normalize_key(key), value} end)

      _ ->
        nil
    end
  end

  @spec put_resume_context(String.t(), keyword()) :: :ok
  def put_resume_context(workspace_id, opts \\ []) when is_binary(workspace_id) do
    if String.trim(workspace_id) == "" do
      :ok
    else
      context =
        %{
          workspace_id: workspace_id,
          session_id: Keyword.get(opts, :session_id),
          source: Keyword.get(opts, :source, :workspace)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      put_profile_value(:resume_context, context)
      :ok
    end
  end

  @spec clear_resume_context() :: :ok
  def clear_resume_context do
    put_profile_value(:resume_context, nil)
    :ok
  end

  @spec clear_resume_context(String.t()) :: :ok
  def clear_resume_context(workspace_id) when is_binary(workspace_id) do
    case resume_context() do
      %{workspace_id: ^workspace_id} -> clear_resume_context()
      _ -> :ok
    end
  end

  def clear_resume_context(_workspace_id) do
    :ok
  end

  defp config_default_pairing do
    case Application.get_env(:devide_mob, :session, [])[:pairing] do
      %{url: url, token: token} when is_binary(url) and is_binary(token) ->
        %{url: url, token: token}

      _ ->
        nil
    end
  end

  defp active_profile do
    Map.get(profiles(), active_profile_url())
  end

  defp active_profile_url do
    Mob.State.get(@active_profile_key, nil)
  end

  defp profiles do
    case Mob.State.get(@profiles_key, nil) do
      profiles when is_map(profiles) and map_size(profiles) > 0 ->
        profiles

      _ ->
        migrate_legacy_profile()
    end
  end

  defp migrate_legacy_profile do
    case legacy_pairing() do
      %{url: url, token: token} ->
        url = normalize_url(url)

        profile = %{
          url: url,
          token: token,
          pinned_workspaces: Mob.State.get(@pinned_key, config_default_pinned()),
          resume_context: Mob.State.get(@resume_key, nil)
        }

        Mob.State.put(@profiles_key, %{url => profile})
        Mob.State.put(@active_profile_key, url)
        %{url => profile}

      _ ->
        %{}
    end
  end

  defp legacy_pairing do
    Mob.State.get(@pairing_key, config_default_pairing())
  end

  defp activate_profile(profile) do
    Mob.State.put(@active_profile_key, profile.url)
    Mob.State.put(@pairing_key, %{url: profile.url, token: profile.token})
    Mob.State.put(@pinned_key, Map.get(profile, :pinned_workspaces, []))
    Mob.State.put(@resume_key, Map.get(profile, :resume_context))
  end

  defp profile_value(key, fallback) do
    case active_profile() do
      profile when is_map(profile) -> Map.get(profile, key, fallback)
      _ -> fallback
    end
  end

  defp put_profile_value(key, value) do
    Mob.State.put(storage_key(key), value)

    case active_profile() do
      %{url: url} = profile ->
        Mob.State.put(@profiles_key, Map.put(profiles(), url, Map.put(profile, key, value)))

      _ ->
        :ok
    end
  end

  defp storage_key(:pinned_workspaces), do: @pinned_key
  defp storage_key(:resume_context), do: @resume_key

  defp normalize_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp last_workspace_id(profile) do
    case Map.get(profile, :resume_context) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) -> workspace_id
      %{"workspace_id" => workspace_id} when is_binary(workspace_id) -> workspace_id
      _ -> profile |> Map.get(:pinned_workspaces, []) |> List.first()
    end
  end

  defp config_default_pinned do
    Application.get_env(:devide_mob, :session, [])[:pinned_workspaces] || []
  end

  defp runtime_default_pairing do
    with url when is_binary(url) <- present_env("DEVIDE_MOB_DEV_PAIRING_URL"),
         token when is_binary(token) <- present_env("DEVIDE_MOB_DEV_PAIRING_TOKEN") do
      %{url: url, token: token}
    else
      _ -> nil
    end
  end

  defp runtime_default_pinned do
    case present_env("DEVIDE_MOB_DEV_PINNED_WORKSPACES") do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp normalize_key("workspace_id"), do: :workspace_id
  defp normalize_key("session_id"), do: :session_id
  defp normalize_key("source"), do: :source
  defp normalize_key(key), do: key
end
