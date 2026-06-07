defmodule DevIDE.Previews.UrlTest do
  use ExUnit.Case, async: true

  alias DevIDE.Previews.Url

  @v3_workspace %{
    metadata: %{
      domain_base: "alice-feature.devbox.example.com"
    }
  }

  test "trusted_embed? accepts localhost dev servers" do
    assert Url.trusted_embed?("http://localhost:4000")
    assert Url.trusted_embed?("http://127.0.0.1:5173")
  end

  test "trusted_embed? accepts workspace-owned v3 domains" do
    origins = Url.allowed_origins(@v3_workspace)

    assert Url.trusted_embed?("https://alice-feature.devbox.example.com", origins)
    assert Url.trusted_embed?("https://tidewave.alice-feature.devbox.example.com", origins)
    refute Url.trusted_embed?("https://evil.example.com", origins)
  end

  test "within_origin? blocks cross-origin navigation" do
    origins = Url.allowed_origins(@v3_workspace)
    base = "https://alice-feature.devbox.example.com"

    assert Url.within_origin?("/dashboard", base, origins)
    refute Url.within_origin?("https://evil.example.com", base, origins)
  end
end
