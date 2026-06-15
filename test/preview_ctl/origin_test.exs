defmodule PreviewCtl.OriginTest do
  use ExUnit.Case, async: true

  alias PreviewCtl.Origin

  test "trusted_embed? accepts localhost dev servers" do
    assert Origin.trusted_embed?("http://localhost:4000")
    assert Origin.trusted_embed?("http://127.0.0.1:5173")
  end

  test "trusted_embed? accepts external http origins" do
    origins = ["https://alice-feature.devbox.example.com"]

    assert Origin.trusted_embed?("https://alice-feature.devbox.example.com", origins)
    assert Origin.trusted_embed?("https://tidewave.alice-feature.devbox.example.com", origins)
    assert Origin.trusted_embed?("https://evil.example.com", origins)
    refute Origin.trusted_embed?("file:///etc/passwd", origins)
  end

  test "within_origin? accepts cross-origin http navigation" do
    origins = ["https://alice-feature.devbox.example.com"]
    base = "https://alice-feature.devbox.example.com"

    assert Origin.within_origin?("/dashboard", base, origins)
    assert Origin.within_origin?("https://evil.example.com", base, origins)
    refute Origin.within_origin?("javascript:alert(1)", base, origins)
  end

  test "resolve_against normalizes absolute paths" do
    assert Origin.resolve_against("/settings", "https://alice.devbox.example.com/app") ==
             "https://alice.devbox.example.com:443/settings"
  end

  test "normalize_localhost rewrites loopback hosts" do
    assert Origin.normalize_localhost("http://127.0.0.1:4000") == "http://localhost:4000"
  end
end
