defmodule Casein.Terminals.ModeBoundary do
  @moduledoc false

  alias Casein.Terminals.ModePolicy
  alias Casein.Terminals.Session.Info

  @doc """
  Determines the effective attachment mode for a session. Always `:raw`.
  """
  @spec attachment_policy(Info.t(), :raw) :: {:ok, :raw}
  defdelegate attachment_policy(info, requested), to: ModePolicy, as: :attachment_mode

  @doc "True when raw terminal access is allowed for the workspace/host pair."
  @spec raw_terminal_allowed?(String.t(), String.t() | nil) :: boolean()
  def raw_terminal_allowed?(workspace_id, host_id) do
    Casein.Terminals.Boundary.raw_allowed?(workspace_id, host_id)
  end

  @doc "Authorizes raw terminal access through the terminal boundary policy."
  @spec authorize_raw_terminal(String.t(), keyword()) :: :ok | {:error, term()}
  def authorize_raw_terminal(workspace_id, opts) do
    Casein.Terminals.Boundary.authorize_raw(workspace_id, opts)
  end

  @doc "Formats a terminal boundary reason for clients."
  @spec terminal_boundary_reason(term()) :: String.t()
  def terminal_boundary_reason(reason) do
    Casein.Terminals.Boundary.format_reason(reason)
  end

  @doc "True when raw terminal mode is reachable for a workspace mode/host pair."
  @spec raw_terminal_mode_allowed?(atom() | nil, String.t() | nil) :: boolean()
  def raw_terminal_mode_allowed?(workspace_mode, host_id) do
    ModePolicy.raw_terminal_allowed?(workspace_mode, host_id)
  end

  @doc "True when the initial terminal should default to raw mode."
  @spec raw_terminal_default?(atom() | nil, String.t() | nil) :: boolean()
  def raw_terminal_default?(workspace_mode, host_id) do
    ModePolicy.raw_default?(workspace_mode, host_id)
  end

  @doc "Initial terminal mode for a workspace mode/host pair."
  @spec initial_terminal_mode(atom() | nil, String.t() | nil) :: ModePolicy.mode()
  def initial_terminal_mode(workspace_mode, host_id) do
    ModePolicy.initial_mode(workspace_mode, host_id)
  end

  @doc "Terminal mode to use when switching to a session."
  @spec session_switch_terminal_mode(term(), atom() | nil, String.t() | nil) :: atom()
  def session_switch_terminal_mode(info, workspace_mode, host_id) do
    ModePolicy.session_switch_mode(info, workspace_mode, host_id)
  end

  @doc "True when tmux layout mutations are allowed for a session kind."
  @spec tmux_mutations_enabled?(atom() | term()) :: boolean()
  defdelegate tmux_mutations_enabled?(kind), to: ModePolicy
end
