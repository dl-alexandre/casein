defmodule DevIDE.Previews.SurfaceResolverTest do
  # Serial: mutates process-global Application env (:preview_loopback_port,
  # :workspaces_root, :on_devbox), which other suites read concurrently.
  use DevIDE.TestCase, async: false

  alias DevIDE.Previews.SurfaceResolver

  @v3_workspace %{
    id: "ws-v3",
    metadata: %{
      type: :v3,
      domain_base: "alice-feature.devbox.example.com",
      ports: %{"app" => 10_100, "tidewave" => 11_003, "api" => 10_200}
    }
  }

  test "resolves v3 manager surfaces from metadata" do
    surfaces = SurfaceResolver.resolve(@v3_workspace)
    names = Enum.map(surfaces, & &1.name)

    assert "app" in names
    assert "tidewave" in names
    assert "api" in names

    app = Enum.find(surfaces, &(&1.name == "app"))
    assert app.url == "https://alice-feature.devbox.example.com"
    assert app.source == :manager

    tidewave = Enum.find(surfaces, &(&1.name == "tidewave"))
    assert tidewave.url == "https://tidewave.alice-feature.devbox.example.com"
  end

  test "get/2 returns a single named surface" do
    assert %{} = surface = SurfaceResolver.get(@v3_workspace, "app")
    assert surface.name == "app"
    assert SurfaceResolver.get(@v3_workspace, "missing") == nil
  end

  test "legacy workspaces without domain_base return no manager surfaces" do
    ws = %{id: "legacy", metadata: %{type: :legacy, ports: %{"app" => 4000}}}
    assert SurfaceResolver.resolve(ws) == []
  end

  test "legacy workspaces with a domain_base get an app surface at local.<domain_base>" do
    ws = %{
      id: "ws-legacy",
      metadata: %{
        type: :legacy,
        domain_base: "bob-legacy.devbox.example.com",
        ports: %{"http" => 10_101, "dash" => 10_301, "jsreport" => 15_489}
      }
    }

    surfaces = SurfaceResolver.resolve(ws)

    app = Enum.find(surfaces, &(&1.name == "app" and &1.source == :manager))
    assert app.url == "https://local.bob-legacy.devbox.example.com"

    # Legacy infra ports are loopback-only: no public dash./jsreport. subdomains.
    urls = Enum.map(surfaces, & &1.url)
    refute "https://dash.bob-legacy.devbox.example.com" in urls
    refute "https://jsreport.bob-legacy.devbox.example.com" in urls
  end

  test "host surfaces are appended on devbox when manager metadata is empty" do
    previous_on_devbox = Application.get_env(:dev_ide, :on_devbox)
    previous_app_url = Application.get_env(:dev_ide, :preview_app_url)
    previous_root = Application.get_env(:dev_ide, :workspaces_root)
    workspace = Path.join(System.tmp_dir!(), "surface-host-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    Application.put_env(:dev_ide, :workspaces_root, Path.dirname(workspace))
    Application.put_env(:dev_ide, :on_devbox, true)
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)
    Application.put_env(:dev_ide, :preview_app_url, "https://devide.example.com")

    on_exit(fn ->
      File.rm_rf(workspace)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:preview_app_url, previous_app_url)
      restore_env(:workspaces_root, previous_root)
    end)

    ws = %{id: "devide-checkout", path: workspace, metadata: %{attached_folder: true}}
    surfaces = SurfaceResolver.resolve(ws)
    names = Enum.map(surfaces, & &1.name)

    assert "app" in names
    assert "app-local" in names
    assert "devide" in names

    devide = Enum.find(surfaces, &(&1.name == "devide"))
    assert devide.url =~ "/workspaces/devide-checkout"

    app_local = Enum.find(surfaces, &(&1.name == "app-local"))
    assert app_local.url == "http://127.0.0.1:4000"
    assert app_local.source == :host
    assert app_local.title == "App (loopback → live)"

    if Code.ensure_loaded?(Tidewave) do
      tidewave_local = Enum.find(surfaces, &(&1.name == "tidewave-local"))
      assert tidewave_local.url == "http://127.0.0.1:4000/tidewave"
      assert tidewave_local.source == :host
    end
  end

  test "detected_ports from metadata become host-detected localhost surfaces" do
    previous_on_devbox = Application.get_env(:dev_ide, :on_devbox)
    previous_root = Application.get_env(:dev_ide, :workspaces_root)

    workspace =
      Path.join(System.tmp_dir!(), "surface-detected-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    Application.put_env(:dev_ide, :workspaces_root, Path.dirname(workspace))
    Application.put_env(:dev_ide, :on_devbox, true)

    on_exit(fn ->
      File.rm_rf(workspace)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:workspaces_root, previous_root)
    end)

    ws = %{
      id: "devide-detected",
      path: workspace,
      metadata: %{attached_folder: true, detected_ports: [8765]}
    }

    surfaces = SurfaceResolver.resolve(ws)
    assert Enum.any?(surfaces, &(&1.name == "localhost:8765" and &1.source == :detected))
  end

  test "embed_url maps loopback surfaces to the public manager URL" do
    local = SurfaceResolver.get(@v3_workspace, "app-local")
    assert local.url == "http://localhost:10100"

    assert SurfaceResolver.embed_url(@v3_workspace, local) ==
             "https://alice-feature.devbox.example.com"
  end

  test "primary_surface prefers app-local for agent control" do
    assert %{} = primary = SurfaceResolver.primary_surface(@v3_workspace)
    assert primary.name == "app-local"
    assert primary.url == "http://localhost:10100"
  end

  test "off-devbox folder workspaces prefer terminal-detected primary_surface" do
    previous_on_devbox = Application.get_env(:dev_ide, :on_devbox)
    previous_root = Application.get_env(:dev_ide, :workspaces_root)

    workspace =
      Path.join(System.tmp_dir!(), "surface-off-devbox-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    Application.put_env(:dev_ide, :workspaces_root, Path.dirname(workspace))
    Application.put_env(:dev_ide, :on_devbox, false)

    on_exit(fn ->
      File.rm_rf(workspace)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:workspaces_root, previous_root)
    end)

    ws = %{
      id: "local-folder",
      path: workspace,
      metadata: %{
        attached_folder: true,
        terminal_output: "Serving at http://localhost:5173/"
      }
    }

    surfaces = SurfaceResolver.resolve(ws)
    refute Enum.any?(surfaces, &(&1.source == :host))

    assert %{} = primary = SurfaceResolver.primary_surface(ws)
    assert primary.name == "localhost:5173"
    assert primary.source == :terminal
  end

  test "terminal surfaces are discovered from metadata terminal_output" do
    ws =
      Map.update!(@v3_workspace, :metadata, fn metadata ->
        Map.put(metadata, :terminal_output, "Serving at http://localhost:8765/")
      end)

    surfaces = SurfaceResolver.resolve(ws)
    assert Enum.any?(surfaces, &(&1.name == "localhost:8765" and &1.source == :terminal))
  end

  test "public surfaces are listed before loopback surfaces" do
    surfaces = SurfaceResolver.resolve(@v3_workspace)

    first_local =
      Enum.find_index(
        surfaces,
        &(String.ends_with?(&1.name, "-local") or String.starts_with?(&1.name, "localhost:"))
      )

    first_public =
      Enum.find_index(
        surfaces,
        &(not String.contains?(&1.url, "localhost") and not String.contains?(&1.url, "127.0.0.1"))
      )

    assert first_public < first_local
  end

  test "detected_ports surface as localhost terminal surfaces, even in v3 mode" do
    ws = put_in(@v3_workspace.metadata[:detected_ports], [4321])

    surfaces = SurfaceResolver.resolve(ws)
    detected = Enum.find(surfaces, &(&1.name == "localhost:4321"))

    assert detected
    assert detected.url == "http://localhost:4321"
    assert detected.port == 4321
    assert detected.source == :terminal
  end

  test "falls back to parsing stored terminal output when detected_ports absent" do
    ws = %{
      id: "legacy-detect",
      metadata: %{terminal_output: "Listening on http://localhost:6060/"}
    }

    surfaces = SurfaceResolver.resolve(ws)
    assert Enum.any?(surfaces, &(&1.name == "localhost:6060"))
  end

  defp restore_env(key, value) do
    if is_nil(value),
      do: Application.delete_env(:dev_ide, key),
      else: Application.put_env(:dev_ide, key, value)
  end
end
