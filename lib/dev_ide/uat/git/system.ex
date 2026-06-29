defmodule DevIDE.UAT.Git.System do
  @moduledoc """
  Default `DevIDE.UAT.Git` — publishes a self-heal proposal as a branch + PR via
  `git` and `gh`.

  > **Not exercised by the unit suite.** Pushing branches / opening PRs can't run
  > deterministically in CI-of-this-repo, so proposal *logic* is tested against a
  > fake `Git` and this module is verified by the live self-heal step (open in the
  > plan). Note the repo-local push auth caveat: `git push` must not inherit an
  > ambient `GH_TOKEN` (see the git-push token-shadow lesson) — hence `env -u`.
  """

  @behaviour DevIDE.UAT.Git

  @impl true
  def propose(%{branch: branch, files: files, title: title, body: body}) do
    with :ok <- run("git", ["checkout", "-B", branch]),
         :ok <- write_and_stage(files),
         :ok <- run("git", ["commit", "-m", title]),
         :ok <- push(branch) do
      open_pr(title, body)
    end
  end

  defp write_and_stage(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, _acc ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      case run("git", ["add", path]) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # Strip an ambient GH_TOKEN so the repo-local credential helper is used.
  defp push(branch), do: run("env", ["-u", "GH_TOKEN", "git", "push", "-u", "origin", branch])

  defp open_pr(title, body) do
    case System.cmd("gh", ["pr", "create", "--title", title, "--body", body],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:gh_pr_failed, code, out}}
    end
  end

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:cmd_failed, cmd, code, out}}
    end
  end
end
