defmodule Casein.Agents.ArtifactToolsTest do
  @moduledoc """
  Unit tests for the Jido.Action-backed artifact tool surface.

  The definitions snapshot pins the tools/list wire shape (JSON Schema incl.
  enum/oneOf and string required lists); the invoke tests pin validation
  semantics and the error shapes the MCP envelope normalizes.
  """
  use ExUnit.Case, async: false

  alias Casein.Agents.Activity
  alias Casein.Agents.ArtifactTools
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-artifact-tools-unit"
  @other_workspace_id "ws-artifact-tools-other"

  setup do
    prev_artifact_root = Application.get_env(:dev_ide, :artifact_projects_root)
    prev_agent_roots = Application.get_env(:dev_ide, :agent_worktree_roots)
    prev_launcher_enabled = Application.get_env(:dev_ide, :runtime_preview_launcher_enabled)
    prev_runtimes_adapter = Application.get_env(:dev_ide, :runtimes_adapter)
    prev_workspace_state_adapter = Application.get_env(:dev_ide, :workspace_state_adapter)

    base = Path.join(System.tmp_dir!(), "artifact-tools-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    other_repo = Path.join(base, "other_repo")
    artifact_root = Path.join(base, "artifacts")

    Application.put_env(:dev_ide, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:dev_ide, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
    Application.put_env(:dev_ide, :artifact_projects_root, artifact_root)
    Application.put_env(:dev_ide, :agent_worktree_roots, [])
    Application.put_env(:dev_ide, :runtime_preview_launcher_enabled, false)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()
    init_repo!(repo)
    init_repo!(other_repo)
    seed_workspace!(@workspace_id, "artifact-tools-ws", repo)
    seed_workspace!(@other_workspace_id, "artifact-tools-other", other_repo)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)

      restore_env(:artifact_projects_root, prev_artifact_root)
      restore_env(:agent_worktree_roots, prev_agent_roots)
      restore_env(:runtime_preview_launcher_enabled, prev_launcher_enabled)
      restore_env(:runtimes_adapter, prev_runtimes_adapter)
      restore_env(:workspace_state_adapter, prev_workspace_state_adapter)
    end)

    :ok
  end

  describe "definitions/0" do
    test "artifact_update definition pins the wire shape" do
      update = definition("artifact_update")

      assert update == %{
               name: "artifact_update",
               description:
                 "Update generated artifact files and append feedback to prompt history. " <>
                   "Commits the result in the artifact worktree.",
               parameters: %{
                 type: "object",
                 properties: %{
                   workspace_id: %{
                     type: "string",
                     description:
                       "Casein workspace id. Pre-scoped Artifact MCP endpoints inject this automatically."
                   },
                   artifact_id: %{
                     type: "string",
                     description: "Artifact project id returned by artifact_create."
                   },
                   prompt: %{
                     type: "string",
                     description:
                       "Natural-language request or iteration note to preserve in prompt history."
                   },
                   files: %{
                     description:
                       "Generated files. Either an object of relative path to string content, " <>
                         "or an array of {path, content} objects. Paths must stay inside the worktree.",
                     oneOf: [
                       %{type: "object", additionalProperties: %{type: "string"}},
                       %{
                         type: "array",
                         items: %{
                           type: "object",
                           properties: %{
                             path: %{type: "string"},
                             content: %{type: "string"}
                           },
                           required: ["path", "content"]
                         }
                       }
                     ]
                   }
                 },
                 required: ["workspace_id", "artifact_id"]
               },
               metadata: %{
                 mutation?: true,
                 danger_level: :medium,
                 capabilities: [:artifact_project],
                 recovery_hints: [
                   "Call artifact_list to rediscover artifact ids.",
                   "Use preview_open with preview_open_arguments to view the artifact."
                 ]
               }
             }
    end

    test "artifact_create keeps enum/default on kind and string required list" do
      create = definition("artifact_create")

      assert create.parameters.required == ["workspace_id"]
      assert create.parameters.properties.kind.enum == ["static", "html"]
      assert create.parameters.properties.kind.default == "static"
      assert [%{type: "object"} | _] = create.parameters.properties.files.oneOf

      assert create.metadata == %{
               mutation?: true,
               danger_level: :medium,
               capabilities: [:artifact_project],
               recovery_hints: [
                 "Call artifact_list to rediscover artifact ids.",
                 "Use preview_open with preview_open_arguments to view the artifact."
               ]
             }
    end

    test "exposes all six tools in stable order" do
      assert Enum.map(ArtifactTools.definitions(), & &1.name) == [
               "artifact_create",
               "artifact_update",
               "artifact_list",
               "artifact_get",
               "artifact_serve",
               "artifact_snapshot"
             ]
    end
  end

  describe "invoke/2 validation" do
    test "missing workspace_id" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               ArtifactTools.invoke("artifact_list", %{})
    end

    test "whitespace-only artifact_id counts as missing" do
      assert {:error, {:missing_argument, "artifact_id"}} =
               ArtifactTools.invoke("artifact_get", %{
                 "workspace_id" => @workspace_id,
                 "artifact_id" => "   "
               })
    end

    test "artifact_id aliases id and project_id are accepted" do
      {:ok, created} = create_artifact("Alias Artifact")

      assert {:ok, %{id: _}} =
               ArtifactTools.invoke("artifact_get", %{
                 "workspace_id" => @workspace_id,
                 "id" => created.id
               })

      assert {:ok, %{id: _}} =
               ArtifactTools.invoke("artifact_get", %{
                 "workspace_id" => @workspace_id,
                 "project_id" => created.id
               })
    end

    test "atom-keyed arguments are accepted" do
      assert {:ok, %{count: 0}} =
               ArtifactTools.invoke("artifact_list", %{workspace_id: @workspace_id})
    end

    test "wrong-type argument returns invalid_argument" do
      assert {:error, %{error: :invalid_argument, message: message}} =
               ArtifactTools.invoke("artifact_create", %{
                 "workspace_id" => @workspace_id,
                 "files" => 42
               })

      assert message =~ "files"
    end

    test "unknown tool" do
      assert {:error, :unknown_tool} = ArtifactTools.invoke("artifact_nope", %{})
      assert {:error, :unknown_tool} = ArtifactTools.invoke(:not_a_string, %{})
    end
  end

  describe "invoke/2 happy path" do
    test "create, update, get, snapshot round-trip" do
      assert {:ok, created} = create_artifact("Round Trip")
      assert created.next_tool == "preview_open"
      assert created.next_arguments == created.preview_open_arguments

      assert {:ok, updated} =
               ArtifactTools.invoke("artifact_update", %{
                 "workspace_id" => @workspace_id,
                 "artifact_id" => created.id,
                 "prompt" => "Add a footer",
                 "files" => %{"index.html" => "<h1>Round Trip</h1><footer>v2</footer>\n"}
               })

      assert updated.id == created.id

      assert {:ok, fetched} =
               ArtifactTools.invoke("artifact_get", %{
                 "workspace_id" => @workspace_id,
                 "artifact_id" => created.id
               })

      assert fetched.id == created.id

      assert {:ok, snapshot} =
               ArtifactTools.invoke("artifact_snapshot", %{
                 "workspace_id" => @workspace_id,
                 "artifact_id" => created.id,
                 "label" => "v2"
               })

      assert snapshot.workspace_id == @workspace_id
      assert snapshot.project_id == created.id
      assert is_binary(snapshot.commit_sha)

      assert {:ok, listed} =
               ArtifactTools.invoke("artifact_list", %{"workspace_id" => @workspace_id})

      assert listed.count == 1
    end
  end

  describe "invoke/2 workspace scoping" do
    test "cross-workspace get returns workspace_scope_mismatch" do
      {:ok, created} = create_artifact("Scoped Artifact")

      assert {:error,
              %{
                error: :workspace_scope_mismatch,
                scoped_workspace_id: @other_workspace_id,
                requested_workspace_id: @workspace_id
              }} =
               ArtifactTools.invoke("artifact_get", %{
                 "workspace_id" => @other_workspace_id,
                 "artifact_id" => created.id
               })
    end
  end

  defp definition(name) do
    Enum.find(ArtifactTools.definitions(), &(&1.name == name)) ||
      flunk("no definition for #{name}")
  end

  defp create_artifact(name) do
    ArtifactTools.invoke("artifact_create", %{
      "workspace_id" => @workspace_id,
      "name" => name,
      "prompt" => "Build #{name}",
      "files" => %{"index.html" => "<h1>#{name}</h1>\n"}
    })
  end

  defp seed_workspace!(id, name, repo) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: name,
        path: repo,
        status: :running,
        metadata: %{"id" => id, "name" => name}
      })
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.name", "Casein Test"])
    git!(repo, ["config", "user.email", "devide-test@localhost"])
    File.write!(Path.join(repo, "README.md"), "# Artifact Tools Test\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
