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

  describe "registerable_loopback_port?/2" do
    test "accepts ordinary dev / ephemeral ports (FileServer escape hatch)" do
      ws = %{id: @workspace, metadata: %{}}

      assert Access.registerable_loopback_port?(5173, ws)
      assert Access.registerable_loopback_port?(41_050, ws)
      assert Access.registerable_loopback_port?(21_005, ws)
      assert Access.registerable_loopback_port?(9_999, ws)
    end

    test "rejects infrastructure ports registration must never widen to (#927)" do
      ws = %{id: @workspace, metadata: %{}}

      # FAIL case: SSH / Postgres / Redis / Mongo — registration cannot mint these.
      refute Access.registerable_loopback_port?(22, ws)
      refute Access.registerable_loopback_port?(5432, ws)
      refute Access.registerable_loopback_port?(6379, ws)
      refute Access.registerable_loopback_port?(27_017, ws)
      assert Access.denied_infra_port?(5432)
      refute Access.denied_infra_port?(5173)
    end
  end

  describe "port_allowed?/3 — registration is not a free SSRF widen (#927)" do
    test "owned non-infra port is allowed without registration" do
      ws = %{id: @workspace, metadata: %{"ports" => %{"http" => 4105}}}
      assert Casein.Previews.workspace_owned_port?(4105, ws)
      refute Access.denied_infra_port?(4105)
    end

    test "denied infra port is never registerable even if 'owned' in metadata" do
      # Even a malicious metadata.ports entry naming Postgres must not pass the
      # registerable gate (Access.port_allowed? ANDs this with registration).
      ws = %{id: @workspace, metadata: %{"ports" => %{"db" => 5432}}}
      assert Casein.Previews.workspace_owned_port?(5432, ws)
      refute Access.registerable_loopback_port?(5432, ws)
      assert Access.denied_infra_port?(5432)
      # Owned + denied must not authorize: first clause of port_allowed? is
      # owned AND not denied.
      refute Casein.Previews.workspace_owned_port?(5432, ws) and
               not Access.denied_infra_port?(5432)
    end
  end

  describe "authorization_description/0 — MCP prose is derived from the predicate" do
    test "names both denial tokens and has no time component" do
      text = Access.authorization_description()
      assert text =~ ":forbidden"
      assert text =~ ":port_not_allowed"
      refute text =~ "few minutes after every deploy"
      refute text =~ "recently started"
      refute text =~ "boot_at"
    end

    test "port_allowed?/3 source has no time component" do
      src = File.read!("lib/casein/previews/access.ex")
      [_before, rest] = String.split(src, "def port_allowed?", parts: 2)
      [predicate | _] = String.split(rest, "\n  def ", parts: 2)
      refute predicate =~ ~r/deploy|grace|DateTime|monotonic|System\.os_time/
    end

    test "deny_payload/1 keeps :forbidden distinct from :port_not_allowed" do
      forbidden = Access.deny_payload(:forbidden)
      port = Access.deny_payload(:port_not_allowed)

      assert forbidden.reason == :forbidden
      assert port.reason == :port_not_allowed
      assert forbidden.error == :forbidden
      assert port.error == :port_not_allowed
    end
  end
end
