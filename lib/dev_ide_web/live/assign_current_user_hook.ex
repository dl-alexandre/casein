defmodule DevIdeWeb.AssignCurrentUserHook do
  @moduledoc "LiveView on_mount hook: shares :current_user via assign_new/3 across workspace LiveViews."

  import Phoenix.Component

  alias DevIdeWeb.Plugs.AssignCurrentUser

  def on_mount(:default, _params, session, socket) do
    {:cont,
     assign_new(socket, :current_user, fn ->
       AssignCurrentUser.from_session(session)
     end)}
  end
end
