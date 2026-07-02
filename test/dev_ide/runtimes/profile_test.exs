defmodule DevIDE.Runtimes.ProfileTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Runtimes.{Profile, Runtime}

  test "normalizes a built-in Phoenix runtime profile" do
    assert {:ok, profile} = Profile.normalize("phoenix")

    assert profile["name"] == "phoenix"
    assert profile["kind"] == "phoenix"
    assert profile["command"] == ["mise", "exec", "--", "mix", "phx.server"]
    assert profile["ports"] == %{"app" => 4000}
    assert profile["surfaces"] == [%{"name" => "app", "port" => 4000}]
  end

  test "normalizes a custom runtime profile without dynamic atom conversion" do
    assert {:ok, profile} =
             Profile.normalize(%{
               name: "preview",
               command: ["npm", "run", "dev"],
               cwd: "assets",
               env: %{PORT: 5173},
               ports: %{app: "5173"},
               surfaces: [%{name: "app", port: "5173"}],
               health_check: %{path: "/health"}
             })

    assert profile["name"] == "preview"
    assert profile["command"] == ["npm", "run", "dev"]
    assert profile["cwd"] == "assets"
    assert profile["env"] == %{"PORT" => "5173"}
    assert profile["ports"] == %{"app" => 5173}
    assert profile["surfaces"] == [%{"name" => "app", "port" => 5173}]
    assert profile["health_check"] == %{"path" => "/health"}
  end

  test "derives runtime-scoped preview surfaces" do
    runtime = %Runtime{
      id: "rt-123",
      workspace_id: "ws-1",
      host_id: "local",
      isolation_mode: "worktree",
      status: "provisioned",
      created_at: DateTime.utc_now(),
      metadata: %{
        "runtime_profile" => %{
          "name" => "vite",
          "kind" => "vite",
          "command" => ["npm", "run", "dev"],
          "env" => %{},
          "ports" => %{"app" => 5173},
          "surfaces" => [%{"name" => "app", "port" => 5173}],
          "health_check" => nil
        }
      }
    }

    assert [
             %{
               "name" => "app",
               "url" => "http://localhost:5173",
               "source" => "runtime",
               "runtime_id" => "rt-123",
               "runtime_status" => "provisioned",
               "surface_key" => "runtime:rt-123:app"
             }
           ] = Profile.preview_surfaces(runtime)
  end

  test "rejects invalid profile ports" do
    assert {:error, {:invalid_runtime_profile_port, "app"}} =
             Profile.normalize(%{ports: %{app: "nope"}})
  end
end
