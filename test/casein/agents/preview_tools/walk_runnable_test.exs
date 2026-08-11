defmodule Casein.Agents.PreviewTools.WalkRunnableTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.PreviewTools.SurfaceDiscovery

  describe "classify_walk_runnable/1" do
    test "alive loopback surface is walk_ready" do
      surface = %{
        name: "localhost:5173",
        url: "http://127.0.0.1:5173/",
        server_active: true,
        server_status: %{liveness: "alive", port: 5173}
      }

      assert {:walk_ready, meta} = SurfaceDiscovery.classify_walk_runnable(surface)
      assert meta.server_active == true
      assert meta.liveness == "alive"
      assert meta.openable? == true
      # walk_ready is openability, not operator visibility
      assert meta.operator_visible? == false
    end

    test "dead loopback is not_ready" do
      surface = %{
        name: "localhost:4321",
        server_active: false,
        server_status: %{"liveness" => "dead"}
      }

      assert {:not_ready, :server_dead} = SurfaceDiscovery.classify_walk_runnable(surface)
    end

    test "public unprobed surface is walk_ready (openable)" do
      surface = %{
        name: "app",
        url: "https://one-v3-dev.example/",
        server_active: true,
        server_status: %{liveness: "unprobed"}
      }

      assert {:walk_ready, meta} = SurfaceDiscovery.classify_walk_runnable(surface)
      assert meta.liveness == "unprobed"
    end

    test "unknown observation is never walk_ready" do
      assert {:not_ready, :unknown_observation} =
               SurfaceDiscovery.classify_walk_runnable(%{})

      assert {:not_ready, :unknown_observation} =
               SurfaceDiscovery.classify_walk_runnable(%{
                 name: "x",
                 server_status: %{liveness: "mystery"}
               })

      assert {:not_ready, :unknown_observation} =
               SurfaceDiscovery.classify_walk_runnable(nil)
    end

    test "explicit server_active false without liveness is server_inactive" do
      assert {:not_ready, :server_inactive} =
               SurfaceDiscovery.classify_walk_runnable(%{
                 name: "stale",
                 server_active: false
               })
    end
  end

  describe "operator_visible?/1" do
    test "requires both operator_visible and browser_loaded true" do
      assert SurfaceDiscovery.operator_visible?(%{
               operator_visible: true,
               browser_loaded: true
             })

      refute SurfaceDiscovery.operator_visible?(%{
               operator_visible: true,
               browser_loaded: false
             })

      refute SurfaceDiscovery.operator_visible?(%{
               operator_visible: false,
               browser_loaded: true
             })

      # missing fields fail closed — unknown ≠ visible
      refute SurfaceDiscovery.operator_visible?(%{operator_visible: true})
      refute SurfaceDiscovery.operator_visible?(%{browser_loaded: true})
      refute SurfaceDiscovery.operator_visible?(%{})
      refute SurfaceDiscovery.operator_visible?(nil)
    end

    test "string keys and string booleans accepted" do
      assert SurfaceDiscovery.operator_visible?(%{
               "operator_visible" => true,
               "browser_loaded" => true
             })

      refute SurfaceDiscovery.operator_visible?(%{
               "operator_visible" => "true",
               "browser_loaded" => "false"
             })
    end
  end
end
