defmodule DevIdeWeb.PageController do
  @moduledoc """
  Root landing controller.

  By default `GET /` redirects to the workspace index. LAN direct mode can
  redirect the root straight into a configured default workspace.
  """
  use DevIdeWeb, :controller

  def home(conn, _params) do
    case direct_workspace_id() do
      nil -> redirect(conn, to: ~p"/workspaces")
      workspace_id -> redirect(conn, to: ~p"/workspaces/#{workspace_id}")
    end
  end

  defp direct_workspace_id do
    lan? = Application.get_env(:dev_ide, :lan_mode, false)
    direct? = Application.get_env(:dev_ide, :lan_direct_mode, false)
    workspace_id = Application.get_env(:dev_ide, :default_workspace)

    if lan? and direct? and is_binary(workspace_id) and String.trim(workspace_id) != "" do
      workspace_id
    end
  end
end
