defmodule Casein.Previews.OwnOriginTest do
  use ExUnit.Case, async: false

  alias Casein.Previews.OwnOrigin

  @workspace "37a50042-54ca-4a6b-9f89-aa21ae5bf623"

  setup do
    prev = Application.get_env(:casein, :preview_own_origin)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:casein, :preview_own_origin)
        val -> Application.put_env(:casein, :preview_own_origin, val)
      end
    end)

    :ok
  end

  defp enable(opts \\ []) do
    Application.put_env(
      :casein,
      :preview_own_origin,
      Keyword.merge([enabled: true, domain: "devbox.milcgroup.com"], opts)
    )
  end

  describe "host/2 and origin/2" do
    test "encode the port and workspace into a single DNS label" do
      enable()

      assert {:ok, host} = OwnOrigin.host(@workspace, 21_005)
      assert host == "pv-21005-#{@workspace}.devbox.milcgroup.com"

      assert {:ok, "https://pv-21005-" <> _} = OwnOrigin.origin(@workspace, 21_005)
    end

    test "stay within the 63-character DNS label limit" do
      enable()

      {:ok, host} = OwnOrigin.host(@workspace, 65_535)
      [label | _] = String.split(host, ".")

      assert String.length(label) <= 63
    end

    test "refuse to build a host when own-origin routing is off" do
      Application.put_env(:casein, :preview_own_origin, enabled: false)

      assert OwnOrigin.host(@workspace, 21_005) == :error
      assert OwnOrigin.origin(@workspace, 21_005) == :error
    end

    # Folder-attached workspaces use `folder:<base64url>` ids, which a DNS label
    # cannot carry. Those previews must fall back to the path proxy rather than
    # produce a hostname that resolves nowhere.
    test "refuse workspace ids that are not hostname-safe" do
      enable()

      assert OwnOrigin.host("folder:L2RhdGEvd29ya3NwYWNlcw", 21_005) == :error
      assert OwnOrigin.host("__scratch__", 21_005) == :error
      assert OwnOrigin.host("not-a-uuid", 21_005) == :error
    end

    test "refuse ports outside the valid range" do
      enable()

      assert OwnOrigin.host(@workspace, 0) == :error
      assert OwnOrigin.host(@workspace, 65_536) == :error
      assert OwnOrigin.host(@workspace, -1) == :error
    end

    test "honour a configured domain" do
      enable(domain: "example.test")

      assert {:ok, "pv-3000-" <> rest} = OwnOrigin.host(@workspace, 3000)
      assert String.ends_with?(rest, ".example.test")
    end
  end

  describe "parse_host/1" do
    test "round-trips what host/2 builds" do
      enable()

      {:ok, host} = OwnOrigin.host(@workspace, 21_005)

      assert {:ok, %{workspace_id: @workspace, port: 21_005}} = OwnOrigin.parse_host(host)
    end

    # Authorization must keep working across a config flip, so parsing an
    # already-issued hostname cannot depend on the feature being switched on.
    test "works even when own-origin routing is disabled" do
      enable()
      {:ok, host} = OwnOrigin.host(@workspace, 4003)
      Application.put_env(:casein, :preview_own_origin, enabled: false)

      assert {:ok, %{workspace_id: @workspace, port: 4003}} = OwnOrigin.parse_host(host)
    end

    test "tolerates an explicit port suffix" do
      enable()
      {:ok, host} = OwnOrigin.host(@workspace, 4003)

      assert {:ok, %{port: 4003}} = OwnOrigin.parse_host(host <> ":8443")
    end

    test "rejects hosts that are not preview hosts" do
      assert OwnOrigin.parse_host("casein.devbox.milcgroup.com") == :error
      assert OwnOrigin.parse_host("mtinker-farm-stage.devbox.milcgroup.com") == :error
      assert OwnOrigin.parse_host("pv-21005.devbox.milcgroup.com") == :error
      assert OwnOrigin.parse_host("") == :error
      assert OwnOrigin.parse_host(nil) == :error
    end

    test "rejects a malformed port or workspace" do
      assert OwnOrigin.parse_host("pv-notaport-#{@workspace}.devbox.milcgroup.com") == :error
      assert OwnOrigin.parse_host("pv-0-#{@workspace}.devbox.milcgroup.com") == :error
      assert OwnOrigin.parse_host("pv-99999-#{@workspace}.devbox.milcgroup.com") == :error
      assert OwnOrigin.parse_host("pv-3000-not-a-uuid.devbox.milcgroup.com") == :error
    end
  end
end
