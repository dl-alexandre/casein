defmodule DevIDE.Terminals.ModePolicy do
  @moduledoc """
  Single home for terminal mode policy.

  Decides which sessions may run raw, which mode a session lands in (on
  mount, on session switch, and on channel attach), and whether tmux layout
  mutations are allowed. Pure functions over explicit inputs — no socket,
  no process state — so every consumer (LiveView, channel, components)
  derives the same answer from the same facts.

  Previously these rules were spread across four places:
  `Show.raw_terminal_allowed?/2` (+ a private copy in `TerminalChrome`),
  `TerminalState.session_switch_terminal_mode/2`,
  `Terminals.attachment_policy/2`, and `Info.governed_by_default?/1`.
  """

  alias DevIDE.Terminals.Session.Info

  @type mode :: :governed | :raw

  @local_hosts ["", "local", "localhost"]

  @doc """
  Raw terminals require manual workspace mode on a local host. Everything
  else (review/agent modes, remote hosts) is governed-only.
  """
  @spec raw_terminal_allowed?(atom() | nil, String.t() | nil) :: boolean()
  def raw_terminal_allowed?(:manual, host_id) when host_id in @local_hosts, do: true
  def raw_terminal_allowed?(_workspace_mode, _host_id), do: false

  @doc "Terminal mode for a fresh LiveView mount."
  @spec initial_mode(atom() | nil, String.t() | nil) :: mode()
  def initial_mode(workspace_mode, host_id) do
    if raw_terminal_allowed?(workspace_mode, host_id), do: :raw, else: :governed
  end

  @doc """
  Mode a session switch lands in: governed-by-default sessions (executions,
  agents, remote shells) are always governed; local shells go raw exactly
  when the workspace allows raw terminals.
  """
  @spec session_switch_mode(Info.t(), atom() | nil, String.t() | nil) :: mode()
  def session_switch_mode(%Info{} = info, workspace_mode, host_id) do
    cond do
      Info.governed_by_default?(info) ->
        :governed

      info.kind == :shell and raw_terminal_allowed?(workspace_mode, host_id) ->
        :raw

      true ->
        :governed
    end
  end

  @doc """
  Channel attachment mode: fleet executions are governed regardless of the
  requested mode; shells honor the request. Other kinds (agent) have no
  attachment policy yet — callers must not offer them.
  """
  @spec attachment_mode(Info.t(), mode()) :: {:ok, mode()}
  def attachment_mode(%Info{kind: :execution}, _requested), do: {:ok, :governed}
  def attachment_mode(%Info{kind: :shell}, requested), do: {:ok, requested}

  @doc """
  Tmux layout mutations (new/kill/rename window, split/kill/resize pane,
  templates) are only allowed on the workspace's own shell session — never
  on attached fleet executions or agent sessions.
  """
  @spec tmux_mutations_enabled?(atom()) :: boolean()
  def tmux_mutations_enabled?(:shell), do: true
  def tmux_mutations_enabled?(_kind), do: false
end
