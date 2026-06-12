defmodule DevIDE.Deployment.HealthTest do
  use ExUnit.Case, async: true

  alias DevIDE.Deployment.Health

  test "caddy_app_dial returns the DevIDE app upstream, not oauth2-proxy" do
    config = %{
      "apps" => %{
        "http" => %{
          "servers" => %{
            "srv0" => %{
              "routes" => [
                %{
                  "match" => [%{"host" => ["devide.devbox.milcgroup.com"]}],
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

    assert Health.caddy_app_dial(config, "devide.devbox.milcgroup.com") ==
             "unix//run/devide/current.sock"
  end
end
