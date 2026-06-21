defmodule DevIDE.Loops.Generator.ClaudeCli do
  @moduledoc """
  `DevIDE.Loops.Generator` backed by the authenticated `claude` CLI — no API key
  required (it reuses the CLI's own login on the box).

  Runs `claude -p <prompt> --output-format text --model <model>` headlessly and
  returns the printed unified diff. The same prompt as the API adapter (shared
  via `DevIDE.Loops.Generator.Prompt`) carries the test + code under it, so the
  CLI is run in an empty scratch directory — it never needs to touch the loop's
  worktree, and the deterministic `Sandbox` still measures the result.

  Config (`config :dev_ide, DevIDE.Loops, ...`):

    * `:cli_bin` — path/name of the binary (default `"claude"`)
    * `:cli_model` — `--model` value (default `"claude-opus-4-8"`)
    * `:cli_runner` — `fun(args, opts) -> {output, status}` (tests inject a stub)
  """
  @behaviour DevIDE.Loops.Generator

  alias DevIDE.Loops.Generator.Prompt

  @default_model "claude-opus-4-8"

  @impl true
  def generate(ctx) do
    args = [
      "-p",
      Prompt.user_prompt(ctx),
      "--output-format",
      "text",
      "--model",
      model(),
      "--append-system-prompt",
      Prompt.system_prompt()
    ]

    dir = scratch_dir()

    try do
      case runner().(args, cd: dir) do
        {output, 0} -> {:ok, %{diff: Prompt.strip_fences(output), notes: "claude-cli"}}
        {output, status} -> {:error, {:claude_cli, status, truncate(output)}}
      end
    rescue
      error -> {:error, {:claude_cli_failed, error}}
    after
      File.rm_rf(dir)
    end
  end

  defp scratch_dir do
    dir = Path.join(System.tmp_dir!(), "devide-cligen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp runner do
    case config()[:cli_runner] do
      fun when is_function(fun, 2) -> fun
      _ -> &System.cmd(bin(), &1, &2)
    end
  end

  defp bin, do: config()[:cli_bin] || "claude"
  defp model, do: config()[:cli_model] || @default_model
  defp config, do: Application.get_env(:dev_ide, DevIDE.Loops, [])

  defp truncate(output) when is_binary(output), do: String.slice(output, 0, 500)
  defp truncate(output), do: inspect(output)
end
