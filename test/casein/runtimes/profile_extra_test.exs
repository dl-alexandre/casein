defmodule Casein.Runtimes.ProfileExtraTest do
  use Casein.TestCase, async: true

  alias Casein.Runtimes.{Profile, Runtime}

  defp runtime(metadata) do
    %Runtime{
      id: "rt-x",
      workspace_id: "ws-1",
      host_id: "local",
      isolation_mode: "worktree",
      status: "provisioned",
      created_at: DateTime.utc_now(),
      metadata: metadata
    }
  end

  describe "from_attrs/1" do
    test "non-map attrs returns nil" do
      assert {:ok, nil} = Profile.from_attrs("nope")
      assert {:ok, nil} = Profile.from_attrs(nil)
    end

    test "empty map yields nil profile" do
      assert {:ok, nil} = Profile.from_attrs(%{})
    end

    test "reads runtime_profile key" do
      assert {:ok, profile} = Profile.from_attrs(%{"runtime_profile" => "phoenix"})
      assert profile["name"] == "phoenix"
    end

    test "reads profile key when runtime_profile absent" do
      assert {:ok, profile} = Profile.from_attrs(%{"profile" => "vite"})
      assert profile["name"] == "vite"
    end

    test "reads nested runtime.profile" do
      assert {:ok, profile} = Profile.from_attrs(%{"runtime" => %{"profile" => "static"}})
      assert profile["name"] == "static"
    end

    test "reads nested metadata.runtime_profile" do
      assert {:ok, profile} =
               Profile.from_attrs(%{"metadata" => %{"runtime_profile" => "phoenix"}})

      assert profile["name"] == "phoenix"
    end

    test "supports atom keys via value/2" do
      assert {:ok, profile} = Profile.from_attrs(%{profile: "vite"})
      assert profile["name"] == "vite"
    end

    test "propagates normalize errors" do
      assert {:error, {:unknown_runtime_profile, "bogus"}} =
               Profile.from_attrs(%{"runtime_profile" => "bogus"})
    end
  end

  describe "normalize/1 scalar inputs" do
    test "nil and empty string yield nil" do
      assert {:ok, nil} = Profile.normalize(nil)
      assert {:ok, nil} = Profile.normalize("")
    end

    test "atom name delegates to string clause" do
      assert {:ok, profile} = Profile.normalize(:phoenix)
      assert profile["name"] == "phoenix"
    end

    test "name is trimmed and downcased" do
      assert {:ok, profile} = Profile.normalize("  PHOENIX  ")
      assert profile["name"] == "phoenix"
    end

    test "unknown name errors" do
      assert {:error, {:unknown_runtime_profile, "nope"}} = Profile.normalize("nope")
    end

    test "non-map non-binary input is invalid" do
      assert {:error, :invalid_runtime_profile} = Profile.normalize(123)
    end
  end

  describe "normalize/1 map inputs" do
    test "map without name defaults to custom builtin" do
      assert {:ok, profile} = Profile.normalize(%{})
      assert profile["name"] == "custom"
      assert profile["kind"] == "custom"
      assert profile["command"] == nil
      assert profile["ports"] == %{}
      assert profile["surfaces"] == []
      assert profile["env"] == %{}
      assert profile["health_check"] == nil
      assert profile["cwd"] == nil
      refute Map.has_key?(profile, "metadata")
    end

    test "builtin name merges and lets overrides win" do
      assert {:ok, profile} =
               Profile.normalize(%{"name" => "phoenix", "command" => "run.sh"})

      assert profile["name"] == "phoenix"
      assert profile["kind"] == "phoenix"
      assert profile["command"] == ["run.sh"]
    end

    test "explicit kind overrides name-derived kind" do
      assert {:ok, profile} = Profile.normalize(%{"name" => "myapp", "kind" => "thing"})
      assert profile["kind"] == "thing"
    end

    test "kind defaults to custom when absent" do
      assert {:ok, profile} = Profile.normalize(%{"name" => "myapp"})
      assert profile["kind"] == "custom"
    end

    test "non-empty cwd is kept, blank cwd dropped to nil" do
      assert {:ok, kept} = Profile.normalize(%{"name" => "x", "cwd" => "assets"})
      assert kept["cwd"] == "assets"

      assert {:ok, blank} = Profile.normalize(%{"name" => "x", "cwd" => ""})
      assert blank["cwd"] == nil
    end

    test "metadata is stringified and only added when present" do
      assert {:ok, with_meta} =
               Profile.normalize(%{"name" => "x", "metadata" => %{owner: "me"}})

      assert with_meta["metadata"] == %{"owner" => "me"}

      assert {:ok, empty_meta} = Profile.normalize(%{"name" => "x", "metadata" => %{}})
      refute Map.has_key?(empty_meta, "metadata")
    end

    test "command as binary wraps in list" do
      assert {:ok, profile} = Profile.normalize(%{"name" => "x", "command" => "do.sh"})
      assert profile["command"] == ["do.sh"]
    end

    test "command list with empty string element errors" do
      assert {:error, :invalid_runtime_profile_command} =
               Profile.normalize(%{"name" => "x", "command" => ["ok", ""]})
    end

    test "command of wrong type errors" do
      assert {:error, :invalid_runtime_profile_command} =
               Profile.normalize(%{"name" => "x", "command" => 42})
    end

    test "ports of wrong type errors" do
      assert {:error, :invalid_runtime_profile_ports} =
               Profile.normalize(%{"name" => "x", "ports" => "nope"})
    end

    test "string surface entry normalizes with port from ports map" do
      assert {:ok, profile} =
               Profile.normalize(%{
                 "name" => "x",
                 "ports" => %{"app" => 3000},
                 "surfaces" => ["app"]
               })

      assert profile["surfaces"] == [%{"name" => "app", "port" => 3000}]
    end

    test "surface with explicit url keeps url and drops nil port" do
      assert {:ok, profile} =
               Profile.normalize(%{
                 "name" => "x",
                 "surfaces" => [%{"name" => "web", "url" => "https://example.com"}]
               })

      assert profile["surfaces"] == [%{"name" => "web", "url" => "https://example.com"}]
    end

    test "surfaces of wrong type errors" do
      assert {:error, :invalid_runtime_profile_surfaces} =
               Profile.normalize(%{"name" => "x", "surfaces" => "nope"})
    end

    test "invalid surface element errors" do
      assert {:error, :invalid_runtime_profile_surface} =
               Profile.normalize(%{"name" => "x", "surfaces" => [123]})
    end

    test "surface with bad port errors" do
      assert {:error, {:invalid_runtime_profile_port, "bad"}} =
               Profile.normalize(%{
                 "name" => "x",
                 "surfaces" => [%{"name" => "a", "port" => "bad"}]
               })
    end

    test "env accepts strings and integers, stringifying both" do
      assert {:ok, profile} =
               Profile.normalize(%{"name" => "x", "env" => %{"A" => "1", "B" => 2}})

      assert profile["env"] == %{"A" => "1", "B" => "2"}
    end

    test "env with invalid value errors" do
      assert {:error, {:invalid_runtime_profile_env, "A"}} =
               Profile.normalize(%{"name" => "x", "env" => %{"A" => %{}}})
    end

    test "env of wrong type errors" do
      assert {:error, :invalid_runtime_profile_env} =
               Profile.normalize(%{"name" => "x", "env" => "nope"})
    end

    test "health_check map is stringified" do
      assert {:ok, profile} =
               Profile.normalize(%{"name" => "x", "health_check" => %{path: "/up"}})

      assert profile["health_check"] == %{"path" => "/up"}
    end

    test "health_check of wrong type errors" do
      assert {:error, :invalid_runtime_profile_health_check} =
               Profile.normalize(%{"name" => "x", "health_check" => "nope"})
    end

    test "port out of range is rejected" do
      assert {:error, {:invalid_runtime_profile_port, "app"}} =
               Profile.normalize(%{"name" => "x", "ports" => %{"app" => 70_000}})
    end

    test "string port within range is parsed" do
      assert {:ok, profile} = Profile.normalize(%{"name" => "x", "ports" => %{"app" => "8080"}})
      assert profile["ports"] == %{"app" => 8080}
    end
  end

  describe "for_runtime/1" do
    test "returns map profile from metadata" do
      profile = %{"name" => "vite", "surfaces" => []}
      assert Profile.for_runtime(runtime(%{"runtime_profile" => profile})) == profile
    end

    test "returns nil when runtime_profile is not a map" do
      assert Profile.for_runtime(runtime(%{"runtime_profile" => "vite"})) == nil
    end

    test "returns nil when metadata lacks profile" do
      assert Profile.for_runtime(runtime(%{})) == nil
    end

    test "returns nil for non-Runtime input" do
      assert Profile.for_runtime(%{not: "a runtime"}) == nil
    end

    test "returns nil when metadata is not a map" do
      assert Profile.for_runtime(runtime(nil)) == nil
    end
  end

  describe "preview_surfaces/2" do
    test "returns [] when runtime has no profile" do
      assert Profile.preview_surfaces(runtime(%{})) == []
    end

    test "uses explicit surface url over port" do
      rt =
        runtime(%{
          "runtime_profile" => %{
            "surfaces" => [%{"name" => "app", "url" => "https://live.test"}],
            "ports" => %{"app" => 4000}
          }
        })

      assert [payload] = Profile.preview_surfaces(rt)
      assert payload["url"] == "https://live.test"
      assert payload["title"] == "App"
      assert payload["surface_key"] == "runtime:rt-x:app"
    end

    test "joins base_url with port and trims trailing slash" do
      rt =
        runtime(%{
          "runtime_profile" => %{
            "surfaces" => [%{"name" => "web", "port" => 5173}],
            "ports" => %{}
          }
        })

      assert [payload] = Profile.preview_surfaces(rt, base_url: "https://host/")
      assert payload["url"] == "https://host:5173"
      assert payload["title"] == "Web"
    end

    test "falls back to localhost url without base_url" do
      rt =
        runtime(%{
          "runtime_profile" => %{
            "surfaces" => [%{"name" => "app"}],
            "ports" => %{"app" => 9000}
          }
        })

      assert [payload] = Profile.preview_surfaces(rt)
      assert payload["url"] == "http://localhost:9000"
      assert payload["port"] == 9000
    end

    test "drops surfaces with no resolvable port and no url" do
      rt =
        runtime(%{
          "runtime_profile" => %{
            "surfaces" => [%{"name" => "app"}],
            "ports" => %{}
          }
        })

      assert Profile.preview_surfaces(rt) == []
    end
  end
end
