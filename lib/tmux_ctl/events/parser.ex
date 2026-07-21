defmodule TmuxCtl.Events.Parser do
  @moduledoc """
  Pure parser for tmux control-mode (`-C`) notification lines.

  Skips `%begin`…`%end`/`%error` command blocks (caller tracks `in_block?`),
  drops high-volume `%output` / `%extended-output` / `%pause` by binary prefix,
  and folds `unlinked-*` variants onto the same event types as their linked
  counterparts. Never raises on malformed input.
  """

  @type event_type ::
          :sessions_changed
          | :session_renamed
          | :session_window_changed
          | :window_add
          | :window_close
          | :window_renamed
          | :window_pane_changed
          | :layout_change
          | :pane_mode_changed
          | :exit

  @type event :: %{
          type: event_type(),
          server: String.t() | nil,
          session_id: String.t() | nil,
          window_id: String.t() | nil,
          pane_id: String.t() | nil,
          raw: binary()
        }

  @type parse_result :: {:event, event()} | :ignore | :begin | :end_block

  @doc """
  Parse one control-mode line (no trailing newline).

  Returns `{:event, event}`, `:ignore`, `:begin`, or `:end_block`.
  """
  @spec parse_line(binary()) :: parse_result()
  def parse_line(line) when is_binary(line) do
    cond do
      starts_with_any?(line, ["%output", "%extended-output", "%pause"]) ->
        :ignore

      String.starts_with?(line, "%begin") ->
        :begin

      String.starts_with?(line, "%end") or String.starts_with?(line, "%error") ->
        :end_block

      true ->
        parse_notification(line)
    end
  rescue
    _ -> :ignore
  end

  def parse_line(_), do: :ignore

  defp parse_notification(line) do
    case String.split(line, " ", parts: 4) do
      ["%sessions-changed" | _] ->
        event(:sessions_changed, line)

      ["%session-renamed", session_id | _rest] ->
        event(:session_renamed, line, session_id: session_id)

      ["%session-window-changed", session_id, window_id | _] ->
        event(:session_window_changed, line, session_id: session_id, window_id: window_id)

      ["%window-add", window_id | _] ->
        event(:window_add, line, window_id: window_id)

      ["%unlinked-window-add", window_id | _] ->
        event(:window_add, line, window_id: window_id)

      ["%window-close", window_id | _] ->
        event(:window_close, line, window_id: window_id)

      ["%unlinked-window-close", window_id | _] ->
        event(:window_close, line, window_id: window_id)

      ["%window-renamed", window_id | _] ->
        event(:window_renamed, line, window_id: window_id)

      ["%unlinked-window-renamed", window_id | _] ->
        event(:window_renamed, line, window_id: window_id)

      ["%window-pane-changed", window_id, pane_id | _] ->
        event(:window_pane_changed, line, window_id: window_id, pane_id: pane_id)

      ["%layout-change", window_id | _] ->
        event(:layout_change, line, window_id: window_id)

      ["%pane-mode-changed", pane_id | _] ->
        event(:pane_mode_changed, line, pane_id: pane_id)

      ["%exit" | _] ->
        event(:exit, line)

      # Client-local notifications have no topology impact for our consumers.
      ["%client-session-changed" | _] ->
        :ignore

      ["%client-detached" | _] ->
        :ignore

      _ ->
        :ignore
    end
  end

  defp event(type, raw, fields \\ []) do
    {:event,
     %{
       type: type,
       server: nil,
       session_id: Keyword.get(fields, :session_id),
       window_id: Keyword.get(fields, :window_id),
       pane_id: Keyword.get(fields, :pane_id),
       raw: raw
     }}
  end

  defp starts_with_any?(line, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(line, &1))
  end
end
