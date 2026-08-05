defmodule Casein.Previews.AccessTest do
  @moduledoc """
  `preview_port/1` decides which loopback ports a workspace has published, so a
  wrong answer here either strands a legitimate preview or nominates a port the
  workspace never exposed. These pin the shapes a registration can actually hold.
  """
  use ExUnit.Case, async: false

  alias Casein.Previews.Access

  @workspace "d4001a09-524d-4555-8e4a-5e65b8fdc271"

  setup do
    prev = Application.get_env(:casein, :preview_own_origin)

    Application.put_env(:casein, :preview_own_origin,
      enabled: true,
      domain: "devbox.milcgroup.com"
    )

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:casein, :preview_own_origin)
        val -> Application.put_env(:casein, :preview_own_origin, val)
      end
    end)

    :ok
  end

  describe "preview_port/1" do
    test "reads a direct loopback URL" do
      assert Access.preview_port("http://localhost:4003/") == 4003
      assert Access.preview_port("http://127.0.0.1:21005/login") == 21_005
    end

    test "reads a relative path-proxy URL" do
      assert Access.preview_port("/preview-proxy/#{@workspace}/4003/login") == 4003
      assert Access.preview_port("/preview-proxy/#{@workspace}/4003") == 4003
    end

    test "reads an own-origin preview host" do
      assert Access.preview_port("https://pv-4003-#{@workspace}.devbox.milcgroup.com/") == 4003
    end

    # Regression: URI.parse/1 supplies the scheme default port, so reading the
    # URI port first answered 443 for an absolute proxy URL — which both denies
    # the real port and nominates 127.0.0.1:443 as a registered preview port.
    test "reads the proxied port, not 443, from an ABSOLUTE path-proxy URL" do
      url = "https://casein.devbox.milcgroup.com/preview-proxy/#{@workspace}/4003/login"

      assert Access.preview_port(url) == 4003
    end

    test "ignores a scheme default port that the URL never spelled out" do
      assert Access.preview_port("https://casein.devbox.milcgroup.com/") == nil
      assert Access.preview_port("http://example.com/some/path") == nil
    end

    test "returns nil for shapes that name no port" do
      assert Access.preview_port("/artifact-projects/ws/proj/index.html") == nil
      assert Access.preview_port("") == nil
      assert Access.preview_port(nil) == nil
      assert Access.preview_port(%{}) == nil
    end
  end

  describe "validate_port/1" do
    test "accepts in-range ports as integer or string" do
      assert Access.validate_port(4003) == {:ok, 4003}
      assert Access.validate_port("4003") == {:ok, 4003}
    end

    test "rejects out-of-range and malformed ports" do
      assert Access.validate_port(0) == {:error, :bad_port}
      assert Access.validate_port(65_536) == {:error, :bad_port}
      assert Access.validate_port("4003x") == {:error, :bad_port}
      assert Access.validate_port(nil) == {:error, :bad_port}
    end
  end
end
