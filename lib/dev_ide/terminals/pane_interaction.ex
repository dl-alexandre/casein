defmodule Casein.Terminals.PaneInteraction do
  @moduledoc """
  Shared policy for how the browser terminal should interact with a focused
  tmux pane — clipboard path format and scroll routing.

  Agent TUIs (Grok, Claude Code, Codex, OpenCode, …) run on the alt screen with
  mouse tracking. They need `@path` file refs and pointer-local SGR wheel, not
  shell-quoted paths or Ghostty emulator scrollback. Detection keys off pane
  `role` and `current_command` so we do not scrape the viewport.
  """

  @agent_role "agent"
  @agent_commands ~w(grok claude codex opencode composer)
  @shell_commands ~w(bash zsh fish sh dash ksh nu fish)

  @type policy :: String.t()

  @doc "Commands treated as agent TUIs (substring match on current_command)."
  @spec agent_commands() :: [String.t()]
  def agent_commands, do: @agent_commands

  @doc """
  Whether a pane/command looks like an interactive agent TUI.
  """
  @spec agent_pane?(term()) :: boolean()
  def agent_pane?(%{} = pane) do
    role = pane_field(pane, :role)
    command = pane_field(pane, :current_command)

    (is_binary(role) and String.downcase(String.trim(role)) == @agent_role) or
      agent_command?(command)
  end

  def agent_pane?(command) when is_binary(command), do: agent_command?(command)
  def agent_pane?(_), do: false

  @doc """
  Clipboard path typing format for a focused pane.

  * `"agent"` — `@/abs/path` file ref
  * `"shell"` — shell-quoted path
  """
  @spec path_format(term()) :: policy()
  def path_format(pane_or_command) do
    if agent_pane?(pane_or_command), do: "agent", else: "shell"
  end

  @doc """
  Scroll routing policy for a focused pane.

  * `"agent"` — wheel/touch → SGR (or key backend) at pointer cell; Shift-select
  * `"shell"` — wheel → emulator scrollback when present; plain drag-select
  """
  @spec scroll_policy(term()) :: policy()
  def scroll_policy(pane_or_command) do
    if agent_pane?(pane_or_command), do: "agent", else: "shell"
  end

  @doc """
  Optional scroll backend for agent mode.

  Defaults to `"sgr_mouse"`. Reserved for future per-agent overrides
  (`"keys_page"` → PageUp/PageDown).
  """
  @spec scroll_backend(term()) :: String.t()
  def scroll_backend(pane_or_command) do
    if agent_pane?(pane_or_command), do: "sgr_mouse", else: "emulator"
  end

  @doc false
  @spec shell_command?(term()) :: boolean()
  def shell_command?(command) when is_binary(command) do
    base =
      command
      |> String.trim()
      |> Path.basename()
      |> String.downcase()

    base in @shell_commands
  end

  def shell_command?(_), do: false

  defp agent_command?(command) when is_binary(command) do
    down = String.downcase(command)
    Enum.any?(@agent_commands, &String.contains?(down, &1))
  end

  defp agent_command?(_), do: false

  defp pane_field(pane, key) when is_map(pane) and is_atom(key) do
    case Map.fetch(pane, key) do
      {:ok, value} -> value
      :error -> Map.get(pane, Atom.to_string(key))
    end
  end
end
