defmodule DevIDE.Agents.TerminalTools do
  @moduledoc """
  Narrow agent-facing tmux operations.

  This is the terminal counterpart to `DevIDE.Agents.PreviewTools`: it lets
  external coding agents (Grok, Claude, Codex, opencode) drive DevIDE's tmux
  sessions the way a human would from the CLI — discover live sessions, read a
  pane's scrollback to debug a server, and send keys/commands — without
  arbitrary shell access on the host.

  Every session-scoped tool is guarded to `devide_`-prefixed sessions
  (`DevIDE.Terminals.Tmux.session_name/2`'s shape), so agents can only see and
  touch DevIDE-managed sessions, never unrelated tmux sessions that happen to
  share the host's tmux server.

  Pass `workspace_id` on every call to scope discovery and mutation to one
  workspace's sessions. After applying the built-in `agent_pair` template, use
  `terminal_topology` and target the `agent` pane explicitly.

  Each terminal tool is a `Jido.Action` module under `DevIDE.Agents.TerminalTools.*`,
  invoked through `DevIDE.Agents.ToolAction`: params are schema-validated at
  runtime while the MCP wire shapes (tools/list JSON Schema, error
  structuredContent) stay exactly as before.
  """

  alias DevIDE.Agents.AnnotationTools
  alias DevIDE.Agents.TerminalCommandPolicy

  alias DevIDE.Agents.TerminalTools.{
    AgentPane,
    AgentTranscript,
    Capture,
    CaptureAgent,
    Context,
    Helpers,
    Impl,
    ListSessions,
    PasteAgentText,
    ReportAgentState,
    ReportWorktree,
    SendAgentCommand,
    SendAgentKeys,
    SendCommand,
    SendKeys,
    SetAgentLabel,
    Topology,
    WaitAgentState
  }

  alias DevIDE.Agents.ToolAction
  alias McpCtl.Tool

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
    SendKeys,
    SendCommand,
    SetAgentLabel,
    ReportWorktree,
    ReportAgentState,
    WaitAgentState
  ]

  @by_name Map.new(@actions, &{&1.name(), &1})

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    terminal_defs = Enum.map(@actions, &ToolAction.definition/1)

    annotation_defs =
      AnnotationTools.definitions()
      |> Enum.map(&Tool.put_metadata(&1, Helpers.metadata(&1.name)))

    terminal_defs ++ annotation_defs
  end

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
  defdelegate list_sessions(params \\ %{}), to: Impl
  @doc false
  defdelegate context(params \\ %{}), to: Impl
  @doc false
  defdelegate topology(params), to: Impl
  @doc false
  defdelegate capture(params), to: Impl
  @doc false
  defdelegate agent_pane(params), to: Impl
  @doc false
  defdelegate agent_transcript(params), to: Impl
  @doc false
  defdelegate capture_agent(params), to: Impl
  @doc false
  defdelegate send_agent_keys(params), to: Impl
  @doc false
  defdelegate send_agent_command(params), to: Impl
  @doc false
  defdelegate paste_agent_text(params), to: Impl
  @doc false
  defdelegate send_keys(params), to: Impl
  @doc false
  defdelegate send_command(params), to: Impl
  @doc false
  defdelegate set_agent_label(params), to: Impl
  @doc false
  defdelegate report_agent_state(params), to: Impl
  @doc false
  defdelegate wait_agent_state(params), to: Impl
  @doc false
  defdelegate report_worktree(params), to: Impl
end
