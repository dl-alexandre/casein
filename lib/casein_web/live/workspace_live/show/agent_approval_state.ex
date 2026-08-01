defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovalState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  def assign_pending_count(socket) do
    count =
      length(socket.assigns[:codex_pending_requests] || []) +
        length(socket.assigns[:grok_permission_requests] || [])

    assign(socket, :agent_pending_approval_count, count)
  end
end
