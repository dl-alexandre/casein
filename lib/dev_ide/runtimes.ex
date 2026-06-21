defmodule DevIDE.Runtimes do
  @moduledoc """
  Agent-worktree discovery + runtime status export for the workspace.

  This is a **record-only**, single-runtime service — it stores where agent
  work *has* run, not where it *should* run. There is no host registry, no
  multi-host placement, and no orchestration: a workspace runs on the box
  serving this cockpit. It never accepts argv, shells, HTTP proxy targets, or
  mutation commands.

  Live surface today:

    * **Agent worktree discovery** — `observe_worktree/2` registers git
      worktrees agents create (via the `terminal_report_worktree` MCP tool).
    * **Status export** — `list_runtimes/1` / `get_runtime/1` snapshot runtimes
      for the read API and `Export.WorkspaceStatus`.
  """

  alias DevIDE.Git.Inspector, as: GitInspector
  alias DevIDE.Runtimes.{LifecycleEvent, Profile, Runtime, StateMachine}
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.WorkspaceRecord

  @callback create_runtime(Runtime.t(), LifecycleEvent.t()) ::
              {:ok, Runtime.t()} | {:error, term()}
  @callback update_runtime(Runtime.t(), LifecycleEvent.t() | nil) ::
              {:ok, Runtime.t()} | {:error, term()}
  @callback get_runtime(String.t()) :: {:ok, Runtime.t()} | :error
  @callback list_runtimes(map()) :: [Runtime.t()]
  @callback events_for(String.t()) :: [LifecycleEvent.t()]
  @callback clear() :: :ok

  def list_runtimes(filters \\ %{}), do: impl().list_runtimes(normalize_filter(filters))

  def get_runtime(runtime_id) when is_binary(runtime_id), do: impl().get_runtime(runtime_id)
  def get_runtime(_), do: :error

  @doc """
  Observe an agent-created Git worktree as a child runtime of `workspace_id`.

  This is record-only: it never creates a manager workspace, starts Docker, or
  spawns a shell. The worktree is accepted when it lives under the workspace
  root, or when it lives under an allowed agent-worktree root and its Git common
  dir proves it belongs to a repo inside the parent workspace.
  """
  @spec observe_worktree(String.t(), map()) :: {:ok, Runtime.t()} | {:error, term()}
  def observe_worktree(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    with {:ok, %WorkspaceRecord{} = record} <- State.get(workspace_id),
         {:ok, worktree_path} <- observed_worktree_path(record, attrs),
         {:ok, %GitInspector{} = git_info} <- inspect_worktree(worktree_path),
         :ok <- validate_agent_worktree(record, worktree_path, git_info) do
      upsert_agent_worktree_runtime(record, attrs, worktree_path, git_info)
    end
  end

  def observe_worktree(_workspace_id, _attrs), do: {:error, :invalid_attrs}

  def events_for(runtime_id) when is_binary(runtime_id), do: impl().events_for(runtime_id)
  def events_for(_), do: []

  def clear, do: impl().clear()

  @doc "Add current runtime projection to assignment metadata for read surfaces."
  def decorate_assignment_metadata(metadata) when is_map(metadata) do
    case runtime_id_from_metadata(metadata) do
      nil ->
        metadata

      runtime_id ->
        case get_runtime(runtime_id) do
          {:ok, %Runtime{} = runtime} -> put_runtime_metadata(metadata, runtime)
          :error -> metadata
        end
    end
  end

  def decorate_assignment_metadata(metadata), do: metadata

  def runtime_id_from_metadata(metadata) when is_map(metadata) do
    runtime = Map.get(metadata, "runtime") || Map.get(metadata, :runtime) || %{}

    string_value(runtime, "id") ||
      string_value(runtime, "runtime_id") ||
      string_value(metadata, "runtime_id") ||
      string_value(metadata, "runtime")
  end

  def runtime_id_from_metadata(_), do: nil

  def payload(%Runtime{} = runtime) do
    %{
      id: runtime.id,
      workspace_id: runtime.workspace_id,
      host: runtime.host_id,
      os: runtime.os,
      repo: runtime.repo,
      branch: runtime.branch,
      worktree_path: runtime.worktree_path,
      runner_id: runtime.runner_id,
      session_id: runtime.session_id,
      tmux_session_id: runtime.tmux_session_id,
      isolation_mode: runtime.isolation_mode,
      status: runtime.status,
      capabilities: runtime.capabilities,
      tools: runtime.tools,
      concurrency_limit: runtime.concurrency_limit,
      active_assignments: runtime.active_assignments,
      created_at: iso(runtime.created_at),
      heartbeat_at: iso(runtime.heartbeat_at),
      expired_at: iso(runtime.expired_at),
      cleaned_at: iso(runtime.cleaned_at),
      failure_reason: runtime.failure_reason,
      runtime_profile: Profile.for_runtime(runtime),
      preview_surfaces: runtime_preview_surfaces(runtime),
      metadata: runtime.metadata || %{}
    }
  end

  @doc "Return the normalized runtime profile stored on a runtime, if any."
  @spec runtime_profile(Runtime.t()) :: map() | nil
  def runtime_profile(%Runtime{} = runtime), do: Profile.for_runtime(runtime)

  @doc "Return preview surface descriptors derived from a runtime profile."
  @spec runtime_preview_surfaces(Runtime.t()) :: [map()]
  def runtime_preview_surfaces(%Runtime{} = runtime), do: Profile.preview_surfaces(runtime)

  def event_payload(%LifecycleEvent{} = event) do
    %{
      id: event.id,
      runtime_id: event.runtime_id,
      workspace_id: event.workspace_id,
      event: event.event,
      from_status: event.from_status,
      to_status: event.to_status,
      actor_id: event.actor_id,
      assignment_id: event.assignment_id,
      runner_id: event.runner_id,
      metadata: event.metadata || %{},
      inserted_at: iso(event.inserted_at)
    }
  end

  def project_lifecycle(events), do: StateMachine.reduce(events)

  defp observed_worktree_path(%WorkspaceRecord{host_path: nil}, _attrs),
    do: {:error, :workspace_root_unavailable}

  defp observed_worktree_path(%WorkspaceRecord{host_path: root}, attrs) do
    case string_value(attrs, "worktree_path") || string_value(attrs, "runtime_path") ||
           string_value(attrs, "path") do
      nil ->
        {:error, :worktree_path_required}

      requested ->
        path = expand_observed_path(root, requested)

        if File.dir?(path), do: {:ok, path}, else: {:error, :worktree_not_found}
    end
  end

  defp expand_observed_path(root, path) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _ -> Path.expand(path, root)
    end
  end

  defp inspect_worktree(path) do
    case GitInspector.inspect_cwd(path) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, :not_git_worktree}
    end
  end

  defp validate_agent_worktree(
         %WorkspaceRecord{host_path: root} = record,
         path,
         %GitInspector{} = info
       ) do
    with :ok <- reject_main_checkout(root, path, info) do
      cond do
        under_root?(path, root) ->
          :ok

        under_agent_worktree_root?(path) and related_to_workspace_git?(record, info) ->
          :ok

        under_agent_worktree_root?(path) ->
          {:error, :unrelated_worktree}

        true ->
          {:error, :worktree_outside_allowed_roots}
      end
    end
  end

  defp reject_main_checkout(root, path, %GitInspector{} = info) do
    if same_path?(Path.expand(root), Path.expand(path)) and info.worktree? == false do
      {:error,
       %{
         error: :main_checkout_not_allowed,
         message: "Report a dedicated git worktree path, not the workspace main checkout.",
         worktree_path: path
       }}
    else
      :ok
    end
  end

  defp related_to_workspace_git?(%WorkspaceRecord{host_path: root}, %GitInspector{} = info) do
    git_common_dir = clean_optional_path(info.git_common_dir)
    root = Path.expand(root)

    cond do
      is_binary(git_common_dir) and under_root?(git_common_dir, root) ->
        true

      true ->
        case GitInspector.inspect_cwd(root) do
          {:ok, parent} -> same_path?(parent.git_common_dir, git_common_dir)
          :error -> false
        end
    end
  end

  defp upsert_agent_worktree_runtime(
         %WorkspaceRecord{} = record,
         attrs,
         worktree_path,
         %GitInspector{} = git_info
       ) do
    existing = existing_agent_worktree_runtime(record.external_id, worktree_path, attrs)

    runtime_id =
      string_value(attrs, "runtime_id") || (existing && existing.id) || worktree_runtime_id()

    now = datetime_value(attrs, "heartbeat_at") || DateTime.utc_now()

    metadata =
      ((existing && existing.metadata) || %{})
      |> Map.merge(map_value(attrs, "metadata"))
      |> Map.merge(agent_worktree_metadata(attrs, worktree_path, git_info, now))

    runtime = %Runtime{
      id: runtime_id,
      workspace_id: record.external_id,
      host_id:
        string_value(attrs, "host_id") || string_value(attrs, "host") ||
          ((existing && existing.host_id) || "local"),
      os: string_value(attrs, "os") || (existing && existing.os),
      repo:
        string_value(attrs, "repo") || (existing && existing.repo) ||
          Path.basename(git_info.toplevel),
      branch: string_value(attrs, "branch") || git_info.branch || (existing && existing.branch),
      worktree_path: worktree_path,
      runner_id: string_value(attrs, "runner_id") || (existing && existing.runner_id),
      session_id: string_value(attrs, "session_id") || (existing && existing.session_id),
      tmux_session_id:
        string_value(attrs, "tmux_session_id") || (existing && existing.tmux_session_id) ||
          Tmux.session_name(record.name || record.external_id, runtime_id),
      isolation_mode: "worktree",
      status:
        string_value(attrs, "runtime_status") || (existing && existing.status) || "provisioned",
      capabilities:
        Enum.uniq(
          ((existing && existing.capabilities) || []) ++ string_list(attrs, "capabilities")
        ),
      tools: Enum.uniq(((existing && existing.tools) || []) ++ string_list(attrs, "tools")),
      concurrency_limit:
        positive_integer(
          attrs,
          "concurrency_limit",
          (existing && existing.concurrency_limit) || 1
        ),
      active_assignments: (existing && existing.active_assignments) || 0,
      created_at: (existing && existing.created_at) || now,
      heartbeat_at: now,
      metadata: metadata
    }

    event_metadata = Map.take(metadata, ["agent", "branch", "git_common_dir", "worktree_path"])

    if existing do
      impl().update_runtime(
        runtime,
        event(runtime, existing.status, "runtime_heartbeat",
          actor_id: string_value(attrs, "actor_id"),
          runner_id: string_value(attrs, "runner_id"),
          metadata: event_metadata
        )
      )
    else
      requested = %{runtime | status: "requested"}

      with {:ok, _requested} <-
             impl().create_runtime(
               requested,
               event(requested, nil, "runtime_requested",
                 actor_id: string_value(attrs, "actor_id"),
                 runner_id: string_value(attrs, "runner_id"),
                 metadata: event_metadata
               )
             ) do
        impl().update_runtime(
          runtime,
          event(runtime, "requested", "runtime_provisioned",
            actor_id: string_value(attrs, "actor_id"),
            runner_id: string_value(attrs, "runner_id"),
            metadata: event_metadata
          )
        )
      end
    end
  end

  defp existing_agent_worktree_runtime(workspace_id, worktree_path, attrs) do
    runtime_id = string_value(attrs, "runtime_id")

    runtime_by_id =
      case runtime_id && get_runtime(runtime_id) do
        {:ok, %Runtime{} = runtime} -> runtime
        _ -> nil
      end

    cond do
      runtime_by_id && runtime_by_id.workspace_id == workspace_id &&
          agent_worktree_runtime?(runtime_by_id) ->
        runtime_by_id

      true ->
        list_runtimes(%{"workspace_id" => workspace_id})
        |> Enum.find(fn runtime ->
          agent_worktree_runtime?(runtime) and runtime.status not in ["cleaned", "expired"] and
            same_path?(runtime.worktree_path, worktree_path)
        end)
    end
  end

  defp agent_worktree_metadata(attrs, worktree_path, %GitInspector{} = git_info, observed_at) do
    dirty_count = dirty_count(worktree_path)
    branch = string_value(attrs, "branch") || git_info.branch

    %{
      "kind" => "agent_worktree",
      "provisioning_model" => "agent_worktree",
      "source" => string_value(attrs, "source") || "agent_report",
      "agent" => string_value(attrs, "agent") || git_info.agent,
      "branch" => branch,
      "worktree_path" => worktree_path,
      "git_toplevel" => git_info.toplevel,
      "git_common_dir" => git_info.git_common_dir,
      "git_head_sha" => git_info.head_sha,
      "git_worktree" => git_info.worktree?,
      "git_detached" => git_info.detached?,
      "dirty_count" => dirty_count,
      "worktree_status" => if(dirty_count == 0, do: "clean", else: "dirty"),
      "observed_at" => DateTime.to_iso8601(observed_at)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp agent_worktree_runtime?(%Runtime{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "kind") == "agent_worktree" or
      Map.get(metadata, "provisioning_model") == "agent_worktree"
  end

  defp agent_worktree_runtime?(_runtime), do: false

  defp dirty_count(path) do
    case DevIDE.Git.status_short(path) do
      {:ok, entries} -> length(entries)
      _ -> nil
    end
  end

  defp worktree_runtime_id, do: "wt-" <> Ecto.UUID.generate()

  defp under_agent_worktree_root?(path) do
    roots =
      Application.get_env(:dev_ide, :agent_worktree_roots, []) ++
        env_agent_worktree_roots() ++ default_agent_worktree_roots()

    path = Path.expand(path)
    Enum.any?(roots, &under_root?(path, &1))
  end

  defp default_agent_worktree_roots do
    [
      Path.join(System.tmp_dir!(), "devide-agent-worktrees"),
      Path.expand("~/.local/share/opencode"),
      Path.expand("~/.local/share/codex"),
      Path.expand("~/.cache/codex"),
      Path.expand("~/.claude")
    ]
  end

  defp env_agent_worktree_roots do
    case System.get_env("DEV_IDE_AGENT_WORKTREE_ROOTS") do
      nil -> []
      value -> String.split(value, [",", ":"], trim: true)
    end
  end

  defp under_root?(path, root) when is_binary(path) and is_binary(root) do
    path = Path.expand(path)
    root = Path.expand(root)
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end

  defp under_root?(_, _), do: false

  defp same_path?(left, right) when is_binary(left) and is_binary(right),
    do: Path.expand(left) == Path.expand(right)

  defp same_path?(_, _), do: false

  defp clean_optional_path(path) when is_binary(path) and path != "", do: Path.expand(path)
  defp clean_optional_path(_), do: nil

  defp put_runtime_metadata(metadata, %Runtime{} = runtime) do
    routing = Map.get(metadata, "routing") || Map.get(metadata, :routing) || %{}

    runtime_map =
      %{
        "id" => runtime.id,
        "runtime_id" => runtime.id,
        "runtime_path" => runtime.worktree_path,
        "worktree_path" => runtime.worktree_path,
        "host" => runtime.host_id,
        "os" => runtime.os,
        "repo" => runtime.repo,
        "branch" => runtime.branch,
        "branch_isolation" => runtime.isolation_mode,
        "isolation_mode" => runtime.isolation_mode,
        "runner_id" => runtime.runner_id,
        "session_id" => runtime.session_id,
        "tmux_session_id" => runtime.tmux_session_id,
        "status" => runtime.status,
        "active_assignments" => runtime.active_assignments,
        "concurrency_limit" => runtime.concurrency_limit
      }
      |> put_profile(Profile.for_runtime(runtime))
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()

    required_tools =
      Map.get(runtime.metadata || %{}, "required_tools") ||
        Map.get(runtime.metadata || %{}, :required_tools) ||
        runtime.tools

    routing =
      routing
      |> Map.merge(%{
        "host" => runtime.host_id,
        "os" => runtime.os,
        "repo" => runtime.repo,
        "branch_isolation" => runtime.isolation_mode,
        "runtime_id" => runtime.id,
        "runtime_path" => runtime.worktree_path,
        "tools" => required_tools
      })
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()

    metadata
    |> Map.put("runtime", runtime_map)
    |> Map.put("runtime_id", runtime.id)
    |> Map.put("runtime_path", runtime.worktree_path)
    |> Map.put("routing", routing)
  end

  defp event(%Runtime{} = runtime, from_status, event, opts) do
    %LifecycleEvent{
      id: Ecto.UUID.generate(),
      runtime_id: runtime.id,
      workspace_id: runtime.workspace_id,
      event: event,
      from_status: from_status,
      to_status: runtime.status,
      actor_id: Keyword.get(opts, :actor_id),
      assignment_id: Keyword.get(opts, :assignment_id),
      runner_id: Keyword.get(opts, :runner_id),
      metadata: Keyword.get(opts, :metadata, %{}) || %{},
      inserted_at: DateTime.utc_now()
    }
  end

  defp normalize_filter(filters) when is_map(filters) do
    filters
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp normalize_filter(_), do: %{}

  defp string_value(attrs, key) when is_map(attrs) do
    case DevIDE.Attrs.get(attrs, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp string_value(_, _), do: nil

  defp string_list(attrs, key) when is_map(attrs) do
    case DevIDE.Attrs.get(attrs, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp string_list(_, _), do: []

  defp positive_integer(attrs, key, fallback) when is_map(attrs) do
    value = DevIDE.Attrs.get(attrs, key)

    parsed =
      cond do
        is_integer(value) -> value
        is_binary(value) -> parse_int(value, fallback)
        true -> fallback
      end

    max(parsed, 1)
  end

  defp positive_integer(_, _, fallback), do: fallback

  defp parse_int(value, fallback) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> fallback
    end
  end

  defp datetime_value(attrs, key) when is_map(attrs) do
    case DevIDE.Attrs.get(attrs, key) do
      %DateTime{} = dt ->
        dt

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp datetime_value(_, _), do: nil

  defp map_value(attrs, key) when is_map(attrs) do
    case DevIDE.Attrs.get(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_value(_, _), do: %{}

  defp put_profile(metadata, nil), do: metadata

  defp put_profile(metadata, profile) when is_map(metadata) and is_map(profile),
    do: Map.put(metadata, "runtime_profile", profile)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp impl,
    do:
      Application.get_env(
        :dev_ide,
        :runtimes_adapter,
        DevIDE.Runtimes.MemoryAdapter
      )
end
