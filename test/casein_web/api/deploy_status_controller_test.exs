defmodule CaseinWeb.API.DeployStatusControllerTest do
  use CaseinWeb.ConnCase, async: false

  @token "test-token"
  @host "devide.devbox.example.com"
  @revision "1fb643af2c58da2c9b10019cc3de1b06555e3732"

  setup %{conn: conn} do
    prev_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_health_opts = Application.get_env(:casein, :deployment_health_opts)

    Application.put_env(:casein, :api_token, @token)
    Application.delete_env(:casein, :deployment_health_opts)

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:casein, :api_token, prev_token),
        else: Application.delete_env(:casein, :api_token)

      if prev_workspace_tokens,
        do: Application.put_env(:casein, :workspace_api_tokens, prev_workspace_tokens),
        else: Application.delete_env(:casein, :workspace_api_tokens)

      if prev_health_opts,
        do: Application.put_env(:casein, :deployment_health_opts, prev_health_opts),
        else: Application.delete_env(:casein, :deployment_health_opts)
    end)

    {:ok, conn: conn}
  end

  test "returns 401 without bearer token", %{conn: conn} do
    conn = get(conn, ~p"/api/deploy_status")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "returns 403 for workspace-scoped tokens on global deploy status", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-1"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer ws-token")
      |> get(~p"/api/deploy_status")

    assert json_response(conn, 403) == %{"error" => "workspace_forbidden"}
  end

  test "returns a neutral 200 when no operator diagnostics are configured", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get(~p"/api/deploy_status")

    body = json_response(conn, 200)
    assert body["ok"] == true

    assert get_in(body, ["checks", "socket_exists", "status"]) == "not_configured"
    assert get_in(body, ["checks", "caddy_devide_upstream", "status"]) == "not_configured"
    assert get_in(body, ["checks", "deploy_revision_current", "status"]) == "not_configured"
  end

  test "returns 200 when injected health checks pass", %{conn: conn} do
    socket =
      Path.join(System.tmp_dir!(), "deploy-status-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    Application.put_env(:casein, :deployment_health_opts, healthy_opts(socket))

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get(~p"/api/deploy_status")

    body = json_response(conn, 200)
    assert body["ok"] == true
    assert body["version"] == @revision
    assert body["socket_path"] == socket
    assert get_in(body, ["checks", "socket_exists"]) == true
    assert get_in(body, ["checks", "deploy_revision_current"]) == true
  end

  defp healthy_opts(socket_path) do
    [
      capabilities: [:socket, :reverse_proxy, :deploy_drift, :deploy_status],
      version: @revision,
      socket_path: socket_path,
      current_target: socket_path,
      caddy_config: {:ok, caddy_config()},
      remote_head: {:ok, @revision},
      host: @host
    ]
  end

  defp caddy_config do
    %{
      "apps" => %{
        "http" => %{
          "servers" => %{
            "srv0" => %{
              "routes" => [
                %{
                  "match" => [%{"host" => [@host]}],
                  "handle" => [
                    %{
                      "handler" => "subroute",
                      "routes" => [
                        %{
                          "handle" => [
                            %{
                              "handler" => "reverse_proxy",
                              "rewrite" => %{"uri" => "/oauth2/auth"},
                              "upstreams" => [%{"dial" => "127.0.0.1:4180"}]
                            }
                          ]
                        },
                        %{
                          "handle" => [
                            %{
                              "handler" => "reverse_proxy",
                              "upstreams" => [%{"dial" => "unix//run/casein/current.sock"}]
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }
  end
end
