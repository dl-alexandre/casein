defmodule DevIDE.Test.RuntimeSeed do
  @moduledoc """
  Test-only seam for inserting `DevIDE.Runtimes.Runtime` records directly through
  the configured runtimes adapter.

  The production runtime *setters* (`request_runtime/provision_runtime/...`) were
  removed because nothing in `lib/` drove them — only tests used them to stand up
  fixture records. This helper replaces that seeding path: it persists a runtime
  (and its initial append-only lifecycle event) via the same adapter
  (`create_runtime/2`) that the kept readers (`list_runtimes/1`, `get_runtime/1`,
  `events_for/1`, preview surfaces, `decorate_assignment_metadata/1`,
  `project_lifecycle/1`) read from, so seeded records are
  indistinguishable from records the old API produced.

  Pass `status:` to seed any lifecycle status directly (no transition API
  required); everything else mirrors the field mapping the old `request_runtime`
  used so existing fixtures port over unchanged.
  """

  alias DevIDE.Runtimes.{LifecycleEvent, Profile, Runtime}

  @doc """
  Inserts a runtime record for `workspace_id` and returns `{:ok, runtime}`.

  `attrs` keys (all optional unless noted):

    * `:id` / `:runtime_id` — runtime id (defaults to a generated `rt-` id)
    * `:host_id` — defaults to `"local"`
    * `:status` — lifecycle status string (defaults to `"requested"`)
    * `:os`, `:repo`, `:branch`, `:worktree_path`, `:runner_id`,
      `:session_id`, `:tmux_session_id`
    * `:isolation_mode` — defaults to `"worktree"`
    * `:capabilities`, `:tools` — lists, default `[]`
    * `:concurrency_limit` — defaults to `1`
    * `:active_assignments` — defaults to `0`
    * `:created_at`, `:heartbeat_at` — defaults to now
    * `:metadata` — map merged into the runtime metadata (e.g. a
      `"runtime_profile"`)
    * `:event` — lifecycle event name (defaults to `"runtime_requested"`)
  """
  @spec seed_runtime(String.t(), map() | keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  def seed_runtime(workspace_id, attrs \\ %{}) when is_binary(workspace_id) do
    attrs = Map.new(attrs)
    now = Map.get(attrs, :created_at) || DateTime.utc_now()
    id = Map.get(attrs, :id) || Map.get(attrs, :runtime_id) || generate_id()
    status = Map.get(attrs, :status, "requested")
    metadata = build_metadata(attrs)

    runtime = %Runtime{
      id: id,
      workspace_id: workspace_id,
      host_id: Map.get(attrs, :host_id, "local"),
      os: Map.get(attrs, :os),
      repo: Map.get(attrs, :repo),
      branch: Map.get(attrs, :branch),
      worktree_path: Map.get(attrs, :worktree_path),
      runner_id: Map.get(attrs, :runner_id),
      session_id: Map.get(attrs, :session_id),
      tmux_session_id: Map.get(attrs, :tmux_session_id),
      isolation_mode: Map.get(attrs, :isolation_mode, "worktree"),
      status: status,
      capabilities: Map.get(attrs, :capabilities, []),
      tools: Map.get(attrs, :tools, []),
      concurrency_limit: Map.get(attrs, :concurrency_limit, 1),
      active_assignments: Map.get(attrs, :active_assignments, 0),
      created_at: now,
      heartbeat_at: Map.get(attrs, :heartbeat_at) || now,
      metadata: metadata
    }

    event = %LifecycleEvent{
      id: Ecto.UUID.generate(),
      runtime_id: id,
      workspace_id: workspace_id,
      event: Map.get(attrs, :event, "runtime_requested"),
      from_status: nil,
      to_status: status,
      inserted_at: now,
      metadata: %{}
    }

    impl().create_runtime(runtime, event)
  end

  @doc "Like `seed_runtime/2` but raises on error and returns the runtime."
  @spec seed_runtime!(String.t(), map() | keyword()) :: Runtime.t()
  def seed_runtime!(workspace_id, attrs \\ %{}) do
    {:ok, runtime} = seed_runtime(workspace_id, attrs)
    runtime
  end

  # Mirrors the old request_runtime metadata handling: a `:runtime_profile`
  # (passed directly or inside `:metadata`) is normalized through Profile and
  # stored under `"runtime_profile"`, so the kept preview-surface/payload readers
  # see the same shape they did when the setters seeded records.
  defp build_metadata(attrs) do
    base =
      case Map.get(attrs, :metadata, %{}) do
        metadata when is_map(metadata) -> metadata
        _ -> %{}
      end

    profile_attrs =
      if Map.has_key?(attrs, :runtime_profile) do
        Map.put(base, "runtime_profile", Map.get(attrs, :runtime_profile))
      else
        base
      end

    case Profile.from_attrs(%{"metadata" => profile_attrs}) do
      {:ok, nil} -> profile_attrs
      {:ok, profile} -> Map.put(profile_attrs, "runtime_profile", profile)
      {:error, _} -> profile_attrs
    end
  end

  defp generate_id, do: "rt-" <> Ecto.UUID.generate()

  defp impl,
    do: Application.get_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.MemoryAdapter)
end
