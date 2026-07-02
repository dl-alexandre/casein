defmodule DevIDE.ProposalApply.GitAdapter do
  @moduledoc """
  Local-host `git apply` adapter. Shells out with **argv-style** invocation
  (no shell interpolation), mirroring `DevIDE.Git.LocalAdapter`. This is the
  only module in the codebase permitted to invoke `git apply` — the read-only
  `DevIDE.Proposals` subsystem must never gain a write path (see
  `test/dev_ide/proposals_no_apply_test.exs`).

  `git apply` (without `--reject`) validates every file in a multi-file patch
  before writing any of them, so a single mismatched hunk aborts the whole
  operation with zero files touched — this is what gives `DevIDE.ProposalApply`
  its atomic "all files or none" guarantee for free.
  """

  @behaviour DevIDE.ProposalApply.Adapter

  @impl true
  def check(root, patch_path), do: run(root, ["apply", "--check", patch_path])

  @impl true
  def apply(root, patch_path), do: run(root, ["apply", patch_path])

  # sobelow_skip ["CI.System"]
  defp run(root, args) do
    git = System.find_executable("git")

    cond do
      is_nil(git) ->
        {:error, :git_not_found}

      not File.dir?(root) ->
        {:error, :no_root}

      true ->
        case System.cmd(git, ["-C", root | args], stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, code} -> {:error, {:git_exit, code, String.trim(out)}}
        end
    end
  end
end
