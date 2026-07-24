defmodule Casein.Previews.UrlTest do
  use Casein.TestCase, async: true

  alias Casein.Previews.Url

  @v3_workspace %{
    metadata: %{
      domain_base: "alice-feature.devbox.example.com"
    }
  }

  test "trusted_embed? accepts localhost dev servers" do
    assert Url.trusted_embed?("http://localhost:4000")
    assert Url.trusted_embed?("http://127.0.0.1:5173")
  end

  test "trusted_embed? enforces allowed origins" do
    origins = Url.allowed_origins(@v3_workspace)

    assert Url.trusted_embed?("https://alice-feature.devbox.example.com", origins)
    assert Url.trusted_embed?("https://tidewave.alice-feature.devbox.example.com", origins)
    refute Url.trusted_embed?("https://evil.example.com", origins)
    refute Url.trusted_embed?("file:///etc/passwd", origins)
  end

  test "allowed_origins includes the legacy local.<domain_base> app host" do
    origins = Url.allowed_origins(@v3_workspace)

    assert Url.trusted_embed?("https://local.alice-feature.devbox.example.com", origins)
  end

  test "allowed_origins includes terminal-detected localhost ports" do
    ws = %{
      metadata: %{
        detected_ports: [8765]
      }
    }

    origins = Url.allowed_origins(ws)
    assert "http://localhost:8765" in origins
    assert Url.port_allowed?(8765, ws)
    refute Url.port_allowed?(9999, ws)
  end

  test "common dev ports are allowed for agent control but not treated as workspace-owned" do
    ws = %{metadata: %{ports: %{"app" => 8765}, detected_ports: [9876]}}

    assert Url.port_allowed?(4000, ws)
    refute Url.workspace_owned_port?(4000, ws)
    assert Url.workspace_owned_port?(8765, ws)
    assert Url.workspace_owned_port?(9876, ws)
  end

  test "within_origin? rejects navigation outside allowed origins" do
    origins = Url.allowed_origins(@v3_workspace)
    base = "https://alice-feature.devbox.example.com"

    assert Url.within_origin?("/dashboard", base, origins)
    refute Url.within_origin?("https://evil.example.com", base, origins)
    refute Url.within_origin?("javascript:alert(1)", base, origins)
  end
end
