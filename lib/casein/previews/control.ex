defmodule Casein.Previews.Control do
  @moduledoc """
  Agent-first preview control for workspace surfaces.

  Opens controllable preview sessions, records audited actions and
  observations, and enforces workspace URL/origin boundaries.
  """

  import Ecto.Query

  alias Casein.Audit
  alias Casein.PreviewActivity
  alias Casein.PreviewPanes
  alias PreviewCtl.{Runtime, Session}
  alias Casein.Previews
  alias Casein.Previews.Deps

  alias Casein.Previews.{
    Artifacts,
    ControlAction,
    ControlObservation,
    ControlSession,
    Storage,
    SurfaceResolver,
    Url,
    WorkspaceContext
  }

  alias Casein.Repo

  @type session_id :: integer()

  @doc """
  Open a controllable preview session for a named surface.

  Options:
    * `:actor_id` — auditing identity
    * `:assignment_id` — agent run/assignment when present
    * `:adapter` — override configured adapter (`:memory` | `:playwright`)
    * `:mode` — preview display mode (`:tab`)
    * `:storage_profile` — `:ephemeral` (default), `:workspace`, or `:profile`
    * `:storage_profile_name` — required for `:profile`
  """
  @spec open_session(map(), String.t() | atom(), keyword()) ::
          {:ok, ControlSession.t()} | {:error, term()}
  def open_session(workspace, surface_name, opts \\ []) when is_map(workspace) do
    workspace = WorkspaceContext.prepare(workspace)
    workspace_id = workspace.id || workspace[:id]

    with {:ok, surface} <- fetch_surface(workspace, surface_name),
         {:ok, preview} <-
           Previews.open_surface(workspace, surface.name,
             actor_id: Keyword.get(opts, :actor_id),
             mode: Keyword.get(opts, :mode, :tab)
           ),
         {:ok, session} <-
           find_or_persist_session(
             workspace_id,
             preview,
             surface,
             Keyword.put(opts, :control_url, surface.url)
           ) do
      _ = record_observation(session, nil, "url", %{url: session.current_url || preview.url})
      _ = broadcast_preview_opened(preview, session)
      {:ok, session}
    end
  end

  @doc "Observe the current page state for a session."
  @spec observe(session_id()) :: {:ok, map()} | {:error, term()}
  def observe(session_id) do
    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, observation} <- Session.observe(session_id) do
      _ = record_action_and_observation(entry.session, "observe", %{}, observation)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Observe the current page state through the browser runtime when available."
  @spec observe_live(session_id()) :: {:ok, map()} | {:error, term()}
  def observe_live(session_id) do
    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, observation} <- Session.observe_live(session_id),
         {:ok, _} <- sync_session_url(entry, observation) do
      _ = record_action_and_observation(entry.session, "observe_live", %{}, observation)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Return localStorage and sessionStorage for the current preview origin."
  @spec get_storage(session_id()) :: {:ok, map()} | {:error, term()}
  def get_storage(session_id) do
    with {:ok, entry, storage} <- Session.get_storage(session_id),
         {:ok, _} <- sync_session_url(entry, storage) do
      _ = record_action_and_observation(entry.session, "get_storage", %{}, storage)
      {:ok, storage}
    end
  end

  @doc "Inject cookies into the persistent browser context without returning their values."
  @spec set_cookies(session_id(), [map()]) :: {:ok, map()} | {:error, term()}
  def set_cookies(session_id, cookies) when is_list(cookies) do
    with {:ok, entry, result} <- Session.set_cookies(session_id, cookies),
         {:ok, _} <- sync_session_url(entry, result) do
      audit = Map.take(result, [:cookie_count, :cookie_names, "cookie_count", "cookie_names"])
      _ = record_action_and_observation(entry.session, "set_cookies", audit, result)
      {:ok, result}
    end
  end

  @doc "Clear cookies, localStorage, and sessionStorage for the current preview origin."
  @spec clear_storage(session_id()) :: {:ok, map()} | {:error, term()}
  def clear_storage(session_id) do
    with {:ok, entry, storage} <- Session.clear_storage(session_id),
         {:ok, _} <- sync_session_url(entry, storage) do
      _ = record_action_and_observation(entry.session, "clear_storage", %{}, storage)
      {:ok, storage}
    end
  end

  @doc "Click an element by CSS selector or viewport point."
  @spec click(session_id(), map()) :: {:ok, map()} | {:error, term()}
  def click(session_id, target) when is_map(target) do
    with :ok <- ensure_local_runtime(session_id) do
      case Session.click(session_id, target) do
        {:ok, entry, observation} ->
          observation = persist_diff_observation(entry.session, observation)

          with {:ok, _} <- sync_session_url(entry, observation) do
            _ =
              record_action_and_observation(entry.session, "click", target, observation,
                actor_id: entry.session.actor_id
              )

            _ = broadcast_observation(entry, observation)
            {:ok, observation}
          end

        {:error, {:origin_not_allowed, observation}} when is_map(observation) ->
          {:error, {:origin_not_allowed, observation}}

        # fetch/ensure_target failures (stale or malformed session) surface here
        # as {:error, term}; propagate rather than raise CaseClauseError.
        other ->
          other
      end
    end
  end

  @doc "Type text into an input matched by selector."
  @spec type(session_id(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def type(session_id, selector, text, opts \\ %{})
      when is_binary(selector) and is_binary(text) and is_map(opts) do
    with {:ok, entry, observation} <- Session.type(session_id, selector, text, opts),
         observation <- persist_diff_observation(entry.session, observation),
         {:ok, _} <- sync_session_url(entry, observation) do
      params = Map.merge(%{selector: selector, text: text}, opts)

      _ =
        record_action_and_observation(entry.session, "type", params, observation,
          actor_id: entry.session.actor_id
        )

      _ = broadcast_observation(entry, observation)

      {:ok, observation}
    end
  end

  @doc "Press a keyboard key in the preview session."
  @spec press(session_id(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def press(session_id, key, opts \\ %{}) when is_binary(key) and is_map(opts) do
    with {:ok, entry, observation} <- Session.press(session_id, key, opts),
         observation <- persist_diff_observation(entry.session, observation),
         {:ok, _} <- sync_session_url(entry, observation) do
      _ = record_action_and_observation(entry.session, "press", %{key: key}, observation)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Navigate within the allowed preview origin."
  @spec navigate(session_id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def navigate(session_id, path_or_url, opts \\ []) when is_binary(path_or_url) do
    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, observation} <- Session.navigate(session_id, path_or_url),
         {:ok, _} <- sync_session_url(entry, observation) do
      _ =
        record_action_and_observation(
          entry.session,
          "navigate",
          %{url: path_or_url},
          observation,
          opts
        )

      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Navigate the preview browser history back."
  @spec go_back(session_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def go_back(session_id, opts \\ []), do: history_action(session_id, :go_back, "go_back", opts)

  @doc "Navigate the preview browser history forward."
  @spec go_forward(session_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def go_forward(session_id, opts \\ []),
    do: history_action(session_id, :go_forward, "go_forward", opts)

  @doc "Reload the current preview browser page."
  @spec reload(session_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def reload(session_id, opts \\ []), do: history_action(session_id, :reload, "reload", opts)

  @doc "Capture a screenshot artifact and observation."
  @spec screenshot(session_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def screenshot(session_id, opts \\ []) do
    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, observation, artifact} <- Session.screenshot(session_id) do
      artifact_path = persist_screenshot_artifact(entry.session, artifact)

      _ =
        record_action_and_observation(
          entry.session,
          "screenshot",
          %{},
          observation,
          Keyword.put(opts, :artifact_path, artifact_path)
        )

      observation = Map.put(observation, :artifact_path, artifact_path)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc """
  Diff two persisted preview artifacts (by their servable `/preview-artifacts/…`
  paths) for a workspace. Returns pixel-diff stats plus a persisted overlay
  image. Pure pixel diff — no `affected_element_ids`, since arbitrary snapshots
  carry no DOM context.
  """
  @spec compare_snapshots(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compare_snapshots(workspace, artifact_a, artifact_b, opts \\ [])
      when is_map(workspace) and is_binary(artifact_a) and is_binary(artifact_b) do
    workspace_id = Map.get(workspace, :id) || Map.get(workspace, "id")

    with {:ok, bytes_a} <- read_artifact(workspace_id, artifact_a),
         {:ok, bytes_b} <- read_artifact(workspace_id, artifact_b),
         {:ok, diff} <-
           differ().compare_images(
             Base.encode64(bytes_a),
             Base.encode64(bytes_b),
             compare_opts(opts)
           ) do
      {:ok, persist_compare_diff(workspace_id, diff)}
    end
  end

  defp differ, do: Application.get_env(:casein, :preview_differ, PreviewCtl.Playwright.Adapter)

  defp compare_opts(opts) do
    opts |> Keyword.take([:threshold, :cell, :cellHits, :minArea]) |> Map.new()
  end

  # Parse a servable /preview-artifacts/<ws>/<file> path (a full URL is accepted;
  # only its path is used), enforce workspace scope, then read the bytes through
  # the containment-checked artifact store.
  defp read_artifact(workspace_id, path) when is_binary(path) do
    normalized = URI.parse(path).path || path

    case Path.split(String.trim_leading(normalized, "/")) do
      ["preview-artifacts", ^workspace_id, filename] ->
        try do
          {:ok, File.read!(Storage.LocalDisk.safe_path!(workspace_id, filename))}
        rescue
          File.Error -> {:error, :artifact_not_found}
          ArgumentError -> {:error, :invalid_artifact_path}
        end

      ["preview-artifacts", _other_ws, _filename] ->
        {:error, :workspace_scope_mismatch}

      _ ->
        {:error, :invalid_artifact_path}
    end
  end

  defp persist_compare_diff(workspace_id, diff) when is_map(diff) do
    base = %{
      diff_pct: diff["diff_pct"],
      changed_pixels: diff["changed_pixels"],
      dimensions: diff["dimensions"],
      changed_regions: diff["changed_regions"] || [],
      noise_filtered: diff["noise_filtered"]
    }

    # Storage failure degrades gracefully — the diff stats are still returned,
    # just without a persisted overlay. Keeps the {:ok, _}/{:error, _} contract
    # (no bang raising out of the success arm).
    with "data:image/png;base64," <> b64 <- diff["diff_png_base64"],
         {:ok, bytes} <- Base.decode64(b64),
         {:ok, url} <-
           Storage.put(
             workspace_id,
             "#{System.unique_integer([:positive])}-diff",
             "png",
             {:bytes, bytes}
           ) do
      Map.put(base, :diff_image_url, url)
    else
      _ -> base
    end
  end

  @doc """
  Start server-side video recording of the agent's preview session.

  Playwright records the headless context the agent drives; subsequent preview
  actions (click/type/navigate) are captured until `record_stop/1`.
  """
  @spec record_start(session_id(), keyword()) :: {:ok, map()} | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"] — dir is built from a server-generated
  # recording_id under a fixed root, never user input.
  def record_start(session_id, opts \\ []) do
    recording_id = recording_id()
    dir = recording_dir(recording_id)
    _ = File.mkdir_p(dir)

    start_opts =
      [recording_id: recording_id, dir: dir]
      |> Keyword.merge(Keyword.take(opts, [:width, :height]))

    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, _result} <- Session.record_start(session_id, start_opts) do
      _ = record_action_and_observation(entry.session, "record_start", %{}, %{}, [])
      {:ok, %{recording_id: recording_id, status: "recording"}}
    end
  end

  @doc """
  Stop recording, store the webm artifact, and show it as playback in the pane.
  """
  @spec record_stop(session_id()) :: {:ok, map()} | {:error, term()}
  def record_stop(session_id) do
    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, result} <- Session.record_stop(session_id) do
      recording_id = Map.get(result, :recording_id)
      artifact_path = persist_recording_artifact(entry.session, recording_id, result[:video_path])

      _ =
        record_action_and_observation(entry.session, "record_stop", %{}, %{},
          artifact_path: artifact_path
        )

      _ = artifact_path && PreviewPanes.show_artifact(entry.session.id, artifact_path)

      {:ok, %{recording_id: recording_id, artifact_path: artifact_path, url: artifact_path}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — video_path is the Playwright-issued
  # recording file under our own record dir, never user input.
  defp persist_recording_artifact(session, recording_id, video_path)
       when is_binary(recording_id) and is_binary(video_path) do
    if File.regular?(video_path) do
      case Storage.put(session.workspace_id, recording_id, "webm", {:file, video_path}) do
        {:ok, ref} ->
          _ = File.rm(video_path)
          _ = File.rmdir(Path.dirname(video_path))
          ref

        {:error, _reason} ->
          nil
      end
    else
      nil
    end
  end

  defp persist_recording_artifact(_session, _recording_id, _video_path), do: nil

  defp recording_id do
    "rec-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp recording_dir(recording_id) do
    base =
      Application.get_env(:casein, :preview_recordings_root) ||
        Path.join([System.tmp_dir!(), "casein_recordings"])

    Path.join(base, recording_id)
  end

  @doc "Close a preview control session and its runtime state."
  @spec close_session(session_id()) :: {:ok, ControlSession.t()} | {:error, term()}
  def close_session(session_id) do
    case Session.close(session_id) do
      {:ok, entry} ->
        entry.session
        |> ControlSession.changeset(%{status: :closed})
        |> Repo.update()

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

  @doc "Latest screenshot observation for a preview control session."
  @spec latest_screenshot(session_id()) :: ControlObservation.t() | nil
  def latest_screenshot(session_id) do
    Repo.one(
      from o in ControlObservation,
        where: o.session_id == ^session_id and o.kind == "screenshot",
        order_by: [desc: o.inserted_at],
        limit: 1
    )
  end

  @doc "Latest console and network errors for a preview control session."
  @spec latest_errors(session_id()) :: %{console_errors: list(), network_errors: list()}
  if Casein.Repo.Adapter.sqlite?() do
    def latest_errors(session_id) do
      by_kind =
        Repo.all(
          from o in ControlObservation,
            where: o.session_id == ^session_id and o.kind in ["console_errors", "network_errors"],
            order_by: [desc: o.inserted_at, desc: o.id],
            select: {o.kind, o.data}
        )
        |> Enum.reduce(%{}, fn {kind, data}, acc -> Map.put_new(acc, kind, data) end)

      %{
        console_errors: extract_errors(by_kind["console_errors"]),
        network_errors: extract_errors(by_kind["network_errors"])
      }
    end
  else
    def latest_errors(session_id) do
      by_kind =
        Repo.all(
          from o in ControlObservation,
            where: o.session_id == ^session_id and o.kind in ["console_errors", "network_errors"],
            distinct: [o.kind],
            order_by: [asc: o.kind, desc: o.inserted_at, desc: o.id],
            select: {o.kind, o.data}
        )
        |> Map.new()

      %{
        console_errors: extract_errors(by_kind["console_errors"]),
        network_errors: extract_errors(by_kind["network_errors"])
      }
    end
  end

  defp extract_errors(%{"errors" => errors}) when is_list(errors), do: errors
  defp extract_errors(%{errors: errors}) when is_list(errors), do: errors
  defp extract_errors(_), do: []

  defp history_action(session_id, runtime_fun, action, opts) when is_integer(session_id) do
    with :ok <- ensure_local_runtime(session_id),
         {:ok, entry, observation} <- apply(Session, runtime_fun, [session_id]),
         {:ok, _} <- sync_session_url(entry, observation) do
      _ = record_action_and_observation(entry.session, action, %{}, observation, opts)
      _ = broadcast_observation(entry, observation)
      {:ok, observation}
    end
  end

  @doc "Latest observation for the most recent open control session of a preview."
  @spec latest_observation_for_preview(integer()) :: ControlObservation.t() | nil
  def latest_observation_for_preview(preview_id) do
    latest_session =
      from s in ControlSession,
        where: s.preview_id == ^preview_id and s.status == :open,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.id

    Repo.one(
      from o in ControlObservation,
        where: o.session_id == subquery(latest_session),
        order_by: [desc: o.inserted_at],
        limit: 1
    )
  end

  @doc "Fetch an open control session scoped to a preview."
  @spec get_open_session_for_preview(term(), term()) :: ControlSession.t() | nil
  def get_open_session_for_preview(session_id, preview_id)
      when is_integer(session_id) and is_integer(preview_id) do
    case Repo.get(ControlSession, session_id) do
      %ControlSession{preview_id: ^preview_id, status: :open} = session -> session
      _ -> nil
    end
  end

  def get_open_session_for_preview(_, _), do: nil

  @doc """
  Open a controllable preview session for a localhost port.

  The port must be allowed for the workspace (metadata, common dev ports, or
  terminal-detected). Optional `:path` (default `/`) sets the initial URL.
  """
  @spec open_localhost_session(map(), integer(), keyword()) ::
          {:ok, ControlSession.t()} | {:error, term()}
  def open_localhost_session(workspace, port, opts \\ [])
      when is_map(workspace) and is_integer(port) do
    workspace = WorkspaceContext.prepare(workspace)
    workspace_id = workspace.id || workspace[:id]
    path = Keyword.get(opts, :path, "/")

    with :ok <- WorkspaceContext.validate_port(workspace, port),
         url <- WorkspaceContext.localhost_url(port, path),
         {:ok, preview} <-
           Previews.find_or_open(workspace, %{
             url: url,
             title: "localhost:#{port}",
             mode: Keyword.get(opts, :mode, :tab),
             actor_id: Keyword.get(opts, :actor_id),
             metadata: %{
               "surface" => "localhost:#{port}",
               "surface_source" => "agent",
               "control_url" => url,
               "display_url" => url
             }
           }),
         {:ok, session} <-
           find_or_persist_session(
             workspace_id,
             preview,
             %{name: "localhost:#{port}"},
             Keyword.put(opts, :control_url, url)
           ) do
      _ = record_observation(session, nil, "url", %{url: session.current_url || preview.url})
      _ = broadcast_preview_opened(preview, session)
      {:ok, session}
    end
  end

  @doc """
  Open a controllable preview session for an allowlisted external origin.

  The tmux-free counterpart of the pane lane: hosts that run preview as a pure
  browser-control session (native Windows) have no pane to bind, so they cannot
  reach an external origin through `PreviewPanes.register/1`. The origin must
  already have passed `Casein.Previews.ExternalOrigins.validate/2`; this
  function is the session half, not the policy half.

  The session's allowed origins carry the target origin explicitly. Without it
  the control guard would fall back to loopback-only origins and refuse every
  navigation on the very origin the caller was allowed to open.
  """
  @spec open_external_session(map(), String.t(), keyword()) ::
          {:ok, ControlSession.t()} | {:error, term()}
  def open_external_session(workspace, url, opts \\ [])
      when is_map(workspace) and is_binary(url) do
    workspace = WorkspaceContext.prepare(workspace)
    workspace_id = workspace.id || workspace[:id]

    with origin when is_binary(origin) <- Url.origin_of(url),
         surface_name <- "external:#{URI.parse(url).host}",
         {:ok, preview} <-
           Previews.find_or_open(workspace, %{
             url: url,
             title: surface_name,
             mode: Keyword.get(opts, :mode, :tab),
             actor_id: Keyword.get(opts, :actor_id),
             metadata: %{
               "surface" => surface_name,
               "surface_source" => "agent",
               "control_url" => url,
               "display_url" => url,
               "allowed_origins" => Enum.uniq(Url.allowed_origins(workspace) ++ [origin])
             }
           }),
         {:ok, session} <-
           find_or_persist_session(
             workspace_id,
             preview,
             %{name: surface_name},
             Keyword.put(opts, :control_url, url)
           ) do
      _ = record_observation(session, nil, "url", %{url: session.current_url || preview.url})
      _ = broadcast_preview_opened(preview, session)
      {:ok, session}
    else
      nil -> {:error, :invalid_external_preview_url}
      {:error, _reason} = error -> error
    end
  end

  @doc "Open control session for a workspace preview record."
  @spec open_for_preview(map(), Previews.Preview.t(), keyword()) ::
          {:ok, ControlSession.t()} | {:error, term()}
  def open_for_preview(workspace, preview, opts \\ []) do
    surface = preview.metadata["surface"] || "preview"
    workspace_id = workspace.id || workspace[:id]

    find_or_persist_session(workspace_id, preview, %{name: surface}, opts)
  end

  @doc "Close every open control session attached to a preview."
  @spec close_sessions_for_preview(integer()) :: {:ok, non_neg_integer()}
  def close_sessions_for_preview(preview_id) do
    ids =
      Repo.all(
        from s in ControlSession,
          where: s.preview_id == ^preview_id and s.status == :open,
          select: s.id
      )

    # Tear down any live runtimes (in-memory side effect only); the DB status
    # flip below is batched and also covers rows whose runtime is already gone.
    Enum.each(ids, &Session.close/1)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(s in ControlSession,
        where: s.preview_id == ^preview_id and s.status == :open
      )
      |> Repo.update_all(set: [status: :closed, updated_at: now])

    {:ok, count}
  end

  defp start_runtime(session, preview) do
    case Runtime.start(session.id, session, preview) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        _ = mark_session_error(session)
        {:error, reason}
    end
  end

  defp find_or_persist_session(workspace_id, preview, surface, opts) do
    opts =
      opts
      |> normalize_storage_profile_opts()
      |> Runtime.with_default_headers()

    with :ok <- validate_storage_profile_opts(opts) do
      case reusable_session(preview, opts) do
        %ControlSession{} = session -> ensure_reusable_session(session, preview, opts)
        nil -> persist_and_start_session(workspace_id, preview, surface, opts)
      end
    end
  end

  defp normalize_storage_profile_opts(opts) do
    profile =
      opts
      |> Keyword.get(:storage_profile, :ephemeral)
      |> normalize_storage_profile()

    name =
      opts
      |> Keyword.get(:storage_profile_name)
      |> normalize_storage_profile_name()

    opts
    |> Keyword.put(:storage_profile, profile)
    |> Keyword.put(:storage_profile_name, name)
  end

  defp validate_storage_profile_opts(opts) do
    case {Keyword.get(opts, :storage_profile), Keyword.get(opts, :storage_profile_name)} do
      {:profile, nil} -> {:error, :missing_storage_profile_name}
      _ -> :ok
    end
  end

  defp persist_and_start_session(workspace_id, preview, surface, opts) do
    with {:ok, session} <- persist_session(workspace_id, preview, surface, opts),
         {:ok, _entry} <- start_runtime(session, preview) do
      {:ok, session}
    end
  end

  defp ensure_runtime(session, preview) do
    Runtime.ensure_registered(session.id, session, preview)
  end

  # Re-hydrate the live runtime on the instance handling the current request.
  #
  # `PreviewCtl.Registry` is in-memory and instance-local. This box runs several
  # instances behind the :4000 loopback (canary/draining), so a session opened on
  # instance A is not registered on instance B (or on A after a restart). Without
  # this, every runtime-resolving op returns `{:error, :not_found}` cross-instance.
  #
  # `Runtime.ensure_registered/3` is idempotent (guards on `Registry.get`), so a
  # benign concurrent double-start collapses to a single entry. Re-hydration
  # starts a fresh adapter at the session's persisted `current_url`; storage
  # profiles carry auth/state across instances.
  defp ensure_local_runtime(session_id) do
    case Session.fetch(session_id) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        with %ControlSession{status: :open} = session <- Repo.get(ControlSession, session_id),
             %Previews.Preview{} = preview <- Repo.get(Previews.Preview, session.preview_id),
             {:ok, _session} <- ensure_runtime(session, preview) do
          :ok
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp ensure_reusable_session(session, preview, opts) do
    with {:ok, session} <- ensure_runtime(session, preview) do
      maybe_navigate_reused_session(session, opts)
    end
  end

  defp maybe_navigate_reused_session(session, opts) do
    requested_url = Keyword.get(opts, :control_url)

    if is_binary(requested_url) and requested_url != session.current_url do
      case navigate(session.id, requested_url) do
        {:ok, _observation} -> {:ok, %{session | current_url: requested_url}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, session}
    end
  end

  defp reusable_session(preview, opts) do
    if Keyword.get(opts, :new_control_session, false) do
      nil
    else
      do_reusable_session(preview, opts)
    end
  end

  defp do_reusable_session(preview, opts) do
    preview.id
    |> open_sessions_for_preview()
    |> Enum.find(&Runtime.matches_reuse_opts?(&1, opts))
  end

  defp open_sessions_for_preview(preview_id) do
    Repo.all(
      from s in ControlSession,
        where: s.preview_id == ^preview_id and s.status == :open,
        order_by: [desc: s.inserted_at]
    )
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

    storage = storage_profile_metadata(workspace_id, preview, opts)

    attrs = %{
      workspace_id: workspace_id,
      preview_id: preview.id,
      surface: surface.name,
      adapter: adapter_name,
      current_url: Keyword.get(opts, :control_url, control_url(preview)),
      actor_id: Keyword.get(opts, :actor_id),
      assignment_id: Keyword.get(opts, :assignment_id),
      metadata: %{
        "allowed_origins" => preview.metadata["allowed_origins"] || Url.allowed_origins(nil),
        "surface_key" => preview.metadata["surface_key"] || surface_key(surface),
        "control_url" => Keyword.get(opts, :control_url, control_url(preview)),
        "display_url" => preview.metadata["display_url"] || preview.url,
        "default_headers" => Keyword.get(opts, :default_headers, %{}),
        "isolation_key" => Keyword.get(opts, :isolation_key),
        "storage_profile" => storage.profile,
        "storage_profile_name" => storage.name,
        "storage_profile_key" => storage.key,
        "storage_state_path" => storage.path
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
            surface_key: session.metadata["surface_key"],
            url: preview.url,
            adapter: adapter_name,
            storage_profile: storage.profile,
            storage_profile_name: storage.name
          }
        })

      _ ->
        :ok
    end)
  end

  defp control_url(%{metadata: %{"control_url" => url}}) when is_binary(url), do: url
  defp control_url(%{metadata: %{control_url: url}}) when is_binary(url), do: url
  defp control_url(%{url: url}), do: url

  defp surface_key(%{surface_key: key}) when is_binary(key) and key != "", do: key
  defp surface_key(%{name: name}) when is_binary(name) and name != "", do: name
  defp surface_key(%{url: url}) when is_binary(url), do: Casein.Previews.Identity.url_key(url)
  defp surface_key(_surface), do: nil

  defp storage_profile_metadata(workspace_id, preview, opts) do
    profile =
      opts
      |> Keyword.get(:storage_profile, :ephemeral)
      |> normalize_storage_profile()

    name = opts |> Keyword.get(:storage_profile_name) |> normalize_storage_profile_name()

    case {profile, name} do
      {:ephemeral, _} ->
        %{profile: "ephemeral", name: nil, key: nil, path: nil}

      {:workspace, _} ->
        key = "workspace"

        %{
          profile: "workspace",
          name: nil,
          key: key,
          path: storage_state_path(workspace_id, preview, key)
        }

      {:profile, name} ->
        key = "profile-" <> name

        %{
          profile: "profile",
          name: name,
          key: key,
          path: storage_state_path(workspace_id, preview, key)
        }
    end
  end

  defp normalize_storage_profile(value) when value in [:workspace, "workspace"], do: :workspace
  defp normalize_storage_profile(value) when value in [:profile, "profile"], do: :profile
  defp normalize_storage_profile(_), do: :ephemeral

  defp normalize_storage_profile_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      name -> String.slice(name, 0, 80)
    end
  end

  defp normalize_storage_profile_name(_), do: nil

  defp storage_state_path(workspace_id, preview, key) do
    origin =
      preview
      |> control_url()
      |> Url.origin_of()
      |> case do
        nil -> "unknown"
        origin -> origin
      end

    workspace = safe_storage_segment(workspace_id || "workspace")
    origin_hash = :crypto.hash(:sha256, origin) |> Base.encode16(case: :lower)
    filename = safe_storage_segment(key) <> ".json"

    Path.join([preview_private_storage_root(), workspace, origin_hash, filename])
  end

  defp safe_storage_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "default"
      segment -> String.slice(segment, 0, 120)
    end
  end

  defp preview_private_storage_root do
    root =
      Application.get_env(:casein, :preview_storage_root) ||
        Application.get_env(:casein, :preview_artifacts_root) ||
        Path.join([File.cwd!(), "priv", "preview_artifacts"])

    Path.join(root, ".storage")
  end

  defp sync_session_url(entry, observation, url \\ nil) do
    url =
      observation_value(observation, :url) || url ||
        current_url(entry.adapter_state, entry)

    # Most actions (type/press/click) don't change the URL — skip the write when
    # it would be a no-op. Every browser action calls through here.
    if url && url != entry.session.current_url do
      entry.session
      |> ControlSession.changeset(%{current_url: url})
      |> Repo.update()
    else
      {:ok, entry.session}
    end
  end

  defp fetch_surface(workspace, surface_name) do
    case SurfaceResolver.get(workspace, surface_name) do
      nil -> fallback_surface(workspace, to_string(surface_name))
      surface -> {:ok, surface}
    end
  end

  # The default "app" surface falls back to the best discoverable surface
  # (terminal-detected localhost ports included), so
  # preview_open_current_workspace works on workspaces without manager
  # surface metadata. Explicitly named surfaces still fail loudly.
  defp fallback_surface(workspace, "app") do
    case SurfaceResolver.primary_surface(workspace) do
      nil -> {:error, :surface_not_found}
      surface -> {:ok, surface}
    end
  end

  defp fallback_surface(_workspace, _surface_name), do: {:error, :surface_not_found}

  defp record_action_and_observation(session, action, params, observation, opts \\ []) do
    result =
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
            {"url", %{url: observation_value(observation, :url)}},
            {"dom_summary", observation_value(observation, :dom_summary) || %{}},
            {"console_errors", %{errors: observation_value(observation, :console_errors) || []}},
            {"network_errors", %{errors: observation_value(observation, :network_errors) || []}}
          ] ++ storage_observation(observation) ++ screenshot_observation(observation, opts)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        observations =
          for {kind, data} <- kinds, data != %{} do
            %{
              session_id: session.id,
              action_id: action_row.id,
              kind: kind,
              data: data,
              artifact_path: opts[:artifact_path],
              inserted_at: now
            }
          end

        if observations != [], do: Repo.insert_all(ControlObservation, observations)

        action_row
      end)

    if match?({:ok, _action_row}, result) do
      record_control_activity(session, action, params, observation, opts)
    end

    result
  end

  defp record_control_activity(session, action, params, observation, opts) do
    registration =
      if opts[:pane_id] do
        %{
          pane_id: opts[:pane_id],
          preview_id: opts[:preview_id] || session.preview_id,
          workspace_id: opts[:workspace_id] || session.workspace_id
        }
      else
        PreviewPanes.get_by_session(session.id)
      end

    _ =
      PreviewActivity.record(%{
        workspace_id: (registration && registration.workspace_id) || session.workspace_id,
        pane_id: registration && registration.pane_id,
        session_id: session.id,
        preview_id: (registration && registration.preview_id) || session.preview_id,
        source: :preview_control,
        event: action,
        summary: control_activity_summary(action, params),
        metadata:
          %{
            selector: Map.get(params, :selector) || Map.get(params, "selector"),
            key: Map.get(params, :key) || Map.get(params, "key"),
            path: Map.get(params, :url) || Map.get(params, "url"),
            x: Map.get(params, :x) || Map.get(params, "x"),
            y: Map.get(params, :y) || Map.get(params, "y"),
            text_length: safe_text_length(params),
            url: observation_value(observation, :url),
            artifact_path: opts[:artifact_path] || observation_value(observation, :artifact_path)
          }
          |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
          |> Map.new()
      })

    :ok
  end

  defp control_activity_summary("click", params) do
    cond do
      selector = Map.get(params, :selector) || Map.get(params, "selector") ->
        "clicked #{selector}"

      is_integer(Map.get(params, :x) || Map.get(params, "x")) and
          is_integer(Map.get(params, :y) || Map.get(params, "y")) ->
        "clicked @ #{Map.get(params, :x) || Map.get(params, "x")},#{Map.get(params, :y) || Map.get(params, "y")}"

      true ->
        "clicked"
    end
  end

  defp control_activity_summary("type", params) do
    selector = Map.get(params, :selector) || Map.get(params, "selector") || "input"
    "typed into #{selector}"
  end

  defp control_activity_summary("press", params) do
    key = Map.get(params, :key) || Map.get(params, "key") || "key"
    "pressed #{key}"
  end

  defp control_activity_summary("navigate", params) do
    url = Map.get(params, :url) || Map.get(params, "url") || "URL"
    "navigated to #{url}"
  end

  defp control_activity_summary("go_back", _), do: "went back"
  defp control_activity_summary("go_forward", _), do: "went forward"
  defp control_activity_summary("reload", _), do: "reloaded"
  defp control_activity_summary("screenshot", _), do: "screenshot updated"
  defp control_activity_summary("observe", _), do: "observed page"
  defp control_activity_summary("observe_live", _), do: "observed live page"
  defp control_activity_summary(action, _), do: action

  defp safe_text_length(params) do
    case Map.get(params, :text) || Map.get(params, "text") do
      text when is_binary(text) -> String.length(text)
      _ -> nil
    end
  end

  defp screenshot_observation(observation, opts) do
    shot = observation_value(observation, :screenshot)

    cond do
      screenshot_artifact?(shot) -> [{"screenshot", shot}]
      is_binary(shot) -> [{"screenshot", %{artifact_path: shot}}]
      is_binary(opts[:artifact_path]) -> [{"screenshot", %{artifact_path: opts[:artifact_path]}}]
      true -> []
    end
  end

  defp screenshot_artifact?(%{artifact: _}), do: true
  defp screenshot_artifact?(%{"artifact" => _}), do: true
  defp screenshot_artifact?(_), do: false

  defp storage_observation(observation) do
    local_storage = observation_value(observation, :local_storage)
    session_storage = observation_value(observation, :session_storage)

    if is_map(local_storage) or is_map(session_storage) do
      [
        {"storage",
         %{
           local_storage: local_storage || %{},
           session_storage: session_storage || %{}
         }}
      ]
    else
      []
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

  defp persist_diff_observation(session, observation) when is_map(observation) do
    case map_get(observation, :diff) do
      %{} = diff ->
        Map.put(observation, :diff, persist_diff_artifact(session, diff))

      _ ->
        observation
    end
  end

  defp persist_diff_observation(_session, observation), do: observation

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> nil
        end
    end
  end

  defp persist_diff_artifact(session, %{diff_png_base64: "data:image/png;base64," <> b64} = diff) do
    case Base.decode64(b64) do
      {:ok, bytes} ->
        id = System.unique_integer([:positive])

        diff
        |> Map.delete(:diff_png_base64)
        |> Map.put(
          :diff_image_url,
          Artifacts.store_named_png!(session.workspace_id, "#{id}-diff", bytes)
        )

      # Malformed helper output: drop the image rather than crash the action.
      :error ->
        Map.delete(diff, :diff_png_base64)
    end
  end

  defp persist_diff_artifact(_session, diff) when is_map(diff), do: diff

  defp configured_adapter do
    Application.get_env(:casein, :preview_control_adapter, :memory)
  end

  defp broadcast_preview_opened(preview, session) do
    payload = %{
      workspace_id: preview.workspace_id,
      preview_id: preview.id,
      session_id: session.id,
      preview_url: preview.url,
      current_url: session.current_url || preview.url
    }

    for workspace_id <-
          Deps.impl(:workspaces).viewer_ids(preview.workspace_id, resolve_remote?: true) do
      Phoenix.PubSub.broadcast(
        Casein.PubSub,
        "preview:" <> workspace_id,
        {:preview_opened, payload}
      )
    end

    :ok
  end

  # Pushes a real page observation to LiveView subscribers so an open Agent
  # preview panel follows agent-driven (MCP) browsing live — not only when the
  # human uses the panel's own controls. Keyed by workspace; the LiveView
  # filters by preview_id. Minimal type/press echoes (no url/dom_summary/
  # artifact_path) are skipped so they don't blank the panel.
  defp broadcast_observation(entry, observation) do
    if real_observation?(observation) do
      payload = %{
        preview_id: entry.preview.id,
        session_id: entry.session.id,
        observation: observation
      }

      for workspace_id <-
            Deps.impl(:workspaces).viewer_ids(entry.preview.workspace_id, resolve_remote?: true) do
        Phoenix.PubSub.broadcast(
          Casein.PubSub,
          "preview:" <> workspace_id,
          {:preview_observation, payload}
        )
      end
    end

    :ok
  end

  defp real_observation?(obs) when is_map(obs) do
    Map.has_key?(obs, :url) or Map.has_key?(obs, "url") or
      Map.has_key?(obs, :dom_summary) or Map.has_key?(obs, "dom_summary") or
      Map.has_key?(obs, :artifact_path) or Map.has_key?(obs, "artifact_path")
  end

  defp real_observation?(_), do: false

  defp current_url(adapter_state, entry) do
    Map.get(adapter_state, :current_url) || entry.session.current_url || entry.preview.url
  end

  defp observation_value(%{} = observation, key) when is_atom(key) do
    Map.get(observation, key) || Map.get(observation, Atom.to_string(key))
  end

  defp observation_value(_, _), do: nil
end
