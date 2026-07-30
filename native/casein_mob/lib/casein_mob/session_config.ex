defmodule CaseinMob.SessionConfig do
  @moduledoc """
  Device-local settings for the session companion. Multiple host profiles are
  retained, while exactly one profile supplies the active `{url, token}`,
  pinned workspaces, and resume context used by the live socket.

  Backed by `Mob.State` so it survives screen navigation. The pairing is
  provisioned by QR scan (web cockpit → camera bridge) or manual entry; see
  `CaseinMob.SessionClient`. A `config :casein_mob, :session` block can seed a
  dev default so the app connects without pairing on the emulator.

  Simulator/dev launches may also pass `CASEIN_MOB_DEV_PAIRING_URL` and
  `CASEIN_MOB_DEV_PAIRING_TOKEN` (plus optional
  `CASEIN_MOB_DEV_PINNED_WORKSPACES`, comma-separated) as runtime environment
  overrides. This is deliberately prefixed as a dev hook; real pairing state
  still comes from QR/manual pairing.
  """

  @pairing_key :session_pairing
  @pinned_key :session_pinned_workspaces
  @resume_key :session_resume_context
  @profiles_key :session_host_profiles
  @active_profile_key :session_active_host
  @max_cached_cards 30
  @cached_locator_keys ~w(workspace_id session_id tmux_session window pane tab artifact)a

  alias CaseinMob.OriginIdentity

  @doc "Returns `{:ok, url, token}` if a pairing exists, else `:error`."
  @spec pairing() :: {:ok, String.t(), String.t()} | :error
  def pairing do
    case runtime_default_pairing() || active_profile() do
      %{url: url, token: token} when is_binary(url) and is_binary(token) -> {:ok, url, token}
      _ -> :error
    end
  end

  @doc "Active connection details including the stable origin descriptor."
  @spec connection() :: {:ok, map()} | :error
  def connection do
    case runtime_default_pairing() || active_profile() do
      %{url: url, token: token} = profile when is_binary(url) and is_binary(token) ->
        {:ok, normalize_profile(profile)}

      _ ->
        :error
    end
  end

  @doc "Saved host profiles, with credentials omitted."
  @spec host_profiles() :: [
          %{
            origin_id: String.t(),
            display_name: String.t(),
            url: String.t(),
            active?: boolean(),
            read_only?: boolean(),
            last_workspace_id: String.t() | nil
          }
        ]
  def host_profiles do
    active_id = active_profile_id()

    profiles()
    |> Map.values()
    |> Enum.map(fn profile ->
      %{
        origin_id: profile.origin_id,
        display_name: profile.display_name,
        url: profile.url,
        active?: profile.origin_id == active_id,
        read_only?: profile.read_only,
        last_workspace_id: last_workspace_id(profile)
      }
    end)
    |> Enum.sort_by(&{&1.display_name, &1.origin_id})
  end

  @spec put_pairing(String.t(), String.t()) :: :ok
  def put_pairing(url, token) when is_binary(url) and is_binary(token) do
    put_pairing(%{url: url, token: token})
  end

  @spec put_pairing(map()) :: :ok
  def put_pairing(%{url: url, token: token} = attrs)
      when is_binary(url) and is_binary(token) do
    incoming = normalize_profile(attrs)
    existing = Map.get(profiles(), incoming.origin_id, default_profile())

    profile =
      incoming
      |> Map.merge(existing)
      |> Map.merge(Map.take(incoming, [:origin_id, :display_name, :url, :token]))

    Mob.State.put(@profiles_key, Map.put(profiles(), profile.origin_id, profile))

    unless profile.read_only do
      activate_profile(profile)
    end

    :ok
  end

  @doc "Make a saved host the active profile."
  @spec activate_host(String.t()) :: {:ok, String.t(), String.t()} | :error
  def activate_host(id_or_url) when is_binary(id_or_url) do
    case find_profile(id_or_url) do
      %{url: active_url, token: token, read_only: false} = profile
      when is_binary(token) ->
        activate_profile(profile)
        {:ok, active_url, token}

      _ ->
        :error
    end
  end

  @doc "Activate a trusted saved origin and return its full connection descriptor."
  @spec activate_origin(String.t()) :: {:ok, map()} | :error
  def activate_origin(origin_id) when is_binary(origin_id) do
    case Map.get(profiles(), origin_id) do
      %{url: url, token: token, read_only: false} = profile
      when is_binary(url) and is_binary(token) ->
        activate_profile(profile)
        {:ok, profile}

      _ ->
        :error
    end
  end

  @doc """
  Reconcile a server-authenticated descriptor with the active profile.

  Legacy URL-derived profiles may be upgraded once. A different stable id is
  rejected so an untrusted payload cannot retarget the active connection.
  """
  @spec reconcile_active_origin(map()) :: {:ok, map()} | {:error, atom()}
  def reconcile_active_origin(descriptor) when is_map(descriptor) do
    origin_id = descriptor |> map_value(:id) |> present()

    display_name =
      present(map_value(descriptor, :display_name) || map_value(descriptor, :name))

    with true <- is_binary(origin_id),
         profile when is_map(profile) <- active_profile() do
      reconcile_profile(profile, origin_id, display_name)
    else
      false -> {:error, :invalid_origin}
      nil -> {:error, :unknown_origin}
    end
  end

  def reconcile_active_origin(_descriptor), do: {:error, :invalid_origin}

  @doc "Cache a bounded, non-authoritative card summary for a known origin."
  @spec cache_cards(String.t(), [map()], String.t() | nil) :: :ok | {:error, atom()}
  def cache_cards(origin_id, cards, observed_at \\ nil)
      when is_binary(origin_id) and is_list(cards) do
    case Map.get(profiles(), origin_id) do
      nil ->
        {:error, :unknown_origin}

      profile ->
        cached_at = observed_at || DateTime.utc_now() |> DateTime.to_iso8601()

        cache =
          cards
          |> Enum.filter(&(is_map(&1) and present(map_value(&1, :id))))
          |> Enum.take(@max_cached_cards)
          |> Enum.map(&cache_card(&1, origin_id, profile.display_name, cached_at))

        persist_profile(%{profile | cached_cards: cache, cards_cached_at: cached_at})
        :ok
    end
  end

  @doc "Read-only cached cards from inactive origins."
  @spec inactive_cached_cards() :: [map()]
  def inactive_cached_cards do
    active_id = active_profile_id()

    profiles()
    |> Map.values()
    |> Enum.reject(&(&1.origin_id == active_id))
    |> Enum.flat_map(&Map.get(&1, :cached_cards, []))
  end

  @spec clear_pairing() :: :ok
  def clear_pairing do
    active_id = active_profile_id()

    if active_id do
      Mob.State.put(@profiles_key, Map.delete(profiles(), active_id))
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
    case Application.get_env(:casein_mob, :session, [])[:pairing] do
      %{url: url, token: token} when is_binary(url) and is_binary(token) ->
        normalize_profile(%{url: url, token: token})

      _ ->
        nil
    end
  end

  defp active_profile do
    Map.get(profiles(), active_profile_id())
  end

  defp active_profile_id do
    active = Mob.State.get(@active_profile_key, nil)
    current_profiles = profiles_without_active_lookup()

    cond do
      is_binary(active) and Map.has_key?(current_profiles, active) ->
        active

      is_binary(active) ->
        migrate_active_url(current_profiles, active)

      true ->
        nil
    end
  end

  defp profiles do
    profiles_without_active_lookup()
  end

  defp profiles_without_active_lookup do
    case Mob.State.get(@profiles_key, nil) do
      profiles when is_map(profiles) and map_size(profiles) > 0 ->
        normalized =
          Map.new(profiles, fn {_key, profile} ->
            profile = normalize_profile(profile)
            {profile.origin_id, profile}
          end)

        if normalized != profiles, do: Mob.State.put(@profiles_key, normalized)
        normalized

      _ ->
        migrate_legacy_profile()
    end
  end

  defp migrate_legacy_profile do
    case legacy_pairing() do
      %{url: url, token: token} ->
        profile =
          normalize_profile(%{
            url: url,
            token: token,
            pinned_workspaces: Mob.State.get(@pinned_key, config_default_pinned()),
            resume_context: Mob.State.get(@resume_key, nil)
          })

        Mob.State.put(@profiles_key, %{profile.origin_id => profile})
        Mob.State.put(@active_profile_key, profile.origin_id)
        %{profile.origin_id => profile}

      _ ->
        %{}
    end
  end

  defp legacy_pairing do
    Mob.State.get(@pairing_key, config_default_pairing())
  end

  defp activate_profile(profile) do
    Mob.State.put(@active_profile_key, profile.origin_id)

    Mob.State.put(@pairing_key, %{
      origin_id: profile.origin_id,
      display_name: profile.display_name,
      url: profile.url,
      token: profile.token
    })

    Mob.State.put(@pinned_key, Map.get(profile, :pinned_workspaces, []))
    Mob.State.put(@resume_key, Map.get(profile, :resume_context))
  end

  defp persist_profile(profile) do
    Mob.State.put(@profiles_key, Map.put(profiles(), profile.origin_id, profile))
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
      %{origin_id: origin_id} = profile ->
        Mob.State.put(
          @profiles_key,
          Map.put(profiles(), origin_id, Map.put(profile, key, value))
        )

      _ ->
        :ok
    end
  end

  defp storage_key(:pinned_workspaces), do: @pinned_key
  defp storage_key(:resume_context), do: @resume_key

  defp normalize_url(url) do
    OriginIdentity.normalize_url(url)
  end

  defp normalize_profile(profile) when is_map(profile) do
    url = normalize_url(map_value(profile, :url, ""))
    deprecated? = OriginIdentity.deprecated_origin?(url)
    read_only? = deprecated? or map_value(profile, :read_only, false) == true

    origin_id =
      if deprecated? do
        OriginIdentity.legacy_id(url)
      else
        present(map_value(profile, :origin_id)) ||
          OriginIdentity.legacy_id(url)
      end

    display_name =
      if deprecated? do
        "Devbox (legacy)"
      else
        present(map_value(profile, :display_name)) ||
          OriginIdentity.display_name(url)
      end

    %{
      origin_id: origin_id,
      display_name: display_name,
      url: url,
      token: if(read_only?, do: nil, else: map_value(profile, :token)),
      read_only: read_only?,
      pinned_workspaces: map_value(profile, :pinned_workspaces, []),
      resume_context: map_value(profile, :resume_context),
      cached_cards: map_value(profile, :cached_cards, []),
      cards_cached_at: map_value(profile, :cards_cached_at)
    }
  end

  defp default_profile do
    %{
      read_only: false,
      pinned_workspaces: [],
      resume_context: nil,
      cached_cards: [],
      cards_cached_at: nil
    }
  end

  defp cache_card(card, origin_id, display_name, cached_at) do
    card_id = present(map_value(card, :id))

    %{
      "id" => card_id,
      "qualified_id" => "#{origin_id}:#{card_id}",
      "origin" => %{"id" => origin_id, "display_name" => display_name},
      "workspace_id" => cache_text(card, :workspace_id),
      "workspace_name" => cache_text(card, :workspace_name),
      "session_id" => cache_text(card, :session_id),
      "title" => cache_text(card, :title),
      "body" => cached_body(card),
      "type" => cache_text(card, :type),
      "kind" => cache_text(card, :kind),
      "status" => cache_text(card, :status),
      "priority" => cache_priority(card),
      "updated_at" => cache_text(card, :updated_at),
      "resume" => cached_resume(map_value(card, :resume, %{}), origin_id, cached_at),
      "evidence" =>
        cached_evidence(map_value(card, :evidence), origin_id, display_name, cached_at),
      "_cached" => true,
      "_cached_at" => cached_at
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp cache_text(card, key), do: card |> map_value(key) |> present()

  defp cached_body(card) do
    if map_value(card, :type) in [:clarification, "clarification"],
      do: "Open Casein to view this request.",
      else: cache_text(card, :body)
  end

  defp cache_priority(card) do
    case map_value(card, :priority) do
      priority when is_integer(priority) -> priority
      priority when is_binary(priority) -> present(priority)
      _ -> nil
    end
  end

  defp cached_resume(resume, origin_id, cached_at) when is_map(resume) do
    %{
      "version" => map_value(resume, :version),
      "state" => map_value(resume, :state),
      "phase" => map_value(resume, :phase),
      "availability" => "offline_resumable",
      "freshness" => %{"kind" => "cached", "observed_at" => cached_at},
      "task_ref" => cached_task_ref(map_value(resume, :task_ref)),
      "locator" => cached_locator(map_value(resume, :locator, %{}), origin_id)
    }
  end

  defp cached_resume(_resume, origin_id, cached_at) do
    cached_resume(%{}, origin_id, cached_at)
  end

  defp cached_task_ref(task_ref) when is_map(task_ref) do
    case {present(map_value(task_ref, :type)), present(map_value(task_ref, :id))} do
      {type, id} when is_binary(type) and is_binary(id) ->
        %{"type" => type, "id" => id}

      _ ->
        nil
    end
  end

  defp cached_task_ref(_task_ref), do: nil

  defp cached_locator(locator, origin_id) when is_map(locator) do
    @cached_locator_keys
    |> Enum.reduce(%{"origin_id" => origin_id}, fn key, acc ->
      case present(map_value(locator, key)) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  defp cached_locator(_locator, origin_id), do: %{"origin_id" => origin_id}

  # Cache only bounded evidence metadata. Diff excerpts, artifact URLs/content,
  # and live actions are intentionally excluded from inactive-origin storage.
  defp cached_evidence(evidence, origin_id, display_name, cached_at)
       when is_map(evidence) do
    changed_files = cached_changed_files(map_value(evidence, :changed_files))
    artifact = cached_artifact(map_value(evidence, :artifact))

    if is_nil(changed_files) and is_nil(artifact) do
      nil
    else
      %{
        "version" => map_value(evidence, :version),
        "origin" => %{"id" => origin_id, "display_name" => display_name},
        "freshness" => %{"kind" => "cached", "observed_at" => cached_at},
        "changed_files" => changed_files,
        "artifact" => artifact
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp cached_evidence(_evidence, _origin_id, _display_name, _cached_at), do: nil

  defp cached_changed_files(changed_files) when is_map(changed_files) do
    files =
      changed_files
      |> map_value(:files, [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 240))
      |> Enum.take(8)

    if files == [] do
      nil
    else
      %{
        "count" => length(files),
        "files" => files,
        "truncated" => map_value(changed_files, :truncated) == true
      }
    end
  end

  defp cached_changed_files(_changed_files), do: nil

  defp cached_artifact(artifact) when is_map(artifact) do
    case present(map_value(artifact, :filename)) do
      filename when is_binary(filename) and byte_size(filename) <= 240 ->
        %{
          "kind" => present(map_value(artifact, :kind)),
          "filename" => filename,
          "media_type" => present(map_value(artifact, :media_type)),
          "byte_size" => map_value(artifact, :byte_size)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _ ->
        nil
    end
  end

  defp cached_artifact(_artifact), do: nil

  defp find_profile(id_or_url) do
    normalized_url = normalize_url(id_or_url)

    Map.get(profiles(), id_or_url) ||
      Enum.find_value(profiles(), fn {_origin_id, profile} ->
        if profile.url == normalized_url, do: profile
      end)
  end

  defp reconcile_profile(%{origin_id: origin_id} = profile, origin_id, display_name) do
    profile = %{profile | display_name: display_name || profile.display_name}
    persist_profile(profile)
    {:ok, profile}
  end

  defp reconcile_profile(%{origin_id: "legacy_" <> _rest} = legacy, origin_id, display_name) do
    existing = Map.get(profiles(), origin_id, default_profile())

    profile =
      existing
      |> Map.merge(legacy, fn
        :pinned_workspaces, current, previous -> Enum.uniq(current ++ previous)
        :cached_cards, current, previous -> Enum.take(current ++ previous, @max_cached_cards)
        _key, current, _previous -> current
      end)
      |> Map.put(:origin_id, origin_id)
      |> Map.put(:display_name, display_name || legacy.display_name)

    updated = profiles() |> Map.delete(legacy.origin_id) |> Map.put(origin_id, profile)
    Mob.State.put(@profiles_key, updated)
    activate_profile(profile)
    {:ok, profile}
  end

  defp reconcile_profile(_profile, _origin_id, _display_name), do: {:error, :origin_mismatch}

  defp migrate_active_url(profiles, active_url) do
    normalized_url = normalize_url(active_url)

    case Enum.find_value(profiles, &matching_origin_id(&1, normalized_url)) do
      nil ->
        nil

      origin_id ->
        Mob.State.put(@active_profile_key, origin_id)
        origin_id
    end
  end

  defp matching_origin_id({origin_id, %{url: url}}, url), do: origin_id
  defp matching_origin_id(_profile, _url), do: nil

  defp map_value(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key), default)
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp last_workspace_id(profile) do
    case Map.get(profile, :resume_context) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) -> workspace_id
      %{"workspace_id" => workspace_id} when is_binary(workspace_id) -> workspace_id
      _ -> profile |> Map.get(:pinned_workspaces, []) |> List.first()
    end
  end

  defp config_default_pinned do
    Application.get_env(:casein_mob, :session, [])[:pinned_workspaces] || []
  end

  defp runtime_default_pairing do
    with url when is_binary(url) <- present_env("CASEIN_MOB_DEV_PAIRING_URL"),
         token when is_binary(token) <- present_env("CASEIN_MOB_DEV_PAIRING_TOKEN") do
      %{url: url, token: token}
    else
      _ -> nil
    end
  end

  defp runtime_default_pinned do
    case present_env("CASEIN_MOB_DEV_PINNED_WORKSPACES") do
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
