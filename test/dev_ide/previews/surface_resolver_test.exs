defmodule DevIDE.Previews.SurfaceResolverTest do
  use ExUnit.Case, async: true

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
end
