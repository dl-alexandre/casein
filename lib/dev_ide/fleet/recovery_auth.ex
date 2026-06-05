defmodule DevIDE.Fleet.RecoveryAuth do
  @moduledoc """
  Authorization for assignment recovery workflow events in LiveView.
  """

  alias DevIDE.Workspaces

  @type actor :: map() | nil
  @type projection :: map() | nil

  @spec can_request_recovery?(actor(), projection()) :: boolean()
  def can_request_recovery?(actor, projection) do
    admin?(actor) or workspace_operator?(actor, projection)
  end

  @spec can_grant_recovery?(actor()) :: boolean()
  def can_grant_recovery?(actor), do: admin?(actor)

  @spec can_apply_recovery?(actor(), projection()) :: boolean()
  def can_apply_recovery?(actor, projection) do
    admin?(actor) or workspace_operator?(actor, projection)
  end

  @spec can_dismiss_recovery?(actor(), projection()) :: boolean()
  def can_dismiss_recovery?(actor, projection), do: can_apply_recovery?(actor, projection)

  defp admin?(%{role: :admin}), do: true
  defp admin?(_), do: false

  defp workspace_operator?(actor, %{workspace_id: ws_id}) when is_binary(ws_id) do
    case actor_email(actor) do
      email when is_binary(email) ->
        case Workspaces.get(ws_id, email) do
          {:ok, ws} -> Workspaces.owns?(ws, workspace_username(actor))
          _ -> false
        end

      _ ->
        false
    end
  end

  defp workspace_operator?(_, _), do: false

  defp actor_email(%{email: email}) when is_binary(email), do: String.downcase(email)
  defp actor_email(_), do: nil

  defp workspace_username(%{username: u}) when is_binary(u), do: u
  defp workspace_username(%{id: id}) when is_binary(id), do: id
  defp workspace_username(_), do: nil
end
