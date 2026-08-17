defmodule Casein.Terminals.AgentScreenStatus do
  @moduledoc """
  Pure, conservative fallback classifier for the live bottom of an agent pane.

  This is weaker evidence than agent reports, liveness, and transcript shape. It
  deliberately returns screen observations (`:permission_prompt` / `:working`),
  not semantic report-only states such as `:blocked` or `:errored`. Callers must
  preserve that provenance when projecting an observation into UI state.

  Each pattern class uses its own bounded non-empty tail. Permission dialogs
  occupy more rows, while activity footer hints live at the very bottom. A
  permission phrase must also be paired with a standalone interactive choice;
  this prevents pasted prose about a prompt from matching itself.
  """

  @attention_lines 8
  @working_lines 3

  @ansi_regex ~r/\e(?:\][^\a\e]*(?:\a|\e\\)|\[[0-?]*[ -\/]*[@-~])/

  @permission_patterns [
    ~r/^\s*(?:[!⚠?]\s*)?permission (?:is )?(?:required|needed)\b/i,
    ~r/^\s*(?:[!⚠?]\s*)?(?:approval|confirmation) (?:is )?(?:required|needed)\b/i,
    ~r/^\s*.{0,48}\bneeds? (?:your )?(?:approval|permission)\s*[?!.:]?\s*$/i,
    ~r/^\s*(?:do you want to|would you like to) (?:allow|approve|run|execute|proceed)\b/i,
    ~r/^\s*(?:allow|approve) (?:this|the) (?:action|command|tool)\b/i
  ]

  @choice_patterns [
    ~r/^\s*(?:[❯›>✔○●]\s*)?(?:\d+[.)]\s*)?(?:allow|approve|yes|deny|reject)(?:\s+(?:once|always|for (?:this|the) session|and don['’]?t ask again))?\s*$/iu,
    ~r/(?:\[[yY]\/[nN]\]|\([yY]\/[nN]\)|\[[yY]\/[nN]\/[aA]\])/,
    ~r/^\s*(?:[❯›>]\s*)?(?:submit\s*\/\s*skip|yes,? and don['’]?t ask again)\s*$/iu
  ]

  @working_patterns [
    ~r/\besc to (?:interrupt|cancel)\b/i,
    ~r/\bctrl[+-]c to (?:interrupt|cancel|stop)\b/i,
    ~r/^\s*[│┆]?\s*[⠀-⣿]\s*(?:thinking|working|running|generating|processing)\b/iu
  ]

  @type status :: :permission_prompt | :working | :unknown

  @doc "Classify a captured pane without I/O. No match is always `:unknown`."
  @spec classify(String.t() | term()) :: status()
  def classify(screen) when is_binary(screen) do
    lines = recent_nonempty_lines(screen)
    attention = Enum.take(lines, -@attention_lines)

    cond do
      permission_prompt?(attention) -> :permission_prompt
      matches_any?(Enum.take(lines, -@working_lines), @working_patterns) -> :working
      true -> :unknown
    end
  end

  def classify(_screen), do: :unknown

  defp recent_nonempty_lines(screen) do
    @ansi_regex
    |> Regex.replace(screen, "")
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case String.trim(line) do
        "" -> acc
        trimmed -> [trimmed | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp permission_prompt?(lines) do
    matches_any?(lines, @permission_patterns) and matches_any?(lines, @choice_patterns)
  end

  defp matches_any?(lines, patterns) do
    Enum.any?(lines, fn line -> Enum.any?(patterns, &Regex.match?(&1, line)) end)
  end
end
