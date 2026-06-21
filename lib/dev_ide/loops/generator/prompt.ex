defmodule DevIDE.Loops.Generator.Prompt do
  @moduledoc """
  Shared prompt construction for `DevIDE.Loops.Generator` adapters.

  Both the Anthropic API adapter and the `claude` CLI adapter ask the model for
  the same thing — a minimal `lib/`-only unified diff that fixes the target
  test — so the system prompt, the source-gathering, and the fence-stripping
  live here rather than being duplicated per transport.
  """

  @system """
  You are fixing ONE failing Elixir/Phoenix test by editing application code.

  Output ONLY a unified git diff that applies cleanly with `git apply` from the
  repository root. No prose, no explanation, no markdown code fences.

  Rules (these are scored — violating them fails the attempt):
    * Edit ONLY files under lib/. NEVER modify anything under test/.
    * Fix the actual defect. Do not hardcode the expected value, weaken or delete
      assertions, or add a bare `rescue`/`catch` that swallows errors.
    * Keep the diff minimal — change only what the fix requires.
  """

  @spec system_prompt() :: String.t()
  def system_prompt, do: @system

  @spec user_prompt(DevIDE.Loops.Generator.context()) :: String.t()
  def user_prompt(ctx) do
    [
      "Target failing test: #{ctx.target}",
      "Round #{Map.get(ctx, :iteration, 1)}.",
      "",
      source_section("FAILING TEST", target_file(ctx)),
      source_section("CODE UNDER TEST (edit here)", lib_file(ctx)),
      feedback_section(Map.get(ctx, :feedback)),
      prior_section(Map.get(ctx, :prior_diff)),
      "",
      "Return the unified diff that fixes the target test."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc """
  Strip a leading/trailing markdown code fence if the model added one anyway,
  and guarantee a single trailing newline — `git apply` rejects a patch whose
  final line has no newline ("corrupt patch").
  """
  @spec strip_fences(String.t()) :: String.t()
  def strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```[a-zA-Z]*\n/, "")
    |> String.replace(~r/\n```$/, "")
    |> String.trim()
    |> then(&(&1 <> "\n"))
  end

  defp source_section(_label, nil), do: nil

  defp source_section(label, {path, contents}),
    do: "#{label} (#{path}):\n```\n#{contents}\n```"

  defp feedback_section(fb) when is_binary(fb) and fb != "",
    do: "FEEDBACK FROM LAST ROUND:\n#{fb}"

  defp feedback_section(_), do: nil

  defp prior_section(diff) when is_binary(diff) and diff != "",
    do: "PRIOR ATTEMPT DIFF (build on it or discard it):\n#{String.slice(diff, 0, 4000)}"

  defp prior_section(_), do: nil

  # `test/foo/bar_test.exs:42` -> read the file
  defp target_file(%{root: root, target: target}) when is_binary(root) do
    read(root, target |> to_string() |> String.split(":") |> hd())
  end

  defp target_file(_), do: nil

  # Map a conventional test path to its lib file: test/dev_ide/foo_test.exs -> lib/dev_ide/foo.ex
  defp lib_file(%{root: root, target: target}) when is_binary(root) do
    rel =
      target
      |> to_string()
      |> String.split(":")
      |> hd()
      |> String.replace_prefix("test/", "lib/")
      |> String.replace_suffix("_test.exs", ".ex")

    read(root, rel)
  end

  defp lib_file(_), do: nil

  defp read(root, rel) do
    path = Path.join(root, rel)

    case File.read(path) do
      {:ok, contents} -> {rel, String.slice(contents, 0, 12_000)}
      _ -> nil
    end
  end
end
