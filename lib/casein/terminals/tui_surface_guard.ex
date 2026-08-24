defmodule Casein.Terminals.TuiSurfaceGuard do
  @moduledoc """
  Refuse a paste/send that would land on a non-conversation TUI surface.

  Claude Code's agents view accepts the same Enter that a conversation
  composer does, but it creates a new background agent instead of briefing
  the intended one. `submitted: true` then lies. This answers at the write:
  capture the pane, name the surface, and refuse unless the caller opted in.
  """

  alias Casein.Terminals
  alias Casein.Terminals.TuiSurface

  @escape_hatch "allow_non_conversation"
  @capture_lines 40

  @doc """
  Check the pane that is about to receive a paste or command.

  Returns `{:ok, surface}` when the write may proceed, or `{:error, payload}`
  naming the detected surface. `allow_non_conversation: true` skips the
  refusal so a caller can deliberately drive a menu or agents view.
  """
  @spec check(String.t(), String.t() | nil, keyword()) ::
          {:ok, TuiSurface.surface()} | {:error, map()}
  def check(session, pane_id, opts \\ [])

  def check(session, pane_id, opts)
      when is_binary(session) and is_binary(pane_id) and pane_id != "" do
    surface = observe(session, pane_id, opts)

    if Keyword.get(opts, :allow_non_conversation, false) or TuiSurface.conversation?(surface) do
      {:ok, surface}
    else
      {:error, refusal(session, pane_id, surface)}
    end
  end

  def check(_session, _pane_id, _opts), do: {:ok, :unknown}

  @doc "Capture and classify the pane's current tail."
  @spec observe(String.t(), String.t(), keyword()) :: TuiSurface.surface()
  def observe(session, pane_id, opts \\ [])

  def observe(session, pane_id, opts)
      when is_binary(session) and is_binary(pane_id) and pane_id != "" do
    tmux = Keyword.get(opts, :tmux, default_tmux())

    session
    |> tmux.capture_scrollback(target: pane_id, ansi: false, lines: @capture_lines)
    |> TuiSurface.classify()
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  def observe(_session, _pane_id, _opts), do: :unknown

  defp refusal(session, pane_id, surface) do
    name = TuiSurface.name(surface)

    %{
      error: :non_conversation_surface,
      refused: true,
      safe_to_mutate: false,
      session: session,
      pane: pane_id,
      surface: name,
      message:
        "Refused: pane #{pane_id} is showing the #{human_surface(surface)}, not the " <>
          "conversation. A paste or send would not reach the intended agent — on the " <>
          "agents view it lands in \"describe a task for a new session\" and spawns a " <>
          "second independent agent.",
      remedy:
        "Switch the TUI back to the conversation, then retry. If you really mean to " <>
          "drive this surface, re-send with `#{@escape_hatch}: true`.",
      escape_hatch: @escape_hatch
    }
  end

  defp human_surface(:agents_view), do: "agents view"
  defp human_surface(:menu), do: "menu"
  defp human_surface(other), do: TuiSurface.name(other)

  defp default_tmux, do: Terminals.tmux_adapter()
end
