defmodule Casein.Agents.PreviewTools.ScopedLocalServerTest do
  # Serial: mutates process-global Application env
  # (:preview_prefer_scoped_local_server, :preview_surface_prober).
  use Casein.TestCase, async: false

  alias Casein.Agents.PreviewTools.SurfaceDiscovery
  alias Casein.Previews.Surface

  # v3 workspace advertising service ports app/tidewave/api. A default "app"
  # open resolves to the shared, workspace-wide manager URL below.
  @workspace %{
    id: "ws-v3",
    metadata: %{
      type: :v3,
      domain_base: "alice-feature.devbox.example.com",
      ports: %{"app" => 10_100, "tidewave" => 11_003, "api" => 10_200}
    }
  }

  @shared %Surface{
    name: "app",
    url: "https://alice-feature.devbox.example.com",
    title: "App",
    source: :manager
  }

  setup do
    previous_flag = Application.get_env(:casein, :preview_prefer_scoped_local_server)
    previous_prober = Application.get_env(:casein, :preview_surface_prober)
    Application.put_env(:casein, :preview_prefer_scoped_local_server, true)

    on_exit(fn ->
      restore(:preview_prefer_scoped_local_server, previous_flag)
      restore(:preview_surface_prober, previous_prober)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  # Stub the liveness probe: only `live` ports accept connections.
  defp stub_prober(live) do
    Application.put_env(
      :casein,
      :preview_surface_prober,
      fn ports -> Map.new(ports, fn port -> {port, port in live} end) end
    )
  end

  defp workspace_with_detected(ports) do
    put_in(@workspace, [:metadata, :detected_ports], ports)
  end

  test "prefers a single live non-advertised localhost server over the shared URL" do
    stub_prober([41_042])
    workspace = workspace_with_detected([41_042])

    assert %Surface{source: :detected, port: 41_042, url: url} =
             SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared)

    assert url == "http://localhost:41042/"
  end

  test "excludes advertised service ports and the preview router from candidates" do
    # 10_100 is the advertised app port (the shared server); 41_080 is the
    # preview router. Both are live but neither is the worktree's own server.
    stub_prober([10_100, 41_080, 41_042])
    workspace = workspace_with_detected([10_100, 41_080, 41_042])

    assert %Surface{source: :detected, port: 41_042} =
             SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared)
  end

  test "keeps the shared URL when only advertised ports are detected" do
    stub_prober([10_100])
    workspace = workspace_with_detected([10_100])

    assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared) == @shared
  end

  test "keeps the shared URL when two or more live candidates are ambiguous" do
    stub_prober([41_042, 41_043])
    workspace = workspace_with_detected([41_042, 41_043])

    assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared) == @shared
  end

  test "keeps the shared URL when the single candidate is not live" do
    stub_prober([])
    workspace = workspace_with_detected([41_042])

    assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared) == @shared
  end

  test "is a no-op when the preference flag is disabled" do
    Application.put_env(:casein, :preview_prefer_scoped_local_server, false)
    stub_prober([41_042])
    workspace = workspace_with_detected([41_042])

    assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared) == @shared
  end

  test "leaves a runtime-provisioned surface untouched" do
    stub_prober([41_042])
    workspace = workspace_with_detected([41_042])

    runtime = %Surface{
      name: "app",
      url: "http://localhost:41055",
      title: "App",
      source: :runtime,
      runtime_id: "rt-1"
    }

    assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", runtime) == runtime
  end

  test "only overrides the default app request, not a named surface" do
    stub_prober([41_042])
    workspace = workspace_with_detected([41_042])

    assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "localhost:5000", @shared) ==
             @shared
  end

  test "treats a nil request as the default app request" do
    stub_prober([41_042])
    workspace = workspace_with_detected([41_042])

    assert %Surface{source: :detected, port: 41_042} =
             SurfaceDiscovery.prefer_scoped_local_server(workspace, nil, @shared)
  end

  describe "preview_source/2 provenance" do
    test "labels a worktree-local override and records what it replaced" do
      local = %Surface{
        name: "app",
        url: "http://localhost:41042/",
        port: 41_042,
        source: :detected
      }

      assert %{
               via: "worktree_local",
               port: 41_042,
               overrode: "https://alice-feature.devbox.example.com"
             } =
               SurfaceDiscovery.preview_source(local, @shared)
    end

    test "labels a runtime-provisioned server" do
      runtime = %Surface{
        name: "app",
        url: "http://localhost:41055",
        port: 41_055,
        source: :runtime
      }

      assert %{via: "runtime", port: 41_055} == SurfaceDiscovery.preview_source(runtime, @shared)
    end

    test "labels the shared manager URL when no override happened" do
      assert %{via: "shared_manager"} == SurfaceDiscovery.preview_source(@shared, @shared)
    end
  end

  describe "real port probe (unstubbed)" do
    test "selects a genuinely listening non-advertised port and rejects it once closed" do
      # No prober stub: exercise the real Casein.Previews.PortProbe against an
      # actual loopback listener, the same connect preview_open's preflight makes.
      Application.delete_env(:casein, :preview_surface_prober)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      workspace = workspace_with_detected([port])

      assert %Surface{source: :detected, port: ^port, url: url} =
               SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared)

      assert url == "http://localhost:#{port}/"

      :ok = :gen_tcp.close(listen)
      # The registration outlives the server; a fresh probe must reject it.
      assert SurfaceDiscovery.prefer_scoped_local_server(workspace, "app", @shared) == @shared
    end
  end
end
