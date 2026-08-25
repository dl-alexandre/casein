defmodule Casein.Agents.JidoSkills.Parity do
  @moduledoc false

  @matrix [
    %{
      capability: :inspect,
      skill: "inspect",
      actions: ~w(code_read code_search),
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :patch,
      skill: "patch",
      actions: ~w(code_apply_patch),
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :verify,
      skill: "approved-verify",
      actions: ~w(code_exec),
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :git,
      skill: "git-inspect",
      actions: ~w(git_status git_diff),
      jido: :not_yet_supported,
      opencode: :supported,
      first_release: :not_yet_supported
    },
    %{
      capability: :human_input,
      skill: "human-input",
      actions: ~w(request_clarification request_human_input),
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :task_control,
      skill: "task-control",
      actions: ~w(task_wait task_cancel),
      jido: :not_yet_supported,
      opencode: :supported,
      first_release: :not_yet_supported
    },
    %{
      capability: :cancel_retry_resume,
      skill: nil,
      actions: [],
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :progress_evidence,
      skill: "progress",
      actions: ~w(report_progress report_result handoff_evidence),
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :provider_unavailable,
      skill: nil,
      actions: [],
      jido: :supported,
      opencode: :supported,
      first_release: :supported
    },
    %{
      capability: :tui_runtime,
      skill: nil,
      actions: ~w(terminal_send_keys terminal_capture preview_open),
      jido: :runtime_specific,
      opencode: :supported,
      first_release: :runtime_specific
    }
  ]

  @spec matrix() :: [map()]
  def matrix, do: @matrix

  @spec capabilities() :: [atom()]
  def capabilities, do: Enum.map(@matrix, & &1.capability)
end
