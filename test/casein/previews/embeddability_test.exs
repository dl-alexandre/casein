defmodule Casein.Previews.EmbeddabilityTest do
  use ExUnit.Case, async: true

  alias Casein.Previews.Embeddability

  describe "frame_blocked?/1" do
    test "X-Frame-Options DENY / SAMEORIGIN block" do
      assert Embeddability.frame_blocked?(%{"x-frame-options" => ["DENY"]})
      assert Embeddability.frame_blocked?(%{"x-frame-options" => "SAMEORIGIN"})
      assert Embeddability.frame_blocked?(%{"x-frame-options" => ["sameorigin"]})
    end

    test "CSP frame-ancestors without a wildcard blocks" do
      assert Embeddability.frame_blocked?(%{
               "content-security-policy" => ["frame-ancestors 'none'"]
             })

      assert Embeddability.frame_blocked?(%{
               "content-security-policy" => "frame-ancestors 'self'; default-src 'self'"
             })

      assert Embeddability.frame_blocked?(%{
               "content-security-policy" => "frame-ancestors https://example.com"
             })
    end

    test "CSP frame-ancestors with a wildcard does not block" do
      refute Embeddability.frame_blocked?(%{
               "content-security-policy" => "frame-ancestors *"
             })

      refute Embeddability.frame_blocked?(%{
               "content-security-policy" => "frame-ancestors https://*.example.com"
             })
    end

    test "no framing headers does not block" do
      refute Embeddability.frame_blocked?(%{"content-type" => ["text/html"]})
      refute Embeddability.frame_blocked?(%{})
    end

    test "X-Frame-Options ALLOWALL / unknown values do not block" do
      refute Embeddability.frame_blocked?(%{"x-frame-options" => ["ALLOWALL"]})
    end

    test "non-map input is safe" do
      refute Embeddability.frame_blocked?(nil)
      refute Embeddability.frame_blocked?("nope")
    end
  end

  describe "frame_blocked_url?/2" do
    test "non-binary input returns false" do
      refute Embeddability.frame_blocked_url?(nil)
    end

    test "an unreachable URL is treated as not-blocked (lenient)" do
      # Reserved TEST-NET-1 address, connection refused/timeout fast.
      refute Embeddability.frame_blocked_url?("http://192.0.2.1:9/x", timeout_ms: 200)
    end
  end
end
