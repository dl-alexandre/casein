defmodule Casein.Terminals.TuiSurface do
  @moduledoc """
  Classify which agent TUI surface a pane capture is showing.

  `terminal_paste_agent_text` / `terminal_send_command` treat `submitted: true`
  as "the conversation received this text". Claude Code's agents view accepts
  the same keystrokes into "describe a task for a new session" and silently
  spawns a second agent. This module names the surface so those tools can
  refuse a non-conversation write instead of reporting a false submit.
  """

  @type surface :: :conversation | :agents_view | :menu | :unknown

  @agents_view_needles [
    "describe a task for a new session",
    "describe a task for a new agent",
    "describe a task for a new background"
  ]

  @menu_needles [
    "do you want to proceed",
    "allow this action",
    "always allow",
    "select a model"
  ]

  @conversation_needles [
    "esc to interrupt",
    "esc interrupt",
    "ctrl+c to stop"
  ]

  @doc "Classify a captured pane tail into a named TUI surface."
  @spec classify(term()) :: surface()
  def classify(text) when is_binary(text) do
    haystack = String.downcase(text)

    cond do
      contains_any?(haystack, @agents_view_needles) -> :agents_view
      contains_any?(haystack, @menu_needles) -> :menu
      contains_any?(haystack, @conversation_needles) -> :conversation
      true -> :unknown
    end
  end

  def classify(_), do: :unknown

  @doc "Wire name for a surface (`\"agents_view\"`, …)."
  @spec name(surface()) :: String.t()
  def name(surface) when surface in [:conversation, :agents_view, :menu, :unknown] do
    Atom.to_string(surface)
  end

  def name(_), do: "unknown"

  @doc "Surfaces that may receive a conversation paste/send by default."
  @spec conversation?(surface()) :: boolean()
  def conversation?(:conversation), do: true
  def conversation?(:unknown), do: true
  def conversation?(_), do: false

  @doc "`submitted: true` is only honest for a conversation (or unclassified) surface."
  @spec conversation_submit?(surface()) :: boolean()
  def conversation_submit?(surface), do: conversation?(surface)

  @doc """
  Collapse a PaneSubmit `submitted` flag against the surface that received it.

  A screen change (or hook) on the agents view is not the conversation taking
  the text, so `true` becomes `false`. Other values pass through.
  """
  @spec honest_submitted(surface(), boolean() | nil) :: boolean() | nil
  def honest_submitted(surface, true) do
    conversation_submit?(surface)
  end

  def honest_submitted(_surface, submitted), do: submitted

  defp contains_any?(haystack, needles) do
    Enum.any?(needles, &String.contains?(haystack, &1))
  end
end
