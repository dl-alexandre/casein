defmodule Casein.Deployment.HealthTest do
  use Casein.TestCase, async: true

  alias Casein.Deployment.Health

  @host "casein.devbox.example.com"
  @revision "1fb643af2c58da2c9b10019cc3de1b06555e3732"

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
             status.checks.caddy_casein_upstream
  end

  test "Caddy probe retries a first zero-byte timeout then accepts the exact config" do
    attempts = start_supervised!({Agent, fn -> 0 end})
    test_pid = self()

    request = fn url, request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      send(test_pid, {:caddy_request, attempt, url, request_opts})

      if attempt == 1,
        do: {:error, %Req.TransportError{reason: :timeout}},
        else: {:ok, %{status: 200, body: caddy_config()}}
    end

    sleep = fn duration -> send(test_pid, {:caddy_backoff, duration}) end

    assert {:ok, config} =
             Health.fetch_caddy_config(
               caddy_admin_probe: true,
               caddy_request: request,
               caddy_retry_sleep: sleep
             )

    assert Health.caddy_app_dial(config, @host) == "unix//run/casein/current.sock"
    assert_receive {:caddy_request, 1, "http://localhost:2019/config/", first_opts}
    assert_receive {:caddy_backoff, 100}
    assert_receive {:caddy_request, 2, "http://localhost:2019/config/", second_opts}
    assert first_opts == second_opts
    assert first_opts[:retry] == false
    assert first_opts[:pool_timeout] == 250
    assert first_opts[:connect_options] == [timeout: 250]
    assert first_opts[:receive_timeout] == 500
    refute_receive {:caddy_request, 3, _, _}
  end

  test "Caddy probe short-circuits after the first exact success" do
    attempts = start_supervised!({Agent, fn -> 0 end})

    request = fn _url, _request_opts ->
      Agent.update(attempts, &(&1 + 1))
      {:ok, %{status: 200, body: caddy_config()}}
    end

    assert {:ok, config} =
             Health.fetch_caddy_config(
               caddy_admin_probe: true,
               caddy_request: request,
               caddy_retry_sleep: fn _ -> flunk("successful probe must not back off") end
             )

    assert Health.caddy_app_dial(config, @host) == "unix//run/casein/current.sock"
    assert Agent.get(attempts, & &1) == 1
  end

  test "Caddy probe bounds persistent timeouts to three attempts" do
    test_pid = self()

    request = fn _url, _opts ->
      send(test_pid, :caddy_request)
      {:error, %Req.TransportError{reason: :timeout}}
    end

    sleep = fn duration -> send(test_pid, {:caddy_backoff, duration}) end

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Health.fetch_caddy_config(
               caddy_admin_probe: true,
               caddy_request: request,
               caddy_retry_sleep: sleep
             )

    assert_receive :caddy_request
    assert_receive {:caddy_backoff, 100}
    assert_receive :caddy_request
    assert_receive {:caddy_backoff, 200}
    assert_receive :caddy_request
    refute_receive :caddy_request
    refute_receive {:caddy_backoff, _}
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

  test "caddy_app_dial returns the Casein app upstream, not oauth2-proxy" do
    assert Health.caddy_app_dial(caddy_config(), @host) ==
             "unix//run/casein/current.sock"
  end

  test "status reports ok when injected checks pass" do
    socket =
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    assert %{ok: true, version: @revision, checks: checks} =
             Health.status(healthy_opts(socket))

    assert checks.socket_exists
    assert checks.current_socket_points_to_instance
    assert %{ok: true} = checks.caddy_casein_upstream
    assert checks.deploy_revision_current
  end

  test "status reports not ok when the socket file is missing" do
    socket = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.sock")

    assert %{ok: false, checks: checks} = Health.status(healthy_opts(socket))
    refute checks.socket_exists
    assert checks.current_socket_points_to_instance
  end

  test "status rejects a stale current socket target" do
    socket =
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

    stale_socket =
      Path.join(System.tmp_dir!(), "casein-stale-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    on_exit(fn -> File.rm(stale_socket) end)
    File.write!(socket, "")
    File.write!(stale_socket, "")

    assert %{ok: false, checks: checks} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:current_target, stale_socket)
             )

    assert checks.socket_exists
    refute checks.current_socket_points_to_instance

    assert %{ok: true, actual: "unix//run/casein/current.sock"} =
             checks.caddy_casein_upstream
  end

  test "status reports ok when Caddy routes Casein through the loopback proxy" do
    socket =
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

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

    assert %{ok: true, actual: "127.0.0.1:4000"} = checks.caddy_casein_upstream
  end

  test "status reports not ok when Caddy points at the wrong upstream" do
    socket =
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

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

    assert %{ok: false, actual: "127.0.0.1:9000"} = checks.caddy_casein_upstream
  end

  test "status reports not ok when the deploy poller failed on master" do
    socket =
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

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

    prev_deploy = Application.get_env(:casein, :deployment)

    Application.put_env(
      :casein,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:last_deploy_path, path)
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:casein, :deployment, prev_deploy),
        else: Application.delete_env(:casein, :deployment)
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
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

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
      Path.join(System.tmp_dir!(), "casein-health-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> File.rm(socket) end)
    File.write!(socket, "")

    assert %{ok: false, checks: checks} =
             Health.status(
               healthy_opts(socket)
               |> Keyword.put(:caddy_config, {:error, :econnrefused})
             )

    assert %{ok: false, error: _} = checks.caddy_casein_upstream
  end
end
