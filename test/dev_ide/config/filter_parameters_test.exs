defmodule DevIDE.Config.FilterParametersTest do
  use DevIdeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @token "filter-log-test-token"

  @auth_keys ~w(
    authorization
    token
    api_token
    bearer
    access_token
    refresh_token
    workspace_api_tokens
    dev_ide_api_token
    password
    secret
  )

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    Application.put_env(:dev_ide, :api_token, @token)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, :api_token)
        val -> Application.put_env(:dev_ide, :api_token, val)
      end
    end)

    :ok
  end

  test "Phoenix.Logger.filter_values redacts configured auth param names" do
    params = %{
      "id" => "42",
      "token" => "super-secret",
      "nested" => %{"api_token" => "nested-secret", "name" => "ok"}
    }

    filtered = Phoenix.Logger.filter_values(params)

    assert filtered["id"] == "42"
    assert filtered["token"] == "[FILTERED]"
    assert filtered["nested"]["api_token"] == "[FILTERED]"
    assert filtered["nested"]["name"] == "ok"
  end

  test "configured auth keys are filtered at runtime via Phoenix.Logger" do
    assert match?({:compiled, _, _}, Application.get_env(:phoenix, :filter_parameters, []))

    for key <- @auth_keys do
      assert Phoenix.Logger.filter_values(%{key => "leak-value"})[key] == "[FILTERED]"
    end
  end

  test "MCP router dispatch log does not emit raw bearer tokens or filtered params", %{conn: conn} do
    log =
      capture_log(fn ->
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post(
          "/api/terminals/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "token" => "body-secret-token"
          })
        )
        |> response(200)
      end)

    refute log =~ @token
    refute log =~ "body-secret-token"
  end

  test "Phoenix router dispatch logs omit Authorization headers (params-only logging)" do
    conn =
      :post
      |> Plug.Test.conn("/api/terminals/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize"
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer header-only-secret")

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:phoenix, :router_dispatch, :start],
          %{system_time: System.system_time()},
          %{
            conn: conn,
            log: :info,
            plug: DevIdeWeb.API.TerminalMCPController,
            plug_opts: :mcp,
            pipe_through: [:mcp_api],
            path_params: %{},
            route: "/api/terminals/mcp"
          }
        )
      end)

    refute log =~ "header-only-secret"
    refute log =~ "Bearer"
  end
end
