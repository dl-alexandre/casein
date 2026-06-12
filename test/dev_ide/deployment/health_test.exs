defmodule DevIDE.Deployment.HealthTest do
  use ExUnit.Case, async: true

  alias DevIDE.Deployment.Health

  @host "devide.devbox.example.com"
  @revision "1fb643af2c58da2c9b10019cc3de1b06555e3732"

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

  test "caddy_app_dial returns the DevIDE app upstream, not oauth2-proxy" do
    assert Health.caddy_app_dial(caddy_config(), @host) ==
             "unix//run/devide/current.sock"
  end

  test "status reports ok when injected checks pass" do
    socket =
      Path.join(System.tmp_dir!(), "devide-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    assert %{ok: true, version: @revision, checks: checks} =
             Health.status(healthy_opts(socket))

    assert checks.socket_exists
    assert checks.current_socket_points_to_instance
    assert %{ok: true} = checks.caddy_devide_upstream
    assert checks.deploy_revision_current
  end

  test "status reports not ok when the socket file is missing" do
    socket = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.sock")

    assert %{ok: false, checks: checks} = Health.status(healthy_opts(socket))
    refute checks.socket_exists
    assert checks.current_socket_points_to_instance
  end

  test "status reports not ok when Caddy points at the wrong upstream" do
    socket =
      Path.join(System.tmp_dir!(), "devide-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    bad_config = %{
      "apps" => %{
        "http" => %{
          "servers" => %{
            "srv0" => %{
              "routes" => [
                %{
                  "match" => [%{"host" => [@host]}],
                  "handle" => [
                    %{
                      "handler" => "reverse_proxy",
                      "upstreams" => [%{"dial" => "127.0.0.1:4000"}]
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }

    assert %{ok: false, checks: checks} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:caddy_config, {:ok, bad_config})
             )

    assert %{ok: false, actual: "127.0.0.1:4000"} = checks.caddy_devide_upstream
  end

  test "status reports not ok when deploy drift is detected" do
    socket =
      Path.join(System.tmp_dir!(), "devide-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    assert %{ok: false, checks: checks} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:remote_head, {:ok, String.duplicate("b", 40)})
             )

    refute checks.deploy_revision_current
  end

  test "status reports not ok when Caddy config cannot be fetched" do
    socket =
      Path.join(System.tmp_dir!(), "devide-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    assert %{ok: false, checks: checks} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:caddy_config, {:error, :econnrefused})
             )

    assert %{ok: false, error: _} = checks.caddy_devide_upstream
  end
end
