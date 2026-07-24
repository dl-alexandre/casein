defmodule DevIDE.Terminals.Themes do
  @moduledoc false

  alias DevIDE.Terminals.{SyncOutput, Theme}

  @doc "True when a terminal theme preset id is selectable."
  @spec valid_terminal_theme_preset?(String.t()) :: boolean()
  def valid_terminal_theme_preset?(preset_id) do
    Theme.valid_preset?(preset_id)
  end

  @doc "JSON-safe terminal theme bundle for LiveView and browser clients."
  @spec terminal_theme_client_bundle(String.t() | nil) :: map()
  def terminal_theme_client_bundle(preset_id \\ nil) do
    Theme.client_bundle(preset_id)
  end

  @doc "Loads the renderer terminal theme bundle for a preset id."
  @spec terminal_theme_bundle(String.t() | nil) :: map()
  def terminal_theme_bundle(preset_id \\ nil) do
    Theme.load_bundle(preset_id)
  end

  @doc "Selects the active terminal theme for a color scheme."
  @spec active_terminal_theme(map(), Theme.scheme()) :: term()
  def active_terminal_theme(theme_bundle, scheme) do
    Theme.active(theme_bundle, scheme)
  end

  @doc "Rewrites terminal PTY color query responses for the active theme."
  @spec rewrite_terminal_pty_write(binary(), term()) :: binary()
  def rewrite_terminal_pty_write(data, theme) do
    Theme.rewrite_pty_write(data, theme)
  end

  @doc "Tracks DEC 2026 synchronized-output state after a PTY chunk."
  @spec terminal_sync_output_active_after?(binary(), boolean()) :: boolean()
  def terminal_sync_output_active_after?(binary, current?) do
    SyncOutput.active_after?(binary, current?)
  end
end
