defmodule Casein.Worktrees.UnpushedAudit do
  @moduledoc """
  Finds agent worktrees holding commits that exist on no origin ref.

  A worktree under the OS temp root is on a deletion timer
  (`/usr/lib/tmpfiles.d/tmp.conf` ages `/tmp` out at 30 days), and nothing
  surfaces that to the agent working in it. Work that was never pushed then has
  a fuse on it: when the sweep runs, or when `git worktree prune` runs, the
  commits are simply gone.

  The check is `git rev-list --count HEAD --not --remotes=origin`: commits
  reachable from `HEAD` and from no origin remote-tracking ref. That phrasing
  matters. Comparing against an upstream misses the two shapes that actually
  bite —

    * a **branch renamed after creation**, whose name no longer matches its
      worktree and which may have no upstream at all, so `ahead` is `nil`
      rather than a count;
    * a **detached HEAD**, which has no branch and therefore no upstream to be
      ahead of. This is the unrecoverable case: `git worktree prune` takes it
      with no ref left anywhere pointing at the commits.

  — and neither depends on a name, so neither is found by looking one up.

  Read-only. It runs `rev-list`, `status` and `rev-parse` and reports; it
  pushes nothing, prunes nothing, and moves nothing. Whose branch gets pushed
  is the owner's call, which is the whole reason this reports rather than acts.
  """

  require Logger

  alias Casein.Paths

  @typedoc "One audited worktree."
  @type entry :: %{
          path: String.t(),
          branch: String.t() | nil,
          detached?: boolean(),
          head_sha: String.t() | nil,
          unpushed: non_neg_integer(),
          dirty?: boolean(),
          at_risk?: boolean(),
          verdict: verdict()
        }

  @typedoc """
  How much is at stake in one worktree.

    * `:unrecoverable` — unpushed commits on a detached HEAD: no ref anywhere
    * `:unpushed` — unpushed commits on a named branch
    * `:uncommitted` — nothing unpushed, but the tree is dirty
    * `:clean` — everything is on an origin ref and the tree is clean
  """
  @type verdict :: :unrecoverable | :unpushed | :uncommitted | :clean

  @doc """
  Audit every agent worktree under the configured roots.

  Options are for tests: `:roots` replaces `Casein.Paths.agent_worktree_roots/0`,
  `:runner` replaces the git call (`(path, [arg]) -> {output, exit_status}`),
  and `:lister` replaces the directory scan.
  """
  @spec audit(keyword()) :: [entry()]
  def audit(opts \\ []) do
    roots = Keyword.get_lazy(opts, :roots, &Paths.agent_worktree_roots/0)
    lister = Keyword.get(opts, :lister, &worktrees_under/1)

    roots
    |> Enum.flat_map(fn root -> Enum.map(lister.(root), &{root, &1}) end)
    |> Enum.map(fn {root, path} -> audit_one(path, at_risk?(root), opts) end)
  end

  @doc """
  Audit one worktree path. `at_risk?` marks a root that is swept on a timer.
  """
  @spec audit_one(String.t(), boolean(), keyword()) :: entry()
  def audit_one(path, at_risk?, opts \\ []) do
    run = Keyword.get(opts, :runner, &run_git/2)
    branch = trimmed(run.(path, ["rev-parse", "--abbrev-ref", "HEAD"]))
    detached? = branch in [nil, "HEAD"]

    entry = %{
      path: path,
      branch: if(detached?, do: nil, else: branch),
      detached?: detached?,
      head_sha: trimmed(run.(path, ["rev-parse", "HEAD"])),
      unpushed: count(run.(path, ["rev-list", "--count", "HEAD", "--not", "--remotes=origin"])),
      dirty?: trimmed(run.(path, ["status", "--porcelain"])) not in [nil, ""],
      at_risk?: at_risk?
    }

    Map.put(entry, :verdict, verdict(entry))
  end

  @doc """
  The verdict for an audited worktree. Pure.

  Unpushed commits on a detached HEAD outrank unpushed commits on a branch:
  the branch is a ref that survives the directory, and a detached HEAD is not.
  """
  @spec verdict(map()) :: verdict()
  def verdict(%{detached?: true, unpushed: unpushed}) when unpushed > 0, do: :unrecoverable
  def verdict(%{unpushed: unpushed}) when unpushed > 0, do: :unpushed
  def verdict(%{dirty?: true}), do: :uncommitted
  def verdict(_), do: :clean

  @doc "Entries worth acting on, worst first."
  @spec exposed([entry()]) :: [entry()]
  def exposed(entries) do
    entries
    |> Enum.reject(&(&1.verdict == :clean))
    |> Enum.sort_by(&{severity(&1.verdict), not &1.at_risk?, -&1.unpushed, &1.path})
  end

  defp severity(:unrecoverable), do: 0
  defp severity(:unpushed), do: 1
  defp severity(:uncommitted), do: 2
  defp severity(_), do: 3

  # A root under the OS temp dir is swept on a timer; anything else is not.
  # Comparing prefixes rather than naming `/tmp` keeps this true wherever
  # TMPDIR points, which is also how Paths builds the default root.
  @spec at_risk?(String.t()) :: boolean()
  def at_risk?(root) do
    tmp = Path.expand(System.tmp_dir!())
    expanded = Path.expand(root)

    expanded == tmp or String.starts_with?(expanded, tmp <> "/")
  end

  defp worktrees_under(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&git_worktree?/1)

      _ ->
        []
    end
  end

  # A linked worktree carries `.git` as a file pointing at the common dir; a
  # plain clone carries it as a directory. Both are worth auditing.
  defp git_worktree?(path), do: File.exists?(Path.join(path, ".git"))

  # Argv-only, never a shell. A directory that is not a checkout answers with a
  # non-zero status, which every reader below already treats as "no answer".
  defp run_git(path, args) do
    System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
  rescue
    error ->
      Logger.warning("worktree_audit_git_failed",
        path: path,
        reason: Exception.message(error)
      )

      {"", 1}
  end

  defp trimmed({out, 0}) when is_binary(out), do: String.trim(out)
  defp trimmed(_), do: nil

  # A count git could not produce is reported as nothing unpushed rather than
  # as an error: one unreadable worktree must not take the sweep down.
  defp count(result) do
    with out when is_binary(out) <- trimmed(result),
         {n, _rest} <- Integer.parse(out) do
      n
    else
      _ -> 0
    end
  end
end
