defmodule Casein.Agents.JidoWorkcell.Git.LocalAdapter do
  @moduledoc """
  Local argv-only implementation of the audited Workcell Git adapter.

  Every command uses a fixed `git` executable and an explicit argument list.
  The scope is rechecked before each mutation so a worker cannot retain a
  stale branch binding after a coordinator changes the worktree.
  """

  @behaviour Casein.Agents.JidoWorkcell.Git.Adapter

  alias Casein.Agents.JidoWorkcell.Git.Scope

  @max_output_bytes 256 * 1024

  @impl true
  def bind(%Scope{} = scope) do
    with {:ok, root} <- git_root(scope),
         {:ok, branch} <- current_branch(scope),
         :ok <- if(branch == scope.assigned_branch, do: :ok, else: {:error, :branch_mismatch}) do
      {:ok, %{scope | worktree_root: root}}
    end
  end

  @impl true
  def status(%Scope{} = scope) do
    with :ok <- verify_binding(scope),
         {:ok, output} <- run(scope, ["status", "--porcelain=v1", "--untracked-files=all", "-z"]) do
      {:ok, %{branch: scope.assigned_branch, entries: parse_status(output)}}
    end
  end

  @impl true
  def diff(%Scope{} = scope, paths) when is_list(paths) do
    with :ok <- verify_binding(scope),
         :ok <- ensure_paths(scope, paths),
         {:ok, output} <-
           run(scope, ["diff", "--no-color", "--no-ext-diff", "--"] ++ paths) do
      {:ok, %{branch: scope.assigned_branch, paths: paths, diff: cap(output)}}
    end
  end

  @impl true
  def stage(%Scope{} = scope, paths) when is_list(paths) do
    with :ok <- verify_binding(scope),
         :ok <- ensure_paths(scope, paths),
         {:ok, _output} <- run(scope, ["add", "--"] ++ paths),
         {:ok, staged} <- staged_paths(scope),
         :ok <- ensure_staged_scope(scope, staged, paths) do
      {:ok, %{branch: scope.assigned_branch, paths: staged}}
    end
  end

  @impl true
  def commit(%Scope{} = scope, attrs) when is_map(attrs) do
    with :ok <- verify_binding(scope),
         {:ok, message} <- Scope.validate_commit_message(value(attrs, :message)),
         {:ok, staged} <- staged_paths(scope),
         :ok <- ensure_staged_scope(scope, staged, value(attrs, :paths, staged)),
         {:ok, _output} <- run(scope, ["commit", "-m", message]),
         {:ok, sha} <- head_sha(scope) do
      {:ok, %{head_sha: sha, changed_files: staged}}
    end
  end

  @impl true
  def push(%Scope{} = scope) do
    if scope.push_allowed? do
      with :ok <- verify_binding(scope),
           {:ok, _output} <-
             run(scope, ["push", "--porcelain", "origin", "HEAD:" <> scope.assigned_branch]) do
        {:ok, %{branch: scope.assigned_branch, pushed?: true}}
      end
    else
      {:error, :push_not_authorized}
    end
  end

  @impl true
  def head_sha(%Scope{} = scope) do
    with :ok <- verify_binding(scope),
         {:ok, output} <- run(scope, ["rev-parse", "HEAD"]),
         sha <- String.trim(output),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      {:ok, sha}
    else
      false -> {:error, :invalid_head_sha}
      {:error, _} = error -> error
    end
  end

  defp verify_binding(%Scope{} = scope) do
    with {:ok, root} <- git_root(scope),
         {:ok, branch} <- current_branch(scope),
         :ok <-
           if(root == scope.worktree_root || is_nil(scope.worktree_root),
             do: :ok,
             else: {:error, :worktree_changed}
           ),
         :ok <- if(branch == scope.assigned_branch, do: :ok, else: {:error, :branch_mismatch}) do
      :ok
    end
  end

  defp git_root(scope) do
    with {:ok, output} <- run(scope, ["rev-parse", "--show-toplevel"]),
         root <- Path.expand(String.trim(output)),
         true <- root == scope.worktree_path do
      {:ok, root}
    else
      false -> {:error, :worktree_mismatch}
      {:error, _} = error -> error
    end
  end

  defp current_branch(scope) do
    with {:ok, output} <- run(scope, ["branch", "--show-current"]),
         branch <- String.trim(output),
         true <- branch != "" do
      {:ok, branch}
    else
      false -> {:error, :detached_head}
      {:error, _} = error -> error
    end
  end

  defp staged_paths(scope) do
    with {:ok, output} <- run(scope, ["diff", "--cached", "--name-only", "-z"]) do
      {:ok, parse_nul_paths(output)}
    end
  end

  defp ensure_staged_scope(scope, staged, requested) do
    with {:ok, requested} <- Scope.validate_paths(scope, requested) do
      cond do
        staged == [] -> {:error, :nothing_to_commit}
        Enum.any?(staged, &(&1 not in scope.allowed_paths)) -> {:error, :staged_path_not_allowed}
        Enum.sort(staged) != Enum.sort(requested) -> {:error, :staged_path_mismatch}
        true -> :ok
      end
    end
  end

  defp ensure_paths(scope, paths) do
    case Scope.validate_paths(scope, paths) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_status(output) do
    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == <<>>))
    |> Enum.map(fn entry ->
      case entry do
        <<x::binary-size(1), y::binary-size(1), " ", path::binary>> ->
          %{x: x, y: y, path: path}

        path ->
          %{x: "?", y: "?", path: path}
      end
    end)
  end

  defp parse_nul_paths(output) do
    output
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == <<>>))
  end

  # sobelow_skip ["CI.System"]
  defp run(%Scope{} = scope, args) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        case System.cmd(git, ["-C", scope.worktree_path | args], stderr_to_stdout: true) do
          {output, 0} -> {:ok, cap(output)}
          {output, code} -> {:error, {:git_exit, code, cap(output)}}
        end
    end
  rescue
    _ -> {:error, :git_failed}
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp cap(output) when byte_size(output) > @max_output_bytes do
    binary_part(output, 0, @max_output_bytes) <> "\n... [truncated]"
  end

  defp cap(output), do: output
end
