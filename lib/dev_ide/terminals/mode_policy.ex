defmodule DevIDE.Terminals.ModePolicy do
  @moduledoc """
  Single home for terminal mode policy.

  Terminals are raw everywhere. The governed terminal mode (and the
  governed-command execution plane behind it) has been removed, so every
  session — workspace shell, execution, or agent — resolves to `:raw`. The
  remaining policy decides whether raw is *reachable* (local manual by default,
  or everywhere when explicitly configured) and whether tmux layout mutations
  are allowed (only on the workspace shell).

  Pure functions over explicit inputs — no socket, no process state — so every
  consumer (LiveView, channel, components) derives the same answer.
  """

  alias DevIDE.Terminals.Session.Info

  @type mode :: :raw

  @doc """
  Whether a raw terminal can be *reached* from a workspace.

  Raw shell is fail-safe by default: local host + manual workspace mode only.
  Set `:raw_terminal_everywhere` to true for deliberately permissive
  single-user/dev deployments.
  """
  @spec raw_terminal_allowed?(atom() | nil, String.t() | nil) :: boolean()
  def raw_terminal_allowed?(workspace_mode, host_id),
    do: raw_terminal_everywhere?() or (workspace_mode == :manual and local_host?(host_id))

  @doc "Terminals are always raw; retained for callers that still ask."
  @spec raw_default?(atom() | nil, String.t() | nil) :: boolean()
  def raw_default?(_workspace_mode, _host_id), do: true

  @doc "Terminal mode for a fresh LiveView mount — always `:raw`."
  @spec initial_mode(atom() | nil, String.t() | nil) :: mode()
  def initial_mode(_workspace_mode, _host_id), do: :raw

  @doc "Mode a session switch lands in — always `:raw`."
  @spec session_switch_mode(Info.t(), atom() | nil, String.t() | nil) :: mode()
  def session_switch_mode(%Info{}, _workspace_mode, _host_id), do: :raw

  @doc "Channel attachment mode — always `:raw`."
  @spec attachment_mode(Info.t(), mode()) :: {:ok, mode()}
  def attachment_mode(%Info{}, _requested), do: {:ok, :raw}

  @doc """
  Tmux layout mutations (new/kill/rename window, split/kill/resize pane,
  templates) are only allowed on the workspace's own shell session — never
  on attached executions or agent sessions.
  """
  @spec tmux_mutations_enabled?(atom()) :: boolean()
  def tmux_mutations_enabled?(:shell), do: true
  def tmux_mutations_enabled?(_kind), do: false

  defp raw_terminal_everywhere?,
    do: Application.get_env(:dev_ide, :raw_terminal_everywhere, false) == true

  defp local_host?(host_id), do: host_id in ["local", "localhost"]
end
