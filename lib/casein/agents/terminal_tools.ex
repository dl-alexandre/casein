defmodule Casein.Agents.TerminalTools do
  @moduledoc """
  Narrow agent-facing tmux operations.

  This is the terminal counterpart to `Casein.Agents.PreviewTools`: it lets
  external coding agents (Grok, Claude, Codex, opencode) drive Casein's tmux
  sessions the way a human would from the CLI — discover live sessions, read a
  pane's scrollback to debug a server, and send keys/commands — without
  arbitrary shell access on the host.

  Every session-scoped tool is guarded to `casein_`-prefixed sessions
  (`Casein.Terminals.Tmux.session_name/2`'s shape), so agents can only see and
  touch Casein-managed sessions, never unrelated tmux sessions that happen to
  share the host's tmux server.

  Pass `workspace_id` on every call to scope discovery and mutation to one
  workspace's sessions. After applying the built-in `agent_pair` template, use
  `terminal_topology` and target the `agent` pane explicitly.

  Each terminal tool is a `Jido.Action` module under `Casein.Agents.TerminalTools.*`,
  invoked through `Casein.Agents.ToolAction`: params are schema-validated at
  runtime while the MCP wire shapes (tools/list JSON Schema, error
  structuredContent) stay exactly as before.
  """

  alias Casein.Agents.AnnotationTools
  alias Casein.Agents.TerminalCommandPolicy

  alias Casein.Agents.TerminalTools.{
    AgentPane,
    AgentTranscript,
    Capture,
    CaptureAgent,
    Context,
    GateReport,
    ListSessions,
    OpenFileInPane,
    PasteAgentText,
    RequestClarification,
    ReportAgentState,
    ReportWorktree,
    SendAgentCommand,
    SendAgentKeys,
    SendCommand,
    SendKeys,
    SetAgentLabel,
    Topology,
    WaitAgentState,
    WorkspaceDigest
  }

  alias Casein.Agents.TerminalTools.Impl.{Agent, Command, Report, Session}
  alias Casein.Agents.ToolAction

  @type tool :: McpCtl.Tool.t()

  @actions [
    ListSessions,
    Context,
    Topology,
    Capture,
    AgentPane,
    CaptureAgent,
    AgentTranscript,
    SendAgentKeys,
    SendAgentCommand,
    PasteAgentText,
    RequestClarification,
    SendKeys,
    SendCommand,
    OpenFileInPane,
    SetAgentLabel,
    ReportWorktree,
    ReportAgentState,
    WaitAgentState,
    WorkspaceDigest,
    GateReport
  ]

  @by_name Map.new(@actions, &{&1.name(), &1})

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    terminal_defs =
      @actions
      |> Enum.reject(&hidden_action?/1)
      |> Enum.map(&ToolAction.definition/1)

    terminal_defs ++ AnnotationTools.definitions()
  end

  # workspace_digest is feature-flagged (CASEIN_WORKSPACE_DIGEST): hide it from
  # tools/list until enabled. Like the tool-search meta-tools, it stays callable
  # by name — the flag only changes what is advertised.
  defp hidden_action?(WorkspaceDigest),
    do: not Application.get_env(:casein, :workspace_digest, false)

  defp hidden_action?(_action), do: false

  @doc "Dispatch a named agent terminal tool."
  @spec invoke(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, params) when is_map(params) do
    with :ok <- TerminalCommandPolicy.authorize(tool_name, params) do
      case Map.fetch(@by_name, tool_name) do
        {:ok, action} ->
          ToolAction.invoke(action, params)

        :error ->
          AnnotationTools.invoke(tool_name, params)
      end
    end
  end

  @doc false
  defdelegate list_sessions(params \\ %{}), to: Session
  @doc false
  defdelegate context(params \\ %{}), to: Session
  @doc false
  defdelegate topology(params), to: Session
  @doc false
  defdelegate capture(params), to: Session
  @doc false
  defdelegate agent_pane(params), to: Agent
  @doc false
  defdelegate agent_transcript(params), to: Agent
  @doc false
  defdelegate capture_agent(params), to: Agent
  @doc false
  defdelegate send_agent_keys(params), to: Agent
  @doc false
  defdelegate send_agent_command(params), to: Agent
  @doc false
  defdelegate paste_agent_text(params), to: Agent
  @doc false
  defdelegate request_clarification(params), to: Agent
  @doc false
  defdelegate send_keys(params), to: Command
  @doc false
  defdelegate send_command(params), to: Command
  @doc false
  defdelegate open_file_in_pane(params), to: Command
  @doc false
  defdelegate set_agent_label(params), to: Agent
  @doc false
  defdelegate report_agent_state(params), to: Agent
  @doc false
  defdelegate wait_agent_state(params), to: Agent
  @doc false
  defdelegate report_worktree(params), to: Report
  @doc false
  defdelegate workspace_digest(params), to: Session
  @doc false
  defdelegate gate_report(params), to: Report
end
