defmodule DevIDE.Agents.ArtifactTools do
  @moduledoc """
  Agent-facing artifact project operations.

  These tools are intentionally a thin wrapper around `DevIDE.ArtifactProjects`:
  agents create and edit isolated Git worktree-backed artifacts here, then hand
  the returned `preview_open_arguments` to Preview MCP when they need a visible
  browser pane.
  """

  alias DevIDE.ArtifactProjects
  alias DevIDE.ArtifactProjects.Project
  alias McpCtl.Tool

  @type tool :: McpCtl.Tool.t()

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    [
      Tool.define(
        "artifact_create",
        "Create a static/html artifact project in an isolated Git worktree for this workspace. " <>
          "Returns artifact metadata plus preview_open_arguments for Preview MCP.",
        Tool.object(
          %{
            workspace_id: workspace_id_param(),
            name: %{type: "string", description: "Human-readable artifact name."},
            kind: kind_param(),
            prompt: prompt_param(),
            files: files_param(),
            base_ref: %{type: "string", description: "Git ref to create the worktree from."},
            branch: %{type: "string", description: "Optional artifact worktree branch name."}
          },
          [:workspace_id]
        ),
        metadata(:medium, true)
      ),
      Tool.define(
        "artifact_update",
        "Update generated artifact files and append feedback to prompt history. " <>
          "Commits the result in the artifact worktree.",
        Tool.object(
          %{
            workspace_id: workspace_id_param(),
            artifact_id: artifact_id_param(),
            prompt: prompt_param(),
            files: files_param()
          },
          [:workspace_id, :artifact_id]
        ),
        metadata(:medium, true)
      ),
      Tool.define(
        "artifact_list",
        "List active artifact projects for the workspace.",
        Tool.object(%{workspace_id: workspace_id_param()}, [:workspace_id]),
        metadata(:low, false)
      ),
      Tool.define(
        "artifact_get",
        "Fetch one artifact project's metadata and preview handoff arguments.",
        Tool.object(%{workspace_id: workspace_id_param(), artifact_id: artifact_id_param()}, [
          :workspace_id,
          :artifact_id
        ]),
        metadata(:low, false)
      ),
      Tool.define(
        "artifact_serve",
        "Ensure the artifact preview server is starting or running, then return " <>
          "updated metadata and preview handoff arguments.",
        Tool.object(%{workspace_id: workspace_id_param(), artifact_id: artifact_id_param()}, [
          :workspace_id,
          :artifact_id
        ]),
        metadata(:medium, true)
      ),
      Tool.define(
        "artifact_snapshot",
        "Create an explicit Git version marker commit for an artifact project.",
        Tool.object(
          %{
            workspace_id: workspace_id_param(),
            artifact_id: artifact_id_param(),
            label: %{type: "string", description: "Short snapshot label."},
            message: %{type: "string", description: "Snapshot commit message suffix."}
          },
          [:workspace_id, :artifact_id]
        ),
        metadata(:medium, true)
      )
    ]
  end

  @doc "Invoke an artifact tool by MCP tool name."
  @spec invoke(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke("artifact_create", args) when is_map(args) do
    with {:ok, workspace_id} <- required_string(args, "workspace_id"),
         {:ok, project} <- ArtifactProjects.create(workspace_id, attrs(args, create_attrs())) do
      {:ok, project_payload(project)}
    end
  end

  def invoke("artifact_update", args) when is_map(args) do
    with {:ok, workspace_id} <- required_string(args, "workspace_id"),
         {:ok, artifact_id} <- required_artifact_id(args),
         {:ok, project} <- get_project(artifact_id),
         :ok <- enforce_workspace(project, workspace_id),
         {:ok, project} <- ArtifactProjects.update(artifact_id, attrs(args, update_attrs())),
         :ok <- enforce_workspace(project, workspace_id) do
      {:ok, project_payload(project)}
    end
  end

  def invoke("artifact_list", args) when is_map(args) do
    with {:ok, workspace_id} <- required_string(args, "workspace_id") do
      artifacts = ArtifactProjects.list(workspace_id) |> Enum.map(&project_payload/1)
      {:ok, %{workspace_id: workspace_id, count: length(artifacts), artifacts: artifacts}}
    end
  end

  def invoke("artifact_get", args) when is_map(args) do
    with {:ok, workspace_id} <- required_string(args, "workspace_id"),
         {:ok, artifact_id} <- required_artifact_id(args),
         {:ok, project} <- get_project(artifact_id),
         :ok <- enforce_workspace(project, workspace_id) do
      {:ok, project_payload(project)}
    end
  end

  def invoke("artifact_serve", args) when is_map(args) do
    with {:ok, workspace_id} <- required_string(args, "workspace_id"),
         {:ok, artifact_id} <- required_artifact_id(args),
         {:ok, project} <- get_project(artifact_id),
         :ok <- enforce_workspace(project, workspace_id),
         {:ok, project} <- ArtifactProjects.serve(artifact_id),
         :ok <- enforce_workspace(project, workspace_id) do
      {:ok, project_payload(project)}
    end
  end

  def invoke("artifact_snapshot", args) when is_map(args) do
    with {:ok, workspace_id} <- required_string(args, "workspace_id"),
         {:ok, artifact_id} <- required_artifact_id(args),
         {:ok, project} <- get_project(artifact_id),
         :ok <- enforce_workspace(project, workspace_id),
         {:ok, snapshot} <- ArtifactProjects.snapshot(artifact_id, attrs(args, snapshot_attrs())) do
      {:ok, Map.put(snapshot, :workspace_id, workspace_id)}
    end
  end

  def invoke(_name, _args), do: {:error, :unknown_tool}

  defp workspace_id_param do
    %{
      type: "string",
      description:
        "DevIDE workspace id. Pre-scoped Artifact MCP endpoints inject this automatically."
    }
  end

  defp artifact_id_param(description \\ "Artifact project id returned by artifact_create.") do
    %{type: "string", description: description}
  end

  defp kind_param do
    %{
      type: "string",
      enum: ["static", "html"],
      default: "static",
      description: "Artifact project kind. Static/html are served from the generated worktree."
    }
  end

  defp prompt_param do
    %{
      type: "string",
      description: "Natural-language request or iteration note to preserve in prompt history."
    }
  end

  defp files_param do
    %{
      description:
        "Generated files. Either an object of relative path to string content, " <>
          "or an array of {path, content} objects. Paths must stay inside the worktree.",
      oneOf: [
        %{type: "object", additionalProperties: %{type: "string"}},
        %{
          type: "array",
          items:
            Tool.object(
              %{
                path: %{type: "string"},
                content: %{type: "string"}
              },
              [:path, :content]
            )
        }
      ]
    }
  end

  defp metadata(danger_level, mutating?) do
    %{
      mutation?: mutating?,
      danger_level: danger_level,
      capabilities: [:artifact_project],
      recovery_hints: [
        "Call artifact_list to rediscover artifact ids.",
        "Use preview_open with preview_open_arguments to view the artifact."
      ]
    }
  end

  defp create_attrs, do: ~w(name kind prompt files base_ref branch)
  defp update_attrs, do: ~w(prompt files)
  defp snapshot_attrs, do: ~w(label message)

  defp attrs(args, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case value(args, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp required_artifact_id(args) do
    case non_empty(value(args, "artifact_id") || value(args, "id") || value(args, "project_id")) do
      nil -> {:error, {:missing_argument, "artifact_id"}}
      id -> {:ok, id}
    end
  end

  defp required_string(args, key) do
    case non_empty(value(args, key)) do
      nil -> {:error, {:missing_argument, key}}
      string -> {:ok, string}
    end
  end

  defp get_project(artifact_id) do
    case ArtifactProjects.get(artifact_id) do
      {:ok, %Project{} = project} -> {:ok, project}
      :error -> {:error, :artifact_not_found}
    end
  end

  defp enforce_workspace(%Project{workspace_id: workspace_id}, workspace_id), do: :ok

  defp enforce_workspace(%Project{workspace_id: actual}, requested) do
    {:error,
     %{
       error: :workspace_scope_mismatch,
       scoped_workspace_id: requested,
       requested_workspace_id: actual,
       message: "Artifact belongs to workspace_id #{inspect(actual)}, not #{inspect(requested)}."
     }}
  end

  defp project_payload(%Project{} = project) do
    payload = ArtifactProjects.payload(project)

    payload
    |> Map.put(:next_tool, "preview_open")
    |> Map.put(:next_arguments, payload.preview_open_arguments)
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom_key(key))
  end

  defp known_atom_key("artifact_id"), do: :artifact_id
  defp known_atom_key("base_ref"), do: :base_ref
  defp known_atom_key("branch"), do: :branch
  defp known_atom_key("files"), do: :files
  defp known_atom_key("id"), do: :id
  defp known_atom_key("kind"), do: :kind
  defp known_atom_key("label"), do: :label
  defp known_atom_key("message"), do: :message
  defp known_atom_key("name"), do: :name
  defp known_atom_key("project_id"), do: :project_id
  defp known_atom_key("prompt"), do: :prompt
  defp known_atom_key("workspace_id"), do: :workspace_id
  defp known_atom_key(_), do: nil

  defp non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty(_), do: nil
end
