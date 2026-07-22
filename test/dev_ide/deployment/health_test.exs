defmodule DevIDE.Deployment.HealthTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Deployment.Health

  test "portable deployments report optional operator checks as not configured" do
    status =
      Health.status(
        capabilities: [],
        version: "portable",
        socket_path: nil,
        host: "localhost"
      )

    assert status.ok
    assert status.last_deploy.status == :not_configured

    assert Enum.all?(status.checks, fn {_name, check} ->
             check.status == :not_configured and check.ok
           end)
  end

  test "does not probe the Caddy admin API when the probe is disabled (test default)" do
    # config/test.exs sets caddy_admin_probe: false, so the un-injected
    # controller path (status/pane/export) never makes a real HTTP request —
    # the caddy check reflects :probe_disabled instead of hitting the network.
    status = Health.status(capabilities: [:reverse_proxy], host: "example.com")

    assert %{ok: false, error: ":probe_disabled"} =
             status.checks.caddy_devide_upstream
  end

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
      capabilities: [:socket, :reverse_proxy, :deploy_drift, :deploy_status],
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

  test "status reports ok when Caddy routes DevIDE through the loopback proxy" do
    socket =
      Path.join(System.tmp_dir!(), "devide-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    loopback_config = %{
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

    assert %{ok: true, checks: checks} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:caddy_config, {:ok, loopback_config})
             )

    assert %{ok: true, actual: "127.0.0.1:4000"} = checks.caddy_devide_upstream
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
                      "upstreams" => [%{"dial" => "127.0.0.1:9000"}]
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

    assert %{ok: false, actual: "127.0.0.1:9000"} = checks.caddy_devide_upstream
  end

  test "status reports not ok when the deploy poller failed on master" do
    socket =
      Path.join(System.tmp_dir!(), "devide-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    path =
      Path.join(
        System.tmp_dir!(),
        "last-deploy-health-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    record = %{
      "outcome" => "failed",
      "target_sha" => String.duplicate("b", 40),
      "target_short" => String.duplicate("b", 12),
      "phase" => "gate",
      "reason" => "pre-push gate failed",
      "started_at" => "2026-07-06T00:00:00Z",
      "finished_at" => "2026-07-06T00:05:00Z"
    }

    File.write!(path, Jason.encode!(record) <> "\n")

    prev_deploy = Application.get_env(:dev_ide, :deployment)

    Application.put_env(
      :dev_ide,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:last_deploy_path, path)
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:dev_ide, :deployment, prev_deploy),
        else: Application.delete_env(:dev_ide, :deployment)
    end)

    assert %{ok: false, checks: checks, last_deploy: %{pipeline: :failed}} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:remote_head, {:ok, String.duplicate("b", 40)})
             )

    refute checks.deploy_pipeline_ok
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
