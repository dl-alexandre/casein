defmodule DevIDE.Deployment.Drift do
  @moduledoc """
  Detects when the running devbox release is not the revision on `origin/master`.

  Manual local deploys are useful for hotfix validation, but GitHub's canonical
  deploy replaces `/opt/devide/release` from `master`. If the running revision is
  a manual label or a SHA that differs from the remote branch head, surface that
  fact immediately so the operator knows the fix is not durable yet.
  """

  require Logger

  @default_remote "https://github.com/dl-alexandre/dev_ide.git"
  @default_branch "master"

  @type status ::
          :current
          | {:drift, map()}
          | {:unknown, map()}

  @doc "Starts a best-effort async drift check unless disabled by env."
  @spec check_async() :: :ok
  def check_async do
    if System.get_env("DEV_IDE_DEPLOY_DRIFT_CHECK") in ["0", "false", "no"] do
      :ok
    else
      _ = Task.start(fn -> check_and_broadcast() end)
      :ok
    end
  end

  @doc "Runs the remote check and broadcasts/logs drift when detected."
  @spec check_and_broadcast() :: status()
  def check_and_broadcast do
    current = DevIDE.Deployment.Registry.version()
    remote = remote_head()

    status = assess(current, remote, branch())

    case status do
      {:drift, info} ->
        Logger.warning("DevIDE deploy drift detected", Map.to_list(info))
        broadcast(info)

      _ ->
        :ok
    end

    status
  end

  @doc "Pure assessment used by tests and by the runtime check after ls-remote."
  @spec assess(String.t() | nil, {:ok, String.t()} | {:error, term()}, String.t()) :: status()
  def assess(current, {:ok, remote_sha}, branch) when is_binary(remote_sha) do
    current = normalize(current)
    remote_sha = normalize(remote_sha)

    cond do
      current in [nil, ""] ->
        {:unknown, %{reason: :missing_current_revision, remote: remote_sha, branch: branch}}

      current_matches_remote?(current, remote_sha) ->
        :current

      git_sha?(current) ->
        {:drift,
         %{
           reason: :revision_differs,
           current: current,
           remote: remote_sha,
           branch: branch,
           message:
             "Running revision differs from origin/#{branch}; the next GitHub deploy will replace it."
         }}

      true ->
        {:drift,
         %{
           reason: :manual_revision,
           current: current,
           remote: remote_sha,
           branch: branch,
           message:
             "Running revision is a manual label, not origin/#{branch}; commit and push before relying on it."
         }}
    end
  end

  def assess(current, {:error, reason}, branch) do
    {:unknown,
     %{
       reason: :remote_lookup_failed,
       current: normalize(current),
       branch: branch,
       error: inspect(reason)
     }}
  end

  defp remote_head do
    case System.cmd("git", ["ls-remote", remote(), "refs/heads/#{branch()}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(output) do
          [sha | _] -> {:ok, sha}
          _ -> {:error, :empty_ls_remote_output}
        end

      {output, status} ->
        {:error, %{status: status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp broadcast(info) do
    Phoenix.PubSub.broadcast(DevIde.PubSub, "deploy:updates", {:deploy_drift, info})
  rescue
    _ -> :ok
  end

  defp current_matches_remote?(current, remote_sha) do
    current == remote_sha or String.starts_with?(remote_sha, current)
  end

  defp git_sha?(value), do: String.match?(value, ~r/\A[0-9a-f]{7,40}\z/i)
  defp normalize(nil), do: nil
  defp normalize(value), do: value |> to_string() |> String.trim()

  defp remote, do: System.get_env("DEV_IDE_GIT_REMOTE", @default_remote)
  defp branch, do: System.get_env("DEV_IDE_GIT_BRANCH", @default_branch)
end
