defmodule Casein.Agents.ArtifactTools.Helpers do
  @moduledoc """
  Shared JSON-Schema fragments and domain helpers for the artifact tool
  actions. The schema fragments are the wire shape served on tools/list —
  keep them byte-identical across tools so the MCP contract stays stable.
  """

  alias Casein.ArtifactProjects
  alias Casein.ArtifactProjects.Project
  alias McpCtl.Tool

  @doc false
  def workspace_id_param do
    %{
      type: "string",
      description:
        "Casein workspace id. Pre-scoped Artifact MCP endpoints inject this automatically."
    }
  end

  @doc false
  def artifact_id_param(description \\ "Artifact project id returned by artifact_create.") do
    %{type: "string", description: description}
  end

  @doc false
  def kind_param do
    %{
      type: "string",
      enum: ["static", "html"],
      default: "static",
      description: "Artifact project kind. Static/html are served from the generated worktree."
    }
  end

  @doc false
  def prompt_param do
    %{
      type: "string",
      description: "Natural-language request or iteration note to preserve in prompt history."
    }
  end

  @doc false
  def files_param do
    %{
      description:
        "Generated files. Either an object of relative path to string content, " <>
          "or an array of file objects. File objects accept UTF-8 content, base64 content " <>
          "with encoding=\"base64\", or a server-local source_path confined to the workspace checkout. " <>
          "Destination paths must stay inside the artifact.",
      oneOf: [
        %{type: "object", additionalProperties: %{type: "string"}},
        %{
          type: "array",
          items:
            Tool.object(
              %{
                path: %{type: "string"},
                content: %{type: "string"},
                encoding: %{type: "string", enum: ["utf8", "base64"], default: "utf8"},
                source_path: %{
                  type: "string",
                  description:
                    "Server-local file inside the workspace checkout. Mutually exclusive with content."
                }
              },
              [:path]
            )
        }
      ]
    }
  end

  @doc false
  def metadata(danger_level, mutating?) do
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

  @doc "Fetch a project by id, mapping the domain's :error to :artifact_not_found."
  def get_project(artifact_id) do
    case ArtifactProjects.get(artifact_id) do
      {:ok, %Project{} = project} -> {:ok, project}
      :error -> {:error, :artifact_not_found}
    end
  end

  @doc "Reject cross-workspace access with the locked workspace_scope_mismatch shape."
  def enforce_workspace(%Project{workspace_id: workspace_id}, workspace_id), do: :ok

  def enforce_workspace(%Project{workspace_id: actual}, requested) do
    {:error,
     %{
       error: :workspace_scope_mismatch,
       scoped_workspace_id: requested,
       requested_workspace_id: actual,
       message: "Artifact belongs to workspace_id #{inspect(actual)}, not #{inspect(requested)}."
     }}
  end

  @doc "Project payload plus the preview_open handoff hint."
  def project_payload(%Project{} = project) do
    payload = ArtifactProjects.payload(project)

    payload
    |> Map.put(:next_tool, "preview_open")
    |> Map.put(:next_arguments, payload.preview_open_arguments)
  end
end
