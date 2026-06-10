defmodule DevIDE.PreviewControl do
  @moduledoc """
  Agent-first preview control for workspace surfaces.

  Opens controllable preview sessions, records audited actions and
  observations, and enforces workspace URL/origin boundaries.
  """

  import Ecto.Query

  alias DevIDE.Audit
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Previews

  alias DevIDE.Previews.{
    Artifacts,
    ControlAction,
    ControlObservation,
    ControlSession,
    SurfaceResolver,
    Url
  }

  alias DevIde.Repo

  @type session_id :: integer()

  @doc """
  Open a controllable preview session for a named surface.

  Options:
    * `:actor_id` — auditing identity
    * `:assignment_id` — agent run/assignment when present
    * `:adapter` — override configured adapter (`:memory` | `:playwright`)
    * `:mode` — preview display mode (`:iframe` | `:tab`)
  """
  @spec open_session(map(), String.t() | atom(), keyword()) ::
          {:ok, ControlSession.t()} | {:error, term()}
  def open_session(workspace, surface_name, opts \\ []) when is_map(workspace) do
    workspace_id = workspace.id || workspace[:id]

    with {:ok, surface} <- fetch_surface(workspace, surface_name),
         {:ok, preview} <-
           Previews.open_surface(workspace, surface.name,
             actor_id: Keyword.get(opts, :actor_id),
             mode: Keyword.get(opts, :mode, :iframe)
           ),
         {:ok, session} <- persist_session(workspace_id, preview, surface, opts),
         {:ok, _entry} <- start_runtime(session, preview) do
      _ = record_observation(session, nil, "url", %{url: preview.url})
      {:ok, session}
    end
  end

  @doc "Observe the current page state for a session."
  @spec observe(session_id()) :: {:ok, map()} | {:error, term()}
  def observe(session_id) do
    with {:ok, entry} <- fetch_runtime(session_id),
         {:ok, observation} <- entry.adapter_module.observe(entry.adapter_state) do
      _ = record_action_and_observation(entry.session, "observe", %{}, observation)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Click an element by CSS selector or viewport point."
  @spec click(session_id(), map()) :: {:ok, map()} | {:error, term()}
  def click(session_id, target) when is_map(target) do
    with {:ok, entry} <- fetch_runtime(session_id),
         :ok <- ensure_target(target),
         {:ok, adapter_state, observation} <-
           entry.adapter_module.click(entry.adapter_state, target),
         {:ok, _} <- update_runtime(session_id, adapter_state, observation, entry.preview.url) do
      _ =
        record_action_and_observation(entry.session, "click", target, observation,
          actor_id: entry.session.actor_id
        )

      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Type text into an input matched by selector."
  @spec type(session_id(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def type(session_id, selector, text)
      when is_binary(selector) and is_binary(text) do
    with {:ok, entry} <- fetch_runtime(session_id),
         {:ok, adapter_state} <- entry.adapter_module.type(entry.adapter_state, selector, text) do
      _ = update_adapter_state(session_id, adapter_state)

      _ =
        record_action_and_observation(entry.session, "type", %{selector: selector, text: text}, %{
          selector: selector
        })

      {:ok, %{selector: selector, text: text}}
    end
  end

  @doc "Press a keyboard key in the preview session."
  @spec press(session_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def press(session_id, key) when is_binary(key) do
    with {:ok, entry} <- fetch_runtime(session_id),
         {:ok, adapter_state} <- entry.adapter_module.press(entry.adapter_state, key) do
      _ = update_adapter_state(session_id, adapter_state)
      _ = record_action_and_observation(entry.session, "press", %{key: key}, %{key: key})
      {:ok, %{key: key}}
    end
  end

  @doc "Navigate within the allowed preview origin."
  @spec navigate(session_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def navigate(session_id, path_or_url) when is_binary(path_or_url) do
    with {:ok, entry} <- fetch_runtime(session_id),
         url <- Url.resolve_against(path_or_url, entry.preview.url),
         :ok <- ensure_allowed_url(entry, url),
         {:ok, adapter_state, observation} <-
           entry.adapter_module.navigate(entry.adapter_state, url),
         {:ok, _} <- update_runtime(session_id, adapter_state, observation, url) do
      _ =
        record_action_and_observation(entry.session, "navigate", %{url: path_or_url}, observation)

      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Capture a screenshot artifact and observation."
  @spec screenshot(session_id()) :: {:ok, map()} | {:error, term()}
  def screenshot(session_id) do
    with {:ok, entry} <- fetch_runtime(session_id),
         {:ok, adapter_state, observation, artifact} <-
           entry.adapter_module.screenshot(entry.adapter_state) do
      _ = update_adapter_state(session_id, adapter_state)
      artifact_path = persist_screenshot_artifact(entry.session, artifact)

      _ =
        record_action_and_observation(
          entry.session,
          "screenshot",
          %{},
          observation,
          artifact_path: artifact_path
        )

      observation = Map.put(observation, :artifact_path, artifact_path)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Close a preview control session and its runtime state."
  @spec close_session(session_id()) :: {:ok, ControlSession.t()} | {:error, term()}
  def close_session(session_id) do
    with {:ok, entry} <- fetch_runtime(session_id) do
      _ = entry.adapter_module.close(entry.adapter_state)
      _ = Registry.delete(session_id)

      entry.session
      |> ControlSession.changeset(%{status: :closed})
      |> Repo.update()
    else
      {:error, :not_found} ->
        case Repo.get(ControlSession, session_id) do
          %ControlSession{} = session ->
            session |> ControlSession.changeset(%{status: :closed}) |> Repo.update()

          nil ->
            {:error, :not_found}
        end
    end
  end

  @doc "Latest observation for a preview control session."
  @spec latest_observation(session_id()) :: ControlObservation.t() | nil
  def latest_observation(session_id) do
    Repo.one(
      from o in ControlObservation,
        where: o.session_id == ^session_id,
        order_by: [desc: o.inserted_at],
        limit: 1
    )
  end

  @doc "Latest observation for the most recent open control session of a preview."
  @spec latest_observation_for_preview(integer()) :: ControlObservation.t() | nil
  def latest_observation_for_preview(preview_id) do
    session_id =
      Repo.one(
        from s in ControlSession,
          where: s.preview_id == ^preview_id and s.status == :open,
          order_by: [desc: s.inserted_at],
          limit: 1,
          select: s.id
      )

    if session_id, do: latest_observation(session_id)
  end

  @doc "Open control session for a workspace preview record."
  @spec open_for_preview(map(), Previews.Preview.t(), keyword()) ::
          {:ok, ControlSession.t()} | {:error, term()}
  def open_for_preview(workspace, preview, opts \\ []) do
    surface = preview.metadata["surface"] || "preview"
    workspace_id = workspace.id || workspace[:id]

    with {:ok, session} <- persist_session(workspace_id, preview, %{name: surface}, opts),
         {:ok, _entry} <- start_runtime(session, preview) do
      {:ok, session}
    end
  end

  # Starts the adapter runtime and registers it. If the adapter fails to start
  # (or registration fails) the persisted session would otherwise be orphaned in
  # status :open with no live runtime, so we mark it :error before propagating.
  defp start_runtime(session, preview) do
    mod = adapter_module(session.adapter)

    with {:ok, adapter_state} <- mod.start_session(session_payload(session, preview)),
         :ok <-
           Registry.put(
             session.id,
             runtime_entry(session, preview, adapter_state, mod)
           ) do
      {:ok, session}
    else
      {:error, reason} ->
        _ = mark_session_error(session)
        {:error, reason}
    end
  end

  defp mark_session_error(session) do
    session
    |> ControlSession.changeset(%{status: :error})
    |> Repo.update()
  end

  defp persist_session(workspace_id, preview, surface, opts) do
    adapter_name =
      opts
      |> Keyword.get(:adapter, configured_adapter())
      |> Atom.to_string()

    attrs = %{
      workspace_id: workspace_id,
      preview_id: preview.id,
      surface: surface.name,
      adapter: adapter_name,
      current_url: control_url(preview),
      actor_id: Keyword.get(opts, :actor_id),
      assignment_id: Keyword.get(opts, :assignment_id),
      metadata: %{
        "allowed_origins" => preview.metadata["allowed_origins"] || Url.allowed_origins(nil),
        "control_url" => control_url(preview),
        "display_url" => preview.url
      }
    }

    %ControlSession{}
    |> ControlSession.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, session} ->
        Audit.emit!(%{
          action: "preview.session_opened",
          workspace_id: workspace_id,
          actor_id: session.actor_id,
          target_type: "preview_session",
          target_ref: to_string(session.id),
          metadata: %{
            preview_id: preview.id,
            surface: surface.name,
            url: preview.url,
            adapter: adapter_name
          }
        })

      _ ->
        :ok
    end)
  end

  defp runtime_entry(session, preview, adapter_state, adapter_module) do
    %{
      session: session,
      preview: preview,
      adapter_state: adapter_state,
      adapter_module: adapter_module || adapter_module(session.adapter),
      allowed_origins: session.metadata["allowed_origins"] || []
    }
  end

  defp session_payload(session, preview) do
    %{
      session_id: session.id,
      workspace_id: session.workspace_id,
      preview_id: preview.id,
      current_url: control_url(preview),
      allowed_origins: session.metadata["allowed_origins"] || []
    }
  end

  defp control_url(%{metadata: %{"control_url" => url}}) when is_binary(url), do: url
  defp control_url(%{metadata: %{control_url: url}}) when is_binary(url), do: url
  defp control_url(%{url: url}), do: url

  defp fetch_runtime(session_id) do
    case Registry.get(session_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp update_runtime(session_id, adapter_state, observation, url) do
    Registry.update(session_id, fn entry ->
      %{entry | adapter_state: adapter_state}
    end)
    |> case do
      {:ok, entry} ->
        entry.session
        |> ControlSession.changeset(%{current_url: observation[:url] || url})
        |> Repo.update()

      error ->
        error
    end
  end

  defp update_adapter_state(session_id, adapter_state) do
    Registry.update(session_id, fn entry ->
      %{entry | adapter_state: adapter_state}
    end)
  end

  defp fetch_surface(workspace, surface_name) do
    case SurfaceResolver.get(workspace, surface_name) do
      nil -> {:error, :surface_not_found}
      surface -> {:ok, surface}
    end
  end

  defp ensure_allowed_url(entry, url) do
    if Url.within_origin?(url, entry.preview.url, entry.allowed_origins),
      do: :ok,
      else: {:error, :origin_not_allowed}
  end

  defp ensure_target(%{selector: selector}) when is_binary(selector), do: :ok
  defp ensure_target(%{x: x, y: y}) when is_integer(x) and is_integer(y), do: :ok
  defp ensure_target(%{"selector" => selector}) when is_binary(selector), do: :ok
  defp ensure_target(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y), do: :ok
  defp ensure_target(_), do: {:error, :invalid_target}

  defp record_action_and_observation(session, action, params, observation, opts \\ []) do
    Repo.transaction(fn ->
      {:ok, action_row} =
        %ControlAction{}
        |> ControlAction.changeset(%{
          session_id: session.id,
          action: action,
          params: params,
          result: observation,
          actor_id: Keyword.get(opts, :actor_id, session.actor_id),
          assignment_id: session.assignment_id
        })
        |> Repo.insert()

      kinds =
        [
          {"url", %{url: observation[:url]}},
          {"dom_summary", observation[:dom_summary] || %{}},
          {"console_errors", %{errors: observation[:console_errors] || []}},
          {"network_errors", %{errors: observation[:network_errors] || []}}
        ] ++ screenshot_observation(observation, opts)

      for {kind, data} <- kinds, data != %{} do
        record_observation(session, action_row.id, kind, data, opts)
      end

      action_row
    end)
  end

  defp screenshot_observation(observation, opts) do
    case Map.get(observation, :screenshot) || opts[:artifact_path] do
      nil -> []
      %{artifact: _} = shot -> [{"screenshot", shot}]
      path when is_binary(path) -> [{"screenshot", %{artifact_path: path}}]
      _ -> []
    end
  end

  defp record_observation(session, action_id, kind, data, opts \\ []) do
    %ControlObservation{}
    |> ControlObservation.changeset(%{
      session_id: session.id,
      action_id: action_id,
      kind: kind,
      data: data,
      artifact_path: opts[:artifact_path]
    })
    |> Repo.insert()
  end

  defp persist_screenshot_artifact(session, "data:image/png;base64," <> b64) do
    id = System.unique_integer([:positive])
    Artifacts.store_png!(session.workspace_id, id, Base.decode64!(b64))
  end

  defp persist_screenshot_artifact(_session, path) when is_binary(path), do: path
  defp persist_screenshot_artifact(_, _), do: nil

  defp configured_adapter do
    Application.get_env(:dev_ide, :preview_control_adapter, :memory)
  end

  defp adapter_module(nil), do: adapter_module(configured_adapter())

  defp adapter_module(name) when is_binary(name),
    do: adapter_module(String.to_existing_atom(name))

  defp adapter_module(:playwright), do: DevIDE.PreviewControl.PlaywrightAdapter
  defp adapter_module(_), do: DevIDE.PreviewControl.MemoryAdapter

  # Pushes a real page observation to LiveView subscribers so an open Agent
  # preview panel follows agent-driven (MCP) browsing live — not only when the
  # human uses the panel's own controls. Keyed by workspace; the LiveView
  # filters by preview_id. Minimal type/press echoes (no url/dom_summary/
  # artifact_path) are skipped so they don't blank the panel.
  defp broadcast_observation(entry, observation) do
    if real_observation?(observation) do
      Phoenix.PubSub.broadcast(
        DevIde.PubSub,
        "preview:" <> to_string(entry.preview.workspace_id),
        {:preview_observation,
         %{
           preview_id: entry.preview.id,
           session_id: entry.session.id,
           observation: observation
         }}
      )
    end

    :ok
  end

  defp real_observation?(obs) when is_map(obs) do
    Map.has_key?(obs, :url) or Map.has_key?(obs, "url") or
      Map.has_key?(obs, :dom_summary) or Map.has_key?(obs, "dom_summary") or
      Map.has_key?(obs, :artifact_path) or Map.has_key?(obs, "artifact_path")
  end

  defp real_observation?(_), do: false
end
