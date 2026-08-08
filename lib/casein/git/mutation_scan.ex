defmodule Casein.Git.MutationScan do
  @moduledoc """
  Decide whether a shell command line would write a git working tree or index.

  Pure text analysis, used by `Casein.Terminals.SharedWorktreeGuard` to decide
  whether a send is worth a topology lookup. It answers one question — *does this
  write the tree?* — and deliberately not "is this dangerous": `git push` and
  `git fetch` are consequential but touch refs, not the tree two panes are
  fighting over.

  ## What counts

  The subcommands that write the index or the working copy: `add`, `am`,
  `apply`, `checkout`, `cherry-pick`, `clean`, `commit`, `merge`, `mv`, `pull`,
  `rebase`, `reset`, `restore`, `revert`, `rm`, `stash`, `switch`. Plus `branch`
  when it carries a delete/move/force flag, which can drop the branch another
  pane is sitting on.

  Everything else passes, including `status`, `log`, `diff`, `push`, `fetch`,
  plain `git branch`, `worktree`, and `config`.

  ## What it will not catch

  A git command hidden inside another program — `bash -c 'git reset --hard'`,
  a `make` target, a script — reads as that program, not as git. This is a guard
  against the accident (an orchestrator driving the wrong pane), not against a
  determined caller; a caller that wants past it has an explicit escape hatch
  and does not need to smuggle.

  The bias runs the other way too: it errs toward *finding* a mutation, because
  a false positive costs one flag and a false negative costs a corrupted index.
  """

  @typedoc "A git invocation that writes the tree, and the directory it writes."
  @type mutation :: %{
          command: String.t(),
          subcommand: String.t(),
          dir: String.t() | nil
        }

  # Subcommands that write the index or the working tree.
  @tree_writing ~w(
    add am apply checkout cherry-pick clean commit merge mv
    pull rebase reset restore revert rm stash switch
  )

  # `git branch` only writes when it drops or moves a ref.
  @branch_writing_flags ~w(-d -D -m -M -c -C -f --delete --move --copy --force)

  # Leading noise before the actual program: env assignments and wrappers that
  # exec through to their argument.
  @passthrough ~w(env nohup time exec command builtin)

  @doc """
  Find the first tree-writing git invocation in a command line.

  Returns `{:mutation, mutation}` or `:none`. `dir` is the `-C` / `--work-tree`
  argument when one is present — the tree that would actually be written, which
  is not always the pane's own.
  """
  @spec scan(String.t() | term()) :: {:mutation, mutation()} | :none
  def scan(command) when is_binary(command) do
    command
    |> segments()
    |> Enum.find_value(:none, &scan_segment/1)
  end

  def scan(_command), do: :none

  @doc "Whether the command line writes a git tree at all."
  @spec mutation?(String.t() | term()) :: boolean()
  def mutation?(command), do: scan(command) != :none

  ## Internals

  # Split on shell separators so `cd x && git reset` is seen as two commands.
  # Anchoring on the *first* token of each segment is what keeps `echo "git
  # reset --hard"` from reading as a mutation: its first token is `echo`.
  defp segments(command) do
    command
    # `&&` and `||` fall out of the single-character class as two splits with an
    # empty segment between them, which `trim` removes.
    |> String.split(~r/[;\n|&]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp scan_segment(segment) do
    case segment |> tokenize() |> strip_prefix() do
      [program | rest] ->
        if git?(program), do: classify(segment, rest), else: nil

      [] ->
        nil
    end
  end

  defp tokenize(segment) do
    # Quotes only matter here for keeping a quoted path in one piece; the
    # subcommand itself is never quoted in practice.
    Regex.scan(~r/"[^"]*"|'[^']*'|\S+/, segment)
    |> Enum.map(fn [token] -> unquote_token(token) end)
  end

  defp unquote_token(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_token(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp unquote_token(token), do: token

  defp strip_prefix([token | rest] = tokens) do
    cond do
      String.contains?(token, "=") and not String.starts_with?(token, "-") -> strip_prefix(rest)
      token in @passthrough -> strip_prefix(rest)
      true -> tokens
    end
  end

  defp strip_prefix([]), do: []

  defp git?(program), do: program == "git" or String.ends_with?(program, "/git")

  # Walk git's global options to find both the subcommand and any redirection of
  # which tree is written. `git -C <other> commit` from a shared pane is not a
  # mutation *of that pane's* worktree, and blocking it would make the guard
  # wrong in exactly the case the repo's own scripts hit constantly.
  defp classify(segment, tokens), do: classify(segment, tokens, nil)

  defp classify(segment, ["-C", dir | rest], _dir), do: classify(segment, rest, dir)
  defp classify(segment, ["--work-tree", dir | rest], _dir), do: classify(segment, rest, dir)

  defp classify(segment, ["--work-tree=" <> dir | rest], _dir), do: classify(segment, rest, dir)

  defp classify(segment, ["-c", _config | rest], dir), do: classify(segment, rest, dir)

  defp classify(segment, [token | rest], dir) do
    if String.starts_with?(token, "-") do
      classify(segment, rest, dir)
    else
      subcommand_mutation(segment, token, rest, dir)
    end
  end

  defp classify(_segment, [], _dir), do: nil

  defp subcommand_mutation(segment, subcommand, rest, dir) do
    cond do
      subcommand in @tree_writing ->
        {:mutation, %{command: segment, subcommand: subcommand, dir: dir}}

      subcommand == "branch" and Enum.any?(rest, &(&1 in @branch_writing_flags)) ->
        {:mutation, %{command: segment, subcommand: "branch", dir: dir}}

      true ->
        nil
    end
  end
end
