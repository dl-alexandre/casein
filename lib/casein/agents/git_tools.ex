defmodule Casein.Agents.GitTools do
  @moduledoc """
  Push-only Git boundary for a completed Casein worker.

  This module never creates, updates, resolves, or merges a pull request. It
  verifies the exact assigned worktree and commit, then emits a safe receipt for
  Dash to consume.
  """

  alias Casein.Agents.{CodeTools, PrHandoff}
  alias Casein.Policy

  @spec push_handoff(map(), map()) :: {:ok, map()} | {:error, map()}
  def push_handoff(params, ctx) when is_map(params) and is_map(ctx) do
    with {:ok, handoff} <-
           PrHandoff.validate(Map.get(params, :handoff) || Map.get(params, "handoff") || %{}),
         {:ok, assignment} <- resolve_assignment(params, ctx),
         :ok <- CodeTools.Helpers.authorize(&Policy.can_enable_agent_write?/1, assignment),
         {:ok, git} <- inspect_worktree(assignment.worktree_path),
         :ok <- ensure_branch(git.branch, handoff.head_branch),
         :ok <- ensure_head(git.head_sha, handoff.head_sha),
         :ok <- ensure_clean(git.status),
         {:ok, remote} <-
           validate_remote(Map.get(params, :remote) || Map.get(params, "remote")),
         :ok <- push(assignment.worktree_path, remote, handoff.head_branch) do
      {:ok,
       CodeTools.Helpers.identity_fields(assignment)
       |> Map.merge(%{
         pushed: true,
         remote: remote,
         remote_branch: handoff.head_branch,
         head_sha: git.head_sha,
         handoff: handoff,
         handoff_id: handoff.handoff_id,
         idempotency_key: PrHandoff.idempotency_key(handoff),
         summary: "worker branch pushed for Dash PR handoff"
       })}
    end
  end

  def push_handoff(_params, _ctx), do: {:error, %{error: :invalid_argument, result: :invalid}}

  defp resolve_assignment(params, ctx) do
    stamped =
      params
      |> Map.put(:workspace_id, ctx[:workspace_id])
      |> Map.put(:worktree_path, ctx[:worktree_path])
      |> Map.put(:task_id, ctx[:task_id])
      |> Map.put(:attempt_id, ctx[:attempt_id])
      |> Map.put(:actor_id, ctx[:principal])

    CodeTools.Helpers.resolve_assignment(stamped, %{actor: ctx[:principal]})
  end

  defp inspect_worktree(path) do
    with {:ok, branch} <-
           git_output(path, ["symbolic-ref", "--quiet", "--short", "HEAD"], :detached_head),
         {:ok, head_sha} <- git_output(path, ["rev-parse", "HEAD"], :git_inspection_failed),
         {:ok, status} <-
           git_output(
             path,
             ["status", "--porcelain", "--untracked-files=all"],
             :git_inspection_failed
           ) do
      {:ok, %{branch: branch, head_sha: head_sha, status: status}}
    end
  end

  defp ensure_branch(branch, branch), do: :ok

  defp ensure_branch(_actual, _expected),
    do: {:error, %{error: :branch_mismatch, result: :denied}}

  defp ensure_head(head, head), do: :ok

  defp ensure_head(_actual, _expected),
    do: {:error, %{error: :head_sha_mismatch, result: :denied}}

  defp ensure_clean(""), do: :ok
  defp ensure_clean(_status), do: {:error, %{error: :dirty_worktree, result: :denied}}

  defp validate_remote(nil), do: {:ok, "origin"}
  defp validate_remote(""), do: {:ok, "origin"}

  defp validate_remote(remote) when is_binary(remote) do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, remote),
      do: {:ok, remote},
      else: {:error, %{error: :invalid_remote, result: :invalid}}
  end

  defp validate_remote(_remote), do: {:error, %{error: :invalid_remote, result: :invalid}}

  defp push(path, remote, branch) do
    push_fun = Application.get_env(:casein, :jido_git_push, &default_push/2)

    case push_fun.(path, [remote, "HEAD:refs/heads/#{branch}"]) do
      :ok ->
        :ok

      {:ok, _details} ->
        :ok

      {:error, _reason} ->
        {:error, %{error: :push_failed, result: :provider_failure, retryable: true}}

      _other ->
        {:error, %{error: :push_failed, result: :provider_failure, retryable: true}}
    end
  end

  defp default_push(path, args) do
    case System.cmd("git", ["-C", path, "push", "--porcelain" | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, code} -> {:error, {:exit_status, code}}
    end
  end

  defp git_output(path, args, error) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, %{error: error, result: :invalid}}
    end
  rescue
    _ -> {:error, %{error: error, result: :invalid}}
  end
end
