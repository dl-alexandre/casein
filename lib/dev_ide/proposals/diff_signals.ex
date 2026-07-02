defmodule DevIDE.Proposals.DiffSignals do
  @moduledoc """
  Content-level anti-gaming signals ported from the deleted `Loops` subsystem
  (`DevIDE.Loops.Sandbox.analyze_diff/1`, removed 2026-06-26). Loops let an
  unaudited generator mutate and execute code off the request path; this is
  the one piece of it worth keeping — a diff touching `test/` is exactly how
  a self-applying agent could quietly make itself look correct.

  Used as a hard, unconditional veto in `DevIDE.Proposals.AutoApply` (never
  auto-applied, always falls back to human review) rather than a scored
  signal, because there is no human-in-the-loop feedback step to weigh it
  against here.
  """

  @doc "Whether a unified diff adds or removes anything under `test/`."
  @spec touched_test_files?(String.t()) :: boolean()
  def touched_test_files?(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.any?(&test_path_header?/1)
  end

  defp test_path_header?("--- " <> rest), do: test_path?(rest)
  defp test_path_header?("+++ " <> rest), do: test_path?(rest)
  defp test_path_header?(_), do: false

  defp test_path?(header) do
    header
    |> String.split("\t", parts: 2)
    |> List.first()
    |> String.trim()
    |> strip_ab_prefix()
    |> String.starts_with?("test/")
  end

  defp strip_ab_prefix("a/" <> p), do: p
  defp strip_ab_prefix("b/" <> p), do: p
  defp strip_ab_prefix(p), do: p
end
