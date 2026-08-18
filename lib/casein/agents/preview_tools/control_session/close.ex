defmodule Casein.Agents.PreviewTools.ControlSession.Close do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession.Shared
  alias Casein.PreviewControl
  alias Casein.PreviewPanes

  @doc "Close a preview control session."
  @spec close(map() | integer()) :: {:ok, map()} | {:error, term()}
  def close(%{"session_id" => id}),
    do: with({:ok, id} <- Shared.parse_id(id), do: do_close(id))

  def close(%{session_id: id}),
    do: with({:ok, id} <- Shared.parse_id(id), do: do_close(id))

  def close(%{"pane_id" => pane_id} = params) when is_binary(pane_id) and pane_id != "",
    do: do_close_pane(pane_id, Map.get(params, "tmux_session"))

  def close(%{pane_id: pane_id} = params) when is_binary(pane_id) and pane_id != "",
    do: do_close_pane(pane_id, Map.get(params, :tmux_session))

  def close(id) when is_integer(id), do: do_close(id)

  def close(_params), do: {:error, {:missing_argument, "session_id or pane_id"}}

  defp do_close(session_id) do
    maybe_kill_preview_pane(session_id)

    with {:ok, session} <- PreviewControl.close_session(session_id) do
      {:ok, %{session_id: session.id, status: session.status}}
    end
  end

  defp do_close_pane(pane_id, tmux_session) do
    case PreviewPanes.get_by_pane(pane_id) do
      %{control_session_id: session_id, tmux_session: registered_tmux_session} = registration ->
        # A registration can name a pane Casein does not own — a plain shell it
        # bound before casein#1001 was fixed. Killing that pane would settle a
        # disagreement about whose pane it is by destroying the operator's shell,
        # so release the binding and leave tmux alone.
        kill_result =
          if Shared.pane_kind(registration) == "non_preview_shell" do
            :skipped_non_preview_pane
          else
            Shared.kill_preview_pane(registered_tmux_session || tmux_session, pane_id)
          end

        deregister_result = PreviewPanes.deregister(pane_id)

        {:ok,
         %{
           pane_id: pane_id,
           session_id: session_id,
           preview_id: registration.preview_id,
           workspace_id: registration.workspace_id,
           status: :closed,
           tmux_kill: close_result_payload(kill_result),
           deregister: close_result_payload(deregister_result)
         }}

      nil when is_binary(tmux_session) and tmux_session != "" ->
        {:ok,
         %{
           pane_id: pane_id,
           status: :closed,
           stale: true,
           tmux_session: tmux_session,
           tmux_kill: close_result_payload(Shared.kill_preview_pane(tmux_session, pane_id))
         }}

      nil ->
        {:error,
         %{
           error: :preview_pane_not_registered,
           pane_id: pane_id,
           message:
             "Preview pane is not registered in this release. Pass tmux_session to close a stale tmux pane."
         }}
    end
  end

  defp maybe_kill_preview_pane(session_id) do
    case PreviewPanes.get_by_session(session_id) do
      %{pane_id: pane_id, tmux_session: tmux_session}
      when is_binary(tmux_session) and is_binary(pane_id) ->
        _ = Shared.kill_preview_pane(tmux_session, pane_id)
        _ = PreviewPanes.deregister(pane_id)
        :ok

      _ ->
        :ok
    end
  end

  defp close_result_payload(:ok), do: %{status: "ok"}

  defp close_result_payload(:skipped_non_preview_pane),
    do: %{
      status: "skipped",
      reason: "non_preview_pane",
      message: "Pane is not a Casein preview pane; the binding was released without killing it."
    }

  defp close_result_payload({:ok, value}), do: %{status: "ok", value: inspect(value)}

  defp close_result_payload({:error, reason}),
    do: %{status: "error", reason: Shared.health_error(reason)}

  defp close_result_payload(other), do: %{status: "unknown", result: inspect(other)}
end
