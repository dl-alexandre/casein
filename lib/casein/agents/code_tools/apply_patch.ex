defmodule Casein.Agents.CodeTools.ApplyPatch do
  @moduledoc "code_apply_patch: validated unified-diff apply inside the assigned worktree."

  use Jido.Action,
    name: "code_apply_patch",
    description:
      "Apply a validated unified diff inside the assigned worktree. Retrying an already-applied patch is idempotent.",
    category: "code",
    tags: ["code", "mutation"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      worktree_path: [type: :string, required: true],
      patch: [type: :string],
      idempotency_key: [type: :string],
      task_id: [type: :string],
      attempt_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.CodeTools.Helpers
  alias Casein.Policy
  alias Casein.ProposalApply.GitAdapter
  alias Casein.Proposals.UnifiedDiff
  alias McpCtl.Tool

  @max_patch_bytes 512 * 1024

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(
        %{
          workspace_id: Helpers.workspace_id_param(),
          worktree_path: Helpers.worktree_path_param(),
          patch: %{
            type: "string",
            description:
              "Unified diff to apply. Header paths are re-validated against the worktree."
          },
          idempotency_key: %{
            type: "string",
            description:
              "Optional client retry key. Echoed in the result; already-applied patches return applied=true."
          }
        },
        Helpers.identity_params()
      ),
      [:workspace_id, :worktree_path, :patch]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Map.put(Helpers.metadata(:medium, true), :timeout_ms, 30_000)

  @impl Jido.Action
  def run(params, context) do
    with {:ok, assignment} <- Helpers.resolve_assignment(params, context),
         :ok <- Helpers.authorize(&Policy.can_edit_file?/1, assignment),
         {:ok, patch} <- normalize_patch(Map.get(params, :patch)),
         :ok <- validate_patch_size(patch),
         {:ok, changes} <- parse_patch(patch, assignment.worktree_path),
         :ok <- validate_change_paths(assignment.worktree_path, changes) do
      apply_patch(assignment, Map.put(params, :patch, patch), changes)
    end
  end

  defp normalize_patch(patch) when is_binary(patch) and patch != "" do
    {:ok, if(String.ends_with?(patch, "\n"), do: patch, else: patch <> "\n")}
  end

  defp normalize_patch(_), do: {:error, %{error: :missing_argument, message: "patch is required"}}

  defp validate_patch_size(patch) when byte_size(patch) > @max_patch_bytes do
    {:error,
     %{
       error: :too_large,
       message: "Patch exceeds #{@max_patch_bytes} bytes",
       size: byte_size(patch)
     }}
  end

  defp validate_patch_size(_patch), do: :ok

  defp parse_patch(patch, worktree) do
    case UnifiedDiff.parse(patch, worktree) do
      {:ok, changes} ->
        {:ok, changes}

      {:error, :no_headers} ->
        {:error, %{error: :invalid_patch, message: "No unified-diff headers found"}}

      {:error, :invalid_path} ->
        {:error, %{error: :invalid_path, message: "Patch path escapes the worktree"}}

      {:error, reason} ->
        {:error, %{error: :invalid_patch, reason: reason}}
    end
  end

  defp validate_change_paths(worktree, changes) do
    Enum.reduce_while(changes, :ok, fn %{path: path}, :ok ->
      case Helpers.resolve_rel_path(worktree, path) do
        {:ok, _rel, _abs} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_patch(assignment, params, changes) do
    with_temp_patch(params.patch, fn tmp ->
      case GitAdapter.check(assignment.worktree_path, tmp) do
        :ok ->
          case GitAdapter.apply(assignment.worktree_path, tmp) do
            :ok ->
              {:ok, result(assignment, params, changes, already_applied: false)}

            {:error, reason} ->
              {:error, git_error(:apply_failed, reason)}
          end

        {:error, reason} ->
          case GitAdapter.check_reverse(assignment.worktree_path, tmp) do
            :ok ->
              {:ok, result(assignment, params, changes, already_applied: true)}

            _ ->
              {:error, git_error(:patch_does_not_apply, reason)}
          end
      end
    end)
  end

  # The path has a cryptographically random server-generated suffix and is
  # created exclusively before content is written; no request path reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  defp with_temp_patch(patch, fun) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "casein-code-patch-#{suffix}.diff")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(io, patch),
               :ok <- File.close(io) do
            fun.(path)
          else
            {:error, _reason} -> temporary_file_error()
          end
        after
          _ = File.close(io)
          _ = File.rm(path)
        end

      {:error, _reason} ->
        temporary_file_error()
    end
  end

  defp temporary_file_error do
    {:error,
     %{
       error: :temporary_file_unavailable,
       message: "Could not prepare the patch for validation"
     }}
  end

  defp result(assignment, params, changes, already_applied: already?) do
    assignment
    |> Helpers.identity_fields()
    |> Map.merge(%{
      applied: true,
      already_applied: already?,
      idempotent: already?,
      retry: already?,
      idempotency_key: Map.get(params, :idempotency_key),
      paths: Enum.map(changes, & &1.path),
      changes: Enum.map(changes, &%{path: &1.path, kind: &1.kind})
    })
  end

  defp git_error(error, reason) do
    %{
      error: error,
      message: "git apply failed",
      detail: inspect(reason)
    }
  end
end
