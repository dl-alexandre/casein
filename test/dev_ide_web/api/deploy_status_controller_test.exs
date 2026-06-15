defmodule DevIdeWeb.API.DeployStatusControllerTest do
  use DevIdeWeb.ConnCase, async: false

  @token "test-token"
  @host "devide.devbox.example.com"
  @revision "1fb643af2c58da2c9b10019cc3de1b06555e3732"

  setup %{conn: conn} do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_workspace_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    prev_health_opts = Application.get_env(:dev_ide, :deployment_health_opts)

    Application.put_env(:dev_ide, :api_token, @token)
    Application.delete_env(:dev_ide, :deployment_health_opts)

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:dev_ide, :api_token, prev_token),
        else: Application.delete_env(:dev_ide, :api_token)

      if prev_workspace_tokens,
        do: Application.put_env(:dev_ide, :workspace_api_tokens, prev_workspace_tokens),
        else: Application.delete_env(:dev_ide, :workspace_api_tokens)

      if prev_health_opts,
        do: Application.put_env(:dev_ide, :deployment_health_opts, prev_health_opts),
        else: Application.delete_env(:dev_ide, :deployment_health_opts)
    end)

    {:ok, conn: conn}
  end

  test "returns 401 without bearer token", %{conn: conn} do
    conn = get(conn, ~p"/api/deploy_status")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "returns 403 for workspace-scoped tokens on global deploy status", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-1"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer ws-token")
      |> get(~p"/api/deploy_status")

    assert json_response(conn, 403) == %{"error" => "workspace_forbidden"}
  end

  test "returns 503 with deploy check payload when health is not ok", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get(~p"/api/deploy_status")

    body = json_response(conn, 503)
    assert body["ok"] == false
    assert is_map(body["checks"])
    assert Map.has_key?(body["checks"], "socket_exists")
    assert Map.has_key?(body["checks"], "caddy_devide_upstream")
    assert Map.has_key?(body["checks"], "deploy_revision_current")
    assert is_binary(body["version"])
  end

  test "returns 200 when injected health checks pass", %{conn: conn} do
    socket =
      Path.join(System.tmp_dir!(), "deploy-status-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    Application.put_env(:dev_ide, :deployment_health_opts, healthy_opts(socket))

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
                              "upstreams" => [%{"dial" => "unix//run/devide/current.sock"}]
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
