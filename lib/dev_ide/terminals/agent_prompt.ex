defmodule DevIDE.Terminals.AgentPrompt do
  @moduledoc false

  alias DevIDE.Terminals.{Activity, AgentPane, AgentPromptSender, Telemetry}

  @doc "Terminal-specific telemetry poller measurements."
  @spec periodic_measurements() :: list()
  def periodic_measurements do
    Telemetry.periodic_measurements()
  end

  @doc "True when a tmux window's agent process has been quiet long enough to need attention."
  @spec agent_window_quiet?(map()) :: boolean()
  def agent_window_quiet?(window) do
    Activity.agent_window_quiet?(window)
  end

  @doc "Sends an agent prompt to a tmux pane in small, line-preserving chunks."
  @spec send_agent_prompt(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AgentPromptSender.result()} | {:error, map()}
  defdelegate send_agent_prompt(session, pane, text, opts \\ []),
    to: AgentPromptSender,
    as: :send_prompt

  @doc "Finds the role-marked agent pane for a tmux session."
  @spec find_agent_pane(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  defdelegate find_agent_pane(session, opts \\ []), to: AgentPane, as: :find

  @doc "Sends an agent prompt to the role-marked agent pane."
  @spec send_agent_prompt_to_agent_pane(String.t(), String.t(), keyword()) ::
          {:ok, AgentPromptSender.result()} | {:error, map()}
  defdelegate send_agent_prompt_to_agent_pane(session, text, opts \\ []),
    to: AgentPromptSender,
    as: :send_to_agent_pane
end
