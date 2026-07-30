defmodule Casein.ArtifactProjects do
  @moduledoc """
  Generated, previewable artifact projects backed by Git worktrees.

  This MVP intentionally reuses the existing runtime and preview-server
  pipeline instead of introducing another persistence table. Each artifact
  project is a dedicated Git worktree registered through `Casein.Runtimes`; its
  project metadata is stored under runtime metadata key `"artifact_project"`.
  """

  alias Casein.ArtifactProjects.Project
  alias Casein.Files.PathSafety
  alias Casein.Git.Inspector, as: GitInspector
  alias Casein.Runtimes
  alias Casein.Runtimes.{PreviewLauncher, Runtime}
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.WorkspaceRecord

  @artifact_version 1
  @default_kind "static"
  @supported_kinds ~w(static html)
  @max_files 2048
  @max_file_bytes 8 * 1024 * 1024
  @max_total_file_bytes 256 * 1024 * 1024
  @static_preview_command "python3 -m http.server \"$PORT\" --bind 127.0.0.1 --directory .casein/public"

  @type attrs :: map() | keyword()

  @doc """
  Create a static artifact project in a dedicated Git worktree.

  Supported attrs:

    * `:name` / `"name"` - human label; defaults from the generated id
    * `:kind` / `"kind"` - currently `"static"` or `"html"`
    * `:prompt` / `"prompt"` - stored in prompt history and scaffold copy
    * `:files` / `"files"` - map of relative path to text content, or a list of
      file entries containing `path` and either `content` (optionally base64
      encoded) or a workspace-confined server-local `source_path`
    * `:base_ref` / `"base_ref"` - Git ref for the new worktree, defaults to `HEAD`
    * `:branch` / `"branch"` - explicit branch name; otherwise generated
  """
  @spec create(String.t(), attrs()) :: {:ok, Project.t()} | {:error, term()}
  def create(workspace_id, attrs \\ %{})

  def create(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    attrs = Map.new(attrs)
    project_id = project_id(attrs)

    with {:ok, %WorkspaceRecord{} = record} <- State.get(workspace_id),
         :ok <- ensure_workspace_git_checkout(record),
         {:ok, spec} <- create_spec(project_id, attrs, record.host_path),
         {:ok, worktree_path, branch} <- create_worktree(record, spec),
         {:ok, project_metadata} <- write_initial_project(worktree_path, spec, branch),
         {:ok, _parity} <- verify_paths(worktree_path, project_metadata["files"]),
         {:ok, _sha} <- commit_all(worktree_path, "Create artifact project #{spec.name}"),
         {:ok, %Runtime{} = runtime} <-
           Runtimes.observe_worktree(
             record.external_id,
             runtime_attrs(spec, project_metadata, worktree_path)
           ) do
      {:ok, project_from_runtime(runtime)}
    else
      {:error, _reason} = error -> error
      :error -> {:error, :workspace_not_found}
    end
  end

  def create(workspace_id, attrs) when is_binary(workspace_id) and is_list(attrs) do
    create(workspace_id, Map.new(attrs))
  end

  def create(_workspace_id, _attrs), do: {:error, :invalid_workspace_id}

  @doc "Fetch an artifact project by id."
  @spec get(String.t()) :: {:ok, Project.t()} | :error
  def get(project_id) when is_binary(project_id) do
    case Runtimes.get_runtime(project_id) do
      {:ok, %Runtime{} = runtime} -> project_from_runtime_result(runtime)
      :error -> :error
    end
  end

  def get(_project_id), do: :error

  @doc "List active artifact projects for a workspace."
  @spec list(String.t()) :: [Project.t()]
  def list(workspace_id) when is_binary(workspace_id) do
    %{"workspace_id" => workspace_id}
    |> Runtimes.list_runtimes()
    |> Enum.reject(&(&1.status in ["cleaned", "expired"]))
    |> Enum.flat_map(fn runtime ->
      case project_from_runtime_result(runtime) do
        {:ok, project} -> [project]
        :error -> []
      end
    end)
  end

  def list(_workspace_id), do: []

  @doc "Verify every registered generated file matches its public mirror byte-for-byte."
  @spec verify(String.t()) :: {:ok, map()} | {:error, term()}
  def verify(project_id) when is_binary(project_id) do
    with {:ok, %Runtime{} = runtime} <- runtime_project(project_id) do
      verify_paths(runtime.worktree_path, (artifact_metadata(runtime) || %{})["files"])
    end
  end

  def verify(_project_id), do: {:error, :invalid_project_id}

  @doc """
  Update generated files and prompt history, committing a new Git snapshot.

  `attrs` accepts the same `:files` shape as `create/2`; `:prompt` is appended
  to prompt history when present.
  """
  @spec update(String.t(), attrs()) :: {:ok, Project.t()} | {:error, term()}
  def update(project_id, attrs) when is_binary(project_id) do
    attrs = Map.new(attrs)

    with {:ok, %Runtime{} = runtime} <- runtime_project(project_id),
         {:ok, %WorkspaceRecord{} = record} <- State.get(runtime.workspace_id),
         {:ok, files} <-
           files_from_attrs(attrs, allow_empty?: true, source_root: record.host_path),
         {:ok, metadata} <- updated_metadata(runtime, attrs),
         :ok <- write_files(runtime.worktree_path, files),
         :ok <- sync_public_mirror(runtime.worktree_path, metadata["files"]),
         {:ok, _parity} <- verify_paths(runtime.worktree_path, metadata["files"]),
         :ok <- write_manifest(runtime.worktree_path, metadata),
         {:ok, _sha} <- commit_all(runtime.worktree_path, update_commit_message(metadata)),
         {:ok, runtime} <-
           Runtimes.observe_worktree(runtime.workspace_id, %{
             "runtime_id" => runtime.id,
             "worktree_path" => runtime.worktree_path,
             "tmux_session_id" => runtime.tmux_session_id,
             "branch" => runtime.branch,
             "agent" => "artifact_project",
             "source" => "artifact_project",
             "runtime_profile" => runtime_profile(metadata["kind"] || @default_kind),
             "metadata" => %{"artifact_project" => metadata}
           }) do
      {:ok, project_from_runtime(runtime)}
    end
  end

  def update(_project_id, _attrs), do: {:error, :invalid_project_id}

  @doc "Ensure the artifact project's runtime preview server is starting or running."
  @spec serve(String.t()) :: {:ok, Project.t()} | {:error, term()}
  def serve(project_id) when is_binary(project_id) do
    with {:ok, %Runtime{} = runtime} <- runtime_project(project_id),
         :ok <- PreviewLauncher.ensure_started(runtime),
         {:ok, runtime} <- Runtimes.get_runtime(project_id) do
      {:ok, project_from_runtime(runtime)}
    end
  end

  def serve(_project_id), do: {:error, :invalid_project_id}

  @doc """
  Retire an artifact while retaining its Git branch for an explicit restore.

  The runtime is expired, its generated worktree is removed, and the runtime is
  marked cleaned so neither the raw preview server nor durable route can serve it.
  """
  @spec retire(String.t()) :: {:ok, Project.t()} | {:error, term()}
  def retire(project_id) when is_binary(project_id) do
    Runtimes.with_runtime_lock(project_id, fn ->
      with {:ok, %Runtime{} = runtime} <- runtime_project(project_id),
           {:ok, %WorkspaceRecord{} = record} <- workspace_record(runtime.workspace_id),
           {:ok, _expired} <-
             Runtimes.expire_runtime(project_id, %{"reason" => "artifact_retired"}),
           :ok <- remove_artifact_worktree(record, runtime.worktree_path),
           {:ok, %Runtime{} = cleaned} <- Runtimes.cleanup_runtime(project_id) do
        {:ok, project_from_runtime(cleaned)}
      end
    end)
  end

  def retire(_project_id), do: {:error, :invalid_project_id}

  @doc "Create a Git snapshot commit without changing project files."
  @spec snapshot(String.t(), attrs()) :: {:ok, map()} | {:error, term()}
  def snapshot(project_id, attrs \\ %{})

  def snapshot(project_id, attrs) when is_binary(project_id) and is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, %Runtime{} = runtime} <- runtime_project(project_id),
         paths when is_list(paths) <- (artifact_metadata(runtime) || %{})["files"],
         :ok <- sync_public_mirror(runtime.worktree_path, paths),
         {:ok, parity} <- verify_paths(runtime.worktree_path, paths),
         {:ok, sha} <-
           commit_all(runtime.worktree_path, snapshot_message(attrs), allow_empty?: true) do
      {:ok, %{project_id: project_id, commit_sha: sha, parity: parity}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_artifact_generated_files}
    end
  end

  def snapshot(project_id, attrs) when is_binary(project_id) and is_list(attrs) do
    snapshot(project_id, Map.new(attrs))
  end

  def snapshot(_project_id, _attrs), do: {:error, :invalid_project_id}

  @doc """
  Restore a retired artifact project from its retained local Git branch.

  The workspace-scoped form is intended for HTTP and agent boundaries: it
  rejects an artifact id owned by a different workspace before touching disk.
  Restoration is idempotent when the runtime is already provisioned and its
  recorded worktree is still valid.
  """
  @spec restore(String.t()) :: {:ok, Project.t()} | {:error, term()}
  def restore(project_id) when is_binary(project_id) do
    with {:ok, %Runtime{} = runtime} <- runtime_project(project_id) do
      restore(runtime.workspace_id, project_id)
    end
  end

  def restore(_project_id), do: {:error, :invalid_project_id}

  @spec restore(String.t(), String.t()) :: {:ok, Project.t()} | {:error, term()}
  def restore(workspace_id, project_id)
      when is_binary(workspace_id) and is_binary(project_id) do
    Runtimes.with_runtime_lock(project_id, fn ->
      do_restore(workspace_id, project_id)
    end)
  end

  def restore(_workspace_id, _project_id), do: {:error, :invalid_project_id}

  defp do_restore(workspace_id, project_id) do
    with {:ok, %Runtime{} = runtime} <- runtime_project(project_id),
         :ok <- ensure_project_workspace(runtime, workspace_id),
         {:ok, %WorkspaceRecord{} = record} <- workspace_record(workspace_id),
         :ok <- ensure_workspace_git_checkout(record),
         :ok <- ensure_restorable_runtime(runtime),
         {:ok, worktree_path} <- restore_worktree_path(record, runtime),
         {:ok, worktree_state} <- ensure_restored_worktree(record, runtime, worktree_path) do
      Runtimes.with_preview_port_lock(fn ->
        restore_observed_runtime(record, runtime, worktree_path, worktree_state)
      end)
    end
  end

  @doc "Filesystem root that holds generated artifact project worktrees."
  @spec root() :: Path.t()
  def root, do: artifact_root_base()

  @doc "Return the JSON-ready payload shape used by task output and future MCP tools."
  @spec payload(Project.t()) :: map()
  def payload(%Project{} = project) do
    %{
      id: project.id,
      workspace_id: project.workspace_id,
      runtime_id: project.runtime_id,
      name: project.name,
      kind: project.kind,
      status: project.status,
      branch: project.branch,
      worktree_path: project.worktree_path,
      preview_url: project.preview_url,
      preview_server: project.preview_server,
      public_url: public_url(project),
      commit: commit_sha(project),
      retired: retired?(project),
      prompt_history: project.prompt_history,
      metadata: project.metadata || %{},
      created_at: iso(project.created_at),
      updated_at: iso(project.updated_at),
      preview_open_arguments: preview_open_arguments(project)
    }
  end

  @doc """
  Human-facing share metadata for the durable public URL — what a teammate sees
  when the link is pasted in a PR: the title, the branch/commit it was cut from,
  whether it is still live, and when it last changed. Safe to expose to any
  viewer already authorized for the artifact.
  """
  @spec share_metadata(Project.t()) :: %{
          title: String.t(),
          branch: String.t() | nil,
          commit: String.t() | nil,
          status: String.t(),
          retired: boolean(),
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }
  def share_metadata(%Project{} = project) do
    %{
      title: project.name,
      branch: project.branch,
      commit: commit_sha(project),
      status: project.status,
      retired: retired?(project),
      created_at: iso(project.created_at),
      updated_at: iso(project.updated_at)
    }
  end

  @doc """
  True when the artifact can no longer be served from disk — its runtime was
  expired or cleaned, or its worktree is gone. Lets the public route tell a
  retired artifact (show the owner a landing page) apart from a live artifact
  with a merely-missing sub-path (a plain 404).
  """
  @spec retired?(Project.t()) :: boolean()
  def retired?(%Project{status: status}) when status in ["expired", "cleaned"], do: true
  def retired?(%Project{worktree_path: path}) when is_binary(path), do: not File.dir?(path)
  def retired?(_project), do: true

  @doc """
  HEAD sha of the artifact's worktree, or nil when the worktree is gone. Part of
  the share metadata pasted alongside a public artifact link.
  """
  @spec commit_sha(Project.t()) :: String.t() | nil
  def commit_sha(%Project{worktree_path: path}) when is_binary(path) do
    if File.dir?(path) do
      case current_sha(path) do
        {:ok, sha} -> sha
        _ -> nil
      end
    end
  end

  def commit_sha(_project), do: nil

  # Durable, login-gated URL served by CaseinWeb.ArtifactProjectController straight
  # from the worktree — safe to paste in a PR (references stable ids, not the
  # ephemeral loopback preview port). nil when no public base URL is configured
  # (e.g. local dev without CASEIN_URL).
  defp public_url(%Project{workspace_id: ws, id: id}) when is_binary(ws) and is_binary(id) do
    case artifact_public_origin() do
      nil -> nil
      origin -> origin <> "/artifact-projects/" <> ws <> "/" <> id <> "/"
    end
  end

  defp public_url(_), do: nil

  # Prefer a dedicated artifacts origin (stronger isolation) when configured,
  # falling back to the cockpit origin. nil when neither is set (local dev).
  defp artifact_public_origin do
    case Application.get_env(:casein, :artifact_public_url) ||
           Application.get_env(:casein, :preview_app_url) do
      url when is_binary(url) and url != "" -> Casein.Previews.origin_of(url)
      _ -> nil
    end
  end

  @doc "Arguments for opening the artifact through the existing Preview MCP app mode."
  @spec preview_open_arguments(Project.t()) :: map()
  def preview_open_arguments(%Project{} = project) do
    %{
      "workspace_id" => project.workspace_id,
      "mode" => "app",
      "runtime_id" => project.runtime_id
    }
  end

  @doc false
  @spec project_from_runtime(Runtime.t()) :: Project.t()
  def project_from_runtime(%Runtime{} = runtime) do
    metadata = artifact_metadata(runtime)
    preview_server = Runtimes.runtime_preview_server(runtime)

    %Project{
      id: metadata["id"] || runtime.id,
      workspace_id: runtime.workspace_id,
      runtime_id: runtime.id,
      name: metadata["name"] || runtime.id,
      kind: metadata["kind"] || @default_kind,
      status: project_status(runtime, metadata, preview_server),
      worktree_path: runtime.worktree_path,
      branch: runtime.branch || metadata["branch"],
      preview_url: preview_server && preview_server["url"],
      preview_server: preview_server,
      prompt_history: prompt_history(metadata),
      metadata: metadata,
      created_at: parse_datetime(metadata["created_at"]) || runtime.created_at,
      updated_at: parse_datetime(metadata["updated_at"]) || runtime.updated_at
    }
  end

  defp project_from_runtime_result(%Runtime{} = runtime) do
    if artifact_project?(runtime), do: {:ok, project_from_runtime(runtime)}, else: :error
  end

  defp runtime_project(project_id) do
    case Runtimes.get_runtime(project_id) do
      {:ok, %Runtime{} = runtime} ->
        if artifact_project?(runtime), do: {:ok, runtime}, else: {:error, :artifact_not_found}

      :error ->
        {:error, :artifact_not_found}
    end
  end

  defp ensure_project_workspace(%Runtime{workspace_id: workspace_id}, workspace_id), do: :ok
  defp ensure_project_workspace(_runtime, _workspace_id), do: {:error, :artifact_not_found}

  defp workspace_record(workspace_id) do
    case State.get(workspace_id) do
      {:ok, %WorkspaceRecord{} = record} -> {:ok, record}
      _ -> {:error, :workspace_not_found}
    end
  end

  defp ensure_restorable_runtime(%Runtime{status: status})
       when status in ["expired", "cleaned", "provisioned"],
       do: :ok

  defp ensure_restorable_runtime(%Runtime{status: status}),
    do: {:error, {:artifact_not_restorable, status}}

  defp restore_worktree_path(%WorkspaceRecord{} = record, %Runtime{worktree_path: path})
       when is_binary(path) and path != "" do
    root = artifact_root(record) |> Path.expand()
    path = Path.expand(path)
    relative = Path.relative_to(path, root)

    with true <- Path.dirname(path) == root,
         relative when relative not in ["", "."] <- relative,
         {:ok, ^path} <- PathSafety.resolve(root, relative) do
      {:ok, path}
    else
      _ -> {:error, :invalid_artifact_worktree_path}
    end
  end

  defp restore_worktree_path(_record, _runtime),
    do: {:error, :invalid_artifact_worktree_path}

  defp ensure_restored_worktree(record, runtime, worktree_path) do
    case File.lstat(worktree_path) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- validate_restored_worktree(record, runtime, worktree_path) do
          {:ok, :existing}
        end

      {:ok, _stat} ->
        {:error, :artifact_worktree_path_occupied}

      {:error, :enoent} ->
        create_restored_worktree(record, runtime, worktree_path)

      {:error, reason} ->
        {:error, {:artifact_worktree_stat_failed, reason}}
    end
  end

  # restore_worktree_path/2 constrains path to exactly one artifact directory
  # beneath this workspace's segment under the configured artifact root.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_restored_worktree(%WorkspaceRecord{} = record, %Runtime{} = runtime, path) do
    with {:ok, branch} <- retained_branch_ref(record, runtime),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      add_restored_worktree(record, runtime, path, branch, true)
    end
  end

  defp add_restored_worktree(record, runtime, path, branch, retry_stale?) do
    case git(record.host_path, ["worktree", "add", path, branch]) do
      {:ok, _output} ->
        case validate_restored_worktree(record, runtime, path) do
          :ok ->
            {:ok, :created}

          {:error, _reason} = error ->
            _ = rollback_created_worktree(record, path)
            error
        end

      {:error, _reason} = error ->
        recover_failed_worktree_add(record, runtime, path, branch, retry_stale?, error)
    end
  end

  defp recover_failed_worktree_add(record, runtime, path, branch, retry_stale?, error) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case validate_restored_worktree(record, runtime, path) do
          :ok -> {:ok, :existing}
          {:error, _reason} -> error
        end

      {:error, :enoent} when retry_stale? ->
        # `git worktree remove --force` succeeds for an exact registered
        # worktree even when its directory is already gone. It cannot remove a
        # different worktree because path is the validated, recorded path.
        case git(record.host_path, ["worktree", "remove", "--force", path]) do
          {:ok, _output} -> add_restored_worktree(record, runtime, path, branch, false)
          {:error, _reason} -> error
        end

      _ ->
        error
    end
  end

  defp retained_branch_ref(%WorkspaceRecord{} = record, %Runtime{} = runtime) do
    branch = runtime.branch || (artifact_metadata(runtime) || %{})["branch"]

    if is_binary(branch) and String.trim(branch) != "" do
      branch = String.trim(branch)
      ref = "refs/heads/" <> branch

      case git(record.host_path, ["show-ref", "--verify", "--quiet", ref]) do
        # `git worktree add PATH refs/heads/branch` checks out detached HEAD.
        # Verify against the unambiguous full ref, then pass the short local
        # branch name so the restored worktree remains attached to it.
        {:ok, _output} -> {:ok, branch}
        {:error, {:git_exit, 1, _output}} -> {:error, :artifact_branch_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :artifact_branch_not_found}
    end
  end

  defp validate_restored_worktree(%WorkspaceRecord{} = record, %Runtime{} = runtime, path) do
    branch = runtime.branch || (artifact_metadata(runtime) || %{})["branch"]

    with {:ok, parent_common} <- git_common_dir(record.host_path),
         {:ok, worktree_common} <- git_common_dir(path),
         true <- same_path?(parent_common, worktree_common),
         {:ok, toplevel} <- git(path, ["rev-parse", "--show-toplevel"]),
         true <- same_path?(toplevel, path),
         {:ok, checked_out_branch} <- git(path, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         true <- checked_out_branch == branch do
      :ok
    else
      _ -> {:error, :artifact_worktree_mismatch}
    end
  end

  defp git_common_dir(path) do
    with {:ok, common_dir} <- git(path, ["rev-parse", "--git-common-dir"]) do
      {:ok, Path.expand(common_dir, path)}
    end
  end

  defp same_path?(left, right) when is_binary(left) and is_binary(right),
    do: Path.expand(left) == Path.expand(right)

  defp same_path?(_left, _right), do: false

  defp restore_observed_runtime(record, runtime, worktree_path, worktree_state) do
    result =
      if runtime.status == "provisioned" and worktree_state == :existing do
        {:ok, runtime}
      else
        do_restore_observed_runtime(record, runtime, worktree_path)
      end

    case result do
      {:ok, %Runtime{} = restored} ->
        _ = PreviewLauncher.ensure_started(restored)

        case Runtimes.get_runtime(restored.id) do
          {:ok, %Runtime{} = current} -> {:ok, project_from_runtime(current)}
          :error -> {:ok, project_from_runtime(restored)}
        end

      {:error, _reason} = error ->
        if worktree_state == :created, do: rollback_created_worktree(record, worktree_path)
        error

      :error ->
        if worktree_state == :created, do: rollback_created_worktree(record, worktree_path)
        {:error, :artifact_not_found}
    end
  end

  defp do_restore_observed_runtime(_record, runtime, worktree_path) do
    metadata = artifact_metadata(runtime)

    with {:ok, _observed} <-
           Runtimes.observe_worktree(runtime.workspace_id, %{
             "runtime_id" => runtime.id,
             "worktree_path" => worktree_path,
             "tmux_session_id" => runtime.tmux_session_id,
             "branch" => runtime.branch,
             "agent" => "artifact_project",
             "source" => "artifact_project",
             "capabilities" => ["artifact_project", "preview"],
             "tools" => ["artifact_create", "artifact_update", "artifact_serve"],
             "runtime_profile" => runtime_profile(metadata["kind"] || @default_kind),
             "preview_status" => "provisioned",
             "ensure_preview_started" => false,
             "metadata" => %{"artifact_project" => metadata}
           }),
         {:ok, %Runtime{} = restored} <-
           Runtimes.restore_runtime(runtime.id, %{"reason" => "artifact_restore"}) do
      {:ok, restored}
    end
  end

  # The path has already been constrained to the workspace's artifact root.
  # sobelow_skip ["Traversal.FileModule"]
  defp rollback_created_worktree(%WorkspaceRecord{} = record, path) do
    case git(record.host_path, ["worktree", "remove", "--force", path]) do
      {:ok, _output} ->
        :ok

      {:error, _reason} ->
        case File.rm_rf(path) do
          {:ok, _removed} -> :ok
          {:error, reason, _file} -> {:error, {:artifact_worktree_rollback_failed, reason}}
        end
    end
  end

  defp create_spec(project_id, attrs, source_root) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    kind = string_attr(attrs, "kind") || @default_kind

    with :ok <- validate_kind(kind),
         {:ok, files} <-
           files_from_attrs(attrs, allow_empty?: true, source_root: source_root) do
      name = string_attr(attrs, "name") || "Artifact #{String.slice(project_id, 4, 8)}"
      prompt = string_attr(attrs, "prompt")
      slug = slugify(name)
      branch = string_attr(attrs, "branch") || "artifact/#{slug}-#{short_id(project_id)}"
      base_ref = string_attr(attrs, "base_ref") || "HEAD"
      files = if files == %{}, do: default_static_files(name, prompt), else: files

      {:ok,
       %{
         id: project_id,
         name: name,
         kind: kind,
         prompt: prompt,
         prompt_history: prompt_history_from(prompt),
         files: files,
         branch: branch,
         base_ref: base_ref,
         created_at: now,
         updated_at: now
       }}
    end
  end

  # The base root is server config; the workspace segment is slugified before mkdir.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_worktree(%WorkspaceRecord{} = record, spec) do
    root = artifact_root(record)
    worktree_path = Path.join(root, Path.basename(spec.branch))

    with :ok <- ensure_git_available(),
         :ok <- File.mkdir_p(root),
         :ok <- refuse_existing(worktree_path),
         {:ok, _out} <-
           git(record.host_path, [
             "worktree",
             "add",
             "-b",
             spec.branch,
             worktree_path,
             spec.base_ref
           ]) do
      {:ok, worktree_path, spec.branch}
    end
  end

  defp write_initial_project(worktree_path, spec, branch) do
    metadata = %{
      "id" => spec.id,
      "version" => @artifact_version,
      "name" => spec.name,
      "kind" => spec.kind,
      "branch" => branch,
      "status" => "draft",
      "files" => Map.keys(spec.files) |> Enum.sort(),
      "prompt_history" => spec.prompt_history,
      "created_at" => DateTime.to_iso8601(spec.created_at),
      "updated_at" => DateTime.to_iso8601(spec.updated_at)
    }

    with :ok <- write_files(worktree_path, spec.files),
         :ok <- write_manifest(worktree_path, metadata) do
      {:ok, metadata}
    end
  end

  defp updated_metadata(%Runtime{} = runtime, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    current = artifact_metadata(runtime)
    prompt = string_attr(attrs, "prompt")

    metadata =
      current
      |> Map.put("prompt_history", append_prompt(prompt_history(current), prompt))
      |> Map.put("updated_at", DateTime.to_iso8601(now))
      |> Map.put_new("created_at", runtime.created_at && DateTime.to_iso8601(runtime.created_at))
      |> Map.put_new("id", runtime.id)
      |> Map.put_new("name", runtime.id)
      |> Map.put_new("kind", @default_kind)
      |> Map.put_new("version", @artifact_version)
      |> Map.put("files", merged_file_paths(current, attrs))
      |> Map.put("status", "draft")

    {:ok, metadata}
  end

  defp runtime_attrs(spec, project_metadata, worktree_path) do
    profile = runtime_profile(spec.kind)

    %{
      "runtime_id" => spec.id,
      "worktree_path" => worktree_path,
      "branch" => spec.branch,
      "agent" => "artifact_project",
      "source" => "artifact_project",
      "capabilities" => ["artifact_project", "preview"],
      "tools" => ["artifact_create", "artifact_update", "artifact_serve"],
      "runtime_profile" => profile,
      "metadata" => %{
        "artifact_project" => project_metadata,
        "runtime_profile" => profile
      }
    }
  end

  defp runtime_profile(kind) when kind in @supported_kinds do
    %{
      "name" => "artifact-static",
      "kind" => "static",
      "env" => %{"CASEIN_RUNTIME_PREVIEW_COMMAND" => @static_preview_command}
    }
  end

  defp ensure_workspace_git_checkout(%WorkspaceRecord{host_path: root}) when is_binary(root) do
    cond do
      not File.dir?(root) ->
        {:error, :workspace_root_unavailable}

      match?({:ok, %GitInspector{}}, GitInspector.inspect_cwd(root)) ->
        :ok

      true ->
        {:error, :workspace_not_git_checkout}
    end
  end

  defp ensure_workspace_git_checkout(_), do: {:error, :workspace_root_unavailable}

  defp artifact_root(%WorkspaceRecord{} = record) do
    Path.join(artifact_root_base(), slugify(record.name || record.external_id))
  end

  defp artifact_root_base do
    root =
      Application.get_env(:casein, :artifact_projects_root) ||
        Path.join([System.tmp_dir!(), "casein-agent-worktrees", "artifacts"])

    Path.expand(root)
  end

  defp files_from_attrs(attrs, opts) do
    files = Casein.PayloadAttrs.get(attrs, "files")

    cond do
      is_nil(files) and Keyword.get(opts, :allow_empty?, false) ->
        {:ok, %{}}

      is_map(files) ->
        files
        |> Enum.reduce_while({:ok, %{}}, fn {path, content}, {:ok, acc} ->
          with {:ok, path} <- normalize_file_path(path),
               {:ok, content} <- normalize_file_content(content) do
            {:cont, {:ok, Map.put(acc, path, content)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> validate_file_count()
        |> validate_total_file_bytes()

      is_list(files) ->
        files
        |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
          with path when is_binary(path) <- Casein.PayloadAttrs.get(entry, "path"),
               {:ok, path} <- normalize_file_path(path),
               {:ok, content} <- file_entry_content(entry, opts) do
            {:cont, {:ok, Map.put(acc, path, content)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
            _ -> {:halt, {:error, :invalid_artifact_file}}
          end
        end)
        |> validate_file_count()
        |> validate_total_file_bytes()

      true ->
        {:error, :invalid_files}
    end
  end

  defp validate_file_count({:ok, files}) when map_size(files) <= @max_files, do: {:ok, files}
  defp validate_file_count({:ok, _files}), do: {:error, :too_many_artifact_files}
  defp validate_file_count(error), do: error

  defp validate_total_file_bytes({:ok, files}) do
    total = files |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))

    if total <= @max_total_file_bytes,
      do: {:ok, files},
      else: {:error, :artifact_files_too_large}
  end

  defp validate_total_file_bytes(error), do: error

  defp normalize_file_path(path) when is_binary(path) do
    path = path |> String.trim() |> String.trim_leading("./")
    parts = Path.split(path)

    cond do
      path == "" ->
        {:error, :invalid_artifact_path}

      Path.type(path) == :absolute ->
        {:error, :invalid_artifact_path}

      Enum.any?(parts, &(&1 in ["", ".", ".."])) ->
        {:error, :invalid_artifact_path}

      List.first(parts) == ".git" ->
        {:error, :invalid_artifact_path}

      true ->
        {:ok, Path.join(parts)}
    end
  end

  defp normalize_file_path(_), do: {:error, :invalid_artifact_path}

  defp normalize_file_content(content) when is_binary(content) do
    if byte_size(content) <= @max_file_bytes,
      do: {:ok, content},
      else: {:error, :artifact_file_too_large}
  end

  defp normalize_file_content(_), do: {:error, :invalid_artifact_file}

  defp file_entry_content(entry, opts) when is_map(entry) do
    content = Casein.PayloadAttrs.get(entry, "content")
    source_path = Casein.PayloadAttrs.get(entry, "source_path")
    encoding = Casein.PayloadAttrs.get(entry, "encoding") || "utf8"

    cond do
      is_binary(content) and is_nil(source_path) ->
        decode_file_content(content, encoding)

      is_binary(source_path) and is_nil(content) ->
        read_source_file(source_path, Keyword.get(opts, :source_root))

      true ->
        {:error, :invalid_artifact_file}
    end
  end

  defp decode_file_content(content, "utf8"), do: normalize_file_content(content)

  defp decode_file_content(content, "base64") do
    case Base.decode64(content) do
      {:ok, decoded} -> normalize_file_content(decoded)
      :error -> {:error, :invalid_artifact_base64}
    end
  end

  defp decode_file_content(_content, _encoding), do: {:error, :invalid_artifact_encoding}

  # PathSafety.resolve/2 confines source_path to the workspace root and rejects symlink escapes.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_source_file(source_path, source_root)
       when is_binary(source_path) and is_binary(source_root) do
    with {:ok, resolved} <- PathSafety.resolve(source_root, source_path),
         true <- File.regular?(resolved),
         {:ok, stat} <- File.stat(resolved) do
      if stat.size <= @max_file_bytes do
        File.read(resolved)
      else
        {:error, :artifact_file_too_large}
      end
    else
      false -> {:error, :invalid_artifact_source_path}
      {:error, _reason} -> {:error, :invalid_artifact_source_path}
    end
  end

  defp read_source_file(_source_path, _source_root),
    do: {:error, :invalid_artifact_source_path}

  defp merged_file_paths(current, attrs) do
    existing = Map.get(current, "files", [])

    incoming =
      case Casein.PayloadAttrs.get(attrs, "files") do
        files when is_map(files) -> Map.keys(files)
        files when is_list(files) -> Enum.map(files, &Casein.PayloadAttrs.get(&1, "path"))
        _ -> []
      end

    (existing ++ incoming)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn path ->
      case normalize_file_path(path) do
        {:ok, normalized} -> normalized
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp write_files(_worktree_path, files) when files == %{}, do: :ok

  defp write_files(worktree_path, files) when is_binary(worktree_path) and is_map(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case write_generated_file(worktree_path, path, content) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp write_generated_file(worktree_path, path, content) do
    with :ok <- write_file(worktree_path, path, content) do
      write_file(worktree_path, Path.join(".casein/public", path), content)
    end
  end

  # Every manifest path is normalized and resolved beneath worktree_path before it is read.
  # sobelow_skip ["Traversal.FileModule"]
  defp sync_public_mirror(worktree_path, paths)
       when is_binary(worktree_path) and is_list(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      with {:ok, path} <- normalize_file_path(path),
           {:ok, source} <- PathSafety.resolve(worktree_path, path),
           true <- File.regular?(source),
           {:ok, content} <- File.read(source),
           :ok <- write_file(worktree_path, Path.join(".casein/public", path), content) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :artifact_generated_file_missing}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_public_mirror(_worktree_path, _paths),
    do: {:error, :invalid_artifact_generated_files}

  defp verify_paths(worktree_path, paths)
       when is_binary(worktree_path) and is_list(paths) do
    mismatches =
      Enum.reduce(paths, [], fn path, acc ->
        with {:ok, path} <- normalize_file_path(path),
             {:ok, source} <- PathSafety.resolve(worktree_path, path),
             {:ok, public} <-
               PathSafety.resolve(worktree_path, Path.join(".casein/public", path)),
             true <- File.regular?(source),
             true <- File.regular?(public),
             {:ok, source_hash} <- file_hash(source),
             {:ok, public_hash} <- file_hash(public),
             true <- source_hash == public_hash do
          acc
        else
          _ -> [path | acc]
        end
      end)
      |> Enum.reverse()

    if mismatches == [] do
      {:ok,
       %{
         status: "ok",
         file_count: length(paths),
         checked_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
       }}
    else
      {:error, {:artifact_public_mirror_mismatch, mismatches}}
    end
  end

  defp verify_paths(_worktree_path, _paths),
    do: {:error, :invalid_artifact_generated_files}

  # Callers resolve both root and mirror paths beneath the artifact worktree.
  # sobelow_skip ["Traversal.FileModule"]
  defp file_hash(path) do
    with {:ok, bytes} <- File.read(path) do
      {:ok, :crypto.hash(:sha256, bytes)}
    end
  end

  defp write_manifest(worktree_path, metadata) do
    write_file(worktree_path, ".casein/artifact.json", Jason.encode!(metadata, pretty: true))
  end

  # rel_path is normalized, resolved through PathSafety, and checked against worktree_path.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(worktree_path, rel_path, content) do
    with {:ok, rel_path} <- normalize_file_path(rel_path),
         {:ok, target} <- PathSafety.resolve(worktree_path, rel_path),
         :ok <- ensure_under_root(worktree_path, target),
         :ok <- File.mkdir_p(Path.dirname(target)) do
      File.write(target, content)
    end
  end

  defp ensure_under_root(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    rel = Path.relative_to(path, root)

    if rel != path and not String.starts_with?(rel, ".."),
      do: :ok,
      else: {:error, :invalid_artifact_path}
  end

  defp remove_artifact_worktree(%WorkspaceRecord{} = record, path) when is_binary(path) do
    if File.exists?(path) do
      case git(record.host_path, ["worktree", "remove", "--force", path]) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, {:artifact_retire_failed, reason}}
      end
    else
      :ok
    end
  end

  defp remove_artifact_worktree(_record, _path), do: {:error, :invalid_artifact_worktree_path}

  defp default_static_files(name, prompt) do
    %{
      "index.html" => default_index_html(name, prompt),
      "styles.css" => default_styles_css(),
      "README.md" => default_readme(name, prompt)
    }
  end

  defp default_index_html(name, prompt) do
    escaped_name = html_escape(name)
    escaped_prompt = html_escape(prompt || "A new Casein artifact project.")

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{escaped_name}</title>
        <link rel="stylesheet" href="./styles.css">
      </head>
      <body>
        <main class="artifact-shell">
          <section class="artifact-panel">
            <p class="eyebrow">Casein Artifact</p>
            <h1>#{escaped_name}</h1>
            <p class="prompt">#{escaped_prompt}</p>
          </section>
        </main>
      </body>
    </html>
    """
  end

  defp default_styles_css do
    """
    :root {
      color-scheme: light;
      font-family:
        Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f7f7f4;
      color: #18181b;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
    }

    .artifact-shell {
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 48px 20px;
      background:
        linear-gradient(135deg, rgba(14, 116, 144, 0.08), transparent 40%),
        linear-gradient(315deg, rgba(132, 204, 22, 0.12), transparent 36%),
        #f7f7f4;
    }

    .artifact-panel {
      width: min(760px, 100%);
      border: 1px solid rgba(39, 39, 42, 0.14);
      border-radius: 8px;
      background: rgba(255, 255, 255, 0.88);
      padding: clamp(28px, 5vw, 56px);
      box-shadow: 0 20px 60px rgba(39, 39, 42, 0.12);
    }

    .eyebrow {
      margin: 0 0 12px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0;
      text-transform: uppercase;
      color: #0f766e;
    }

    h1 {
      margin: 0;
      font-size: clamp(36px, 8vw, 72px);
      line-height: 0.96;
      letter-spacing: 0;
    }

    .prompt {
      margin: 22px 0 0;
      max-width: 58ch;
      font-size: clamp(16px, 2vw, 20px);
      line-height: 1.55;
      color: #3f3f46;
    }
    """
  end

  defp default_readme(name, nil), do: "# #{name}\n\nGenerated by Casein Artifact Projects.\n"
  defp default_readme(name, prompt), do: "# #{name}\n\n#{prompt}\n"

  defp validate_kind(kind) when kind in @supported_kinds, do: :ok

  defp validate_kind(kind),
    do:
      {:error,
       %{
         error: :unsupported_artifact_kind,
         kind: kind,
         supported_kinds: @supported_kinds
       }}

  defp artifact_project?(%Runtime{} = runtime), do: is_map(artifact_metadata(runtime))

  defp artifact_metadata(%Runtime{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "artifact_project") || Map.get(metadata, :artifact_project) do
      project when is_map(project) -> project
      _ -> nil
    end
  end

  defp artifact_metadata(_), do: nil

  defp project_status(%Runtime{} = runtime, metadata, preview_server) do
    cond do
      runtime.status in ["expired", "cleaned"] -> runtime.status
      is_map(preview_server) and is_binary(preview_server["status"]) -> preview_server["status"]
      is_binary(metadata["status"]) -> metadata["status"]
      true -> runtime.status
    end
  end

  defp prompt_history(metadata) when is_map(metadata),
    do: prompt_history(Map.get(metadata, "prompt_history") || Map.get(metadata, :prompt_history))

  defp prompt_history(values) when is_list(values),
    do: values |> Enum.filter(&is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))

  defp prompt_history(_), do: []

  defp prompt_history_from(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)
    if prompt == "", do: [], else: [prompt]
  end

  defp prompt_history_from(_), do: []

  defp append_prompt(history, prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)
    if prompt == "", do: history, else: history ++ [prompt]
  end

  defp append_prompt(history, _), do: history

  defp update_commit_message(metadata) do
    "Update artifact project #{metadata["name"] || metadata["id"] || "artifact"}"
  end

  defp snapshot_message(attrs) do
    case string_attr(attrs, "label") || string_attr(attrs, "message") do
      nil -> "Snapshot artifact project"
      label -> "Snapshot artifact project: #{label}"
    end
  end

  # Git is invoked with argv-style arguments only; no shell interpolation.
  # sobelow_skip ["CI.System"]
  defp git(cwd, args) when is_binary(cwd) and is_list(args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_exit, code, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_failed, Exception.message(error)}}
  end

  defp commit_all(worktree_path, message, opts \\ []) do
    with {:ok, _} <- git(worktree_path, ["add", "--all"]) do
      allow_empty_args =
        if Keyword.get(opts, :allow_empty?, false), do: ["--allow-empty"], else: []

      args =
        [
          "-c",
          "user.name=Casein Artifact",
          "-c",
          "user.email=casein-artifacts@localhost",
          "commit",
          "--no-verify"
        ] ++ allow_empty_args ++ ["-m", message]

      case git(worktree_path, args) do
        {:ok, _out} -> current_sha(worktree_path)
        {:error, {:git_exit, 1, output}} -> maybe_no_changes(worktree_path, output)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_no_changes(worktree_path, output) do
    if String.contains?(output, "nothing to commit"),
      do: current_sha(worktree_path),
      else: {:error, {:git_commit_failed, output}}
  end

  defp current_sha(worktree_path), do: git(worktree_path, ["rev-parse", "HEAD"])

  defp ensure_git_available do
    if System.find_executable("git"), do: :ok, else: {:error, :git_not_found}
  end

  defp refuse_existing(path) do
    if File.exists?(path), do: {:error, :artifact_worktree_exists}, else: :ok
  end

  defp project_id(attrs) do
    case string_attr(attrs, "id") do
      "art-" <> _ = id -> id
      _ -> "art-" <> Ecto.UUID.generate()
    end
  end

  defp string_attr(attrs, key) when is_map(attrs) do
    case Casein.PayloadAttrs.get(attrs, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        Atom.to_string(value)

      _ ->
        nil
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "artifact"
      slug -> String.slice(slug, 0, 48)
    end
  end

  defp short_id("art-" <> rest), do: String.slice(rest, 0, 8)
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp html_escape(_), do: ""
end
