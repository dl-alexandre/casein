defmodule CaseinWeb.API.CodexHookControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Codex.Store

  @workspace_id "ws-codex-hook"
  @workspace_token "codex-hook-workspace-token"
  @admin_token "codex-hook-admin-token"

  setup do
    previous_api_token = Application.get_env(:dev_ide, :api_token)
    previous_workspace_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)

    Application.put_env(:dev_ide, :api_token, @admin_token)
    Application.put_env(:dev_ide, :workspace_api_tokens, %{@workspace_token => @workspace_id})
    :ok = Store.clear()

    on_exit(fn ->
      restore(:api_token, previous_api_token)
      restore(:workspace_api_tokens, previous_workspace_tokens)
    end)

    :ok
  end

  test "accepts a matching workspace-scoped lifecycle hook", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @workspace_token)
      |> post(~p"/api/workspaces/#{@workspace_id}/codex/hooks", %{
        "event" => %{
          "hook_event_name" => "SessionStart",
          "session_id" => "cli-thread",
          "cwd" => "/workspace"
        }
      })

    assert %{"accepted" => true, "event_ids" => [_id]} = json_response(conn, 202)

    assert %{threads: [%{thread_id: "cli-thread", transport: :hook}]} =
             Store.workspace_snapshot(@workspace_id)
  end

  test "rejects a global token because hook ingestion must be workspace scoped", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @admin_token)
      |> post(~p"/api/workspaces/#{@workspace_id}/codex/hooks", %{
        "event" => %{"hook_event_name" => "SessionStart", "session_id" => "cli-thread"}
      })

    assert %{"error" => "workspace_scoped_token_required"} = json_response(conn, 403)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
