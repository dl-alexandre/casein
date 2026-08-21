defmodule Casein.UAT.Git.System do
  @moduledoc """
  Default `Casein.UAT.Git` — publishes a self-heal proposal as a branch + PR via
  `git` and `gh`.

  > **Not exercised by the unit suite.** Pushing branches / opening PRs can't run
  > deterministically in CI-of-this-repo, so proposal *logic* is tested against a
  > fake `Git` and this module is verified by the live self-heal step (open in the
  > plan). Note the repo-local push auth caveat: `git push` must not inherit an
  > ambient `GH_TOKEN` (see the git-push token-shadow lesson) — hence `env -u`.

  Identity comes from `Casein.Identity`. Self-heal runs with no viewer behind
  it, so it normally resolves the *declared* service identity rather than a
  person. Before that, `gh pr create` here inherited whatever the host-global
  `gh` config had selected — so an automated proposal opened a PR under an
  arbitrary engineer's account.
  """

  @behaviour Casein.UAT.Git

  alias Casein.Identity

  @impl true
  def propose(%{branch: branch, files: files, title: title, body: body}) do
    with {:ok, branch} <- safe_branch(branch),
         :ok <- run_git(["checkout", "-B", branch]),
         :ok <- write_and_stage(files),
         :ok <- run_git(Identity.git_config_args(identity()) ++ ["commit", "-m", title]),
         :ok <- push(branch) do
      open_pr(title, body)
    end
  end

  # Proposal paths are repo-relative and validated by repo_relative_path/1 before file writes.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_and_stage(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, _acc ->
      case repo_relative_path(path) do
        {:ok, path} ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)

          case run_git(["add", "--", path]) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # Strip an ambient GH_TOKEN so the repo-local credential helper is used.
  defp push(branch), do: run_env(["-u", "GH_TOKEN", "git", "push", "-u", "origin", branch])

  defp open_pr(title, body) do
    case System.cmd("gh", ["pr", "create", "--title", title, "--body", body],
           env: Identity.gh_env([]),
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:gh_pr_failed, code, out}}
    end
  end

  # No viewer reaches this path, and `env: false` keeps it from picking up a
  # `CASEIN_ACTOR` the release happened to be started with — self-heal must not
  # commit or open PRs under a person who merely launched the server.
  defp identity, do: [env: false]

  defp run_git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:cmd_failed, "git", code, out}}
    end
  end

  defp run_env(args) do
    case System.cmd("env", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:cmd_failed, "env", code, out}}
    end
  end

  defp repo_relative_path(path) when is_binary(path) do
    parts = Path.split(path)

    cond do
      path == "" -> {:error, {:unsafe_path, path}}
      Path.type(path) != :relative -> {:error, {:unsafe_path, path}}
      Enum.any?(parts, &(&1 in ["..", ".git"])) -> {:error, {:unsafe_path, path}}
      true -> {:ok, Path.join(parts)}
    end
  end

  defp repo_relative_path(path), do: {:error, {:unsafe_path, path}}

  defp safe_branch(branch) when is_binary(branch) do
    cond do
      branch == "" -> {:error, {:unsafe_branch, branch}}
      String.starts_with?(branch, ["-", "/", "."]) -> {:error, {:unsafe_branch, branch}}
      String.contains?(branch, ["..", "//", "@{"]) -> {:error, {:unsafe_branch, branch}}
      String.ends_with?(branch, ["/", ".lock"]) -> {:error, {:unsafe_branch, branch}}
      branch =~ ~r/\A[A-Za-z0-9._\/-]+\z/ -> {:ok, branch}
      true -> {:error, {:unsafe_branch, branch}}
    end
  end

  defp safe_branch(branch), do: {:error, {:unsafe_branch, branch}}
end
