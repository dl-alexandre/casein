defmodule DevIDE.Agents.TerminalOutputFormat do
  @moduledoc """
  Normalizes tmux scrollback for agent-facing terminal tools.

  Strips ANSI escape sequences by default so MCP clients receive plain text
  with fewer tokens. Callers may opt in to raw output with `ansi: true`.
  """

  @ansi_regex ~r/\e\[[0-?]*[ -\/]*[@-~]/

  @doc """
  Format scrollback for agent consumption.

  Options:
    * `:ansi` — keep ANSI escape codes (default `false`)
  """
  @spec format(String.t(), keyword()) :: String.t()
  def format(output, opts \\ []) when is_binary(output) do
    if Keyword.get(opts, :ansi, false) == true do
      output
    else
      output
      |> strip_ansi()
      |> normalize_newlines()
    end
  end

  defp strip_ansi(text), do: Regex.replace(@ansi_regex, text, "")

  defp normalize_newlines(text), do: String.replace(text, "\r\n", "\n")
end
