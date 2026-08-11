defmodule Casein.Previews.ExternalOriginsTest do
  use ExUnit.Case, async: true

  alias Casein.Previews.ExternalOrigins

  setup do
    previous = Application.get_env(:casein, :preview_external_origins)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:casein, :preview_external_origins)
      else
        Application.put_env(:casein, :preview_external_origins, previous)
      end
    end)

    :ok
  end

  defp configure(origins), do: Application.put_env(:casein, :preview_external_origins, origins)

  describe "allowlist/1" do
    test "is empty by default so the lane is off until an operator opts in" do
      Application.delete_env(:casein, :preview_external_origins)

      assert ExternalOrigins.allowlist(%{}) == []
    end

    test "normalizes configured entries to scheme://host:port" do
      configure(["https://dev.example.com", "http://staging.example.test:8080"])

      assert ExternalOrigins.allowlist() == [
               "https://dev.example.com:443",
               "http://staging.example.test:8080"
             ]
    end

    test "reads a bare host as https rather than dropping it" do
      configure(["dev.example.com"])

      assert ExternalOrigins.allowlist() == ["https://dev.example.com:443"]
    end

    test "unions the deployment allowlist with workspace metadata" do
      configure(["https://dev.example.com"])

      workspace = %{metadata: %{"external_preview_origins" => ["https://other.example.test"]}}

      assert ExternalOrigins.allowlist(workspace) == [
               "https://dev.example.com:443",
               "https://other.example.test:443"
             ]
    end

    test "ignores non-string and unparseable metadata entries" do
      configure([])
      workspace = %{metadata: %{external_preview_origins: ["ftp://nope.example.test", 42]}}

      assert ExternalOrigins.allowlist(workspace) == []
    end
  end

  describe "validate/2" do
    test "accepts a URL whose origin is allowlisted" do
      configure(["https://dev.example.com"])

      assert {:ok, "https://dev.example.com/login"} =
               ExternalOrigins.validate("https://dev.example.com/login", %{})
    end

    test "accepts a subdomain of an allowlisted host" do
      configure(["https://example.com"])

      assert {:ok, _} = ExternalOrigins.validate("https://dev.example.com/login", %{})
    end

    test "refuses a lookalike host that merely ends with the allowlisted string" do
      configure(["https://example.com"])

      assert {:error, %{error: :external_origin_not_allowed}} =
               ExternalOrigins.validate("https://example.com.evil.test/login", %{})
    end

    test "refuses a scheme downgrade on an allowlisted host" do
      configure(["https://dev.example.com"])

      assert {:error, %{error: :external_origin_not_allowed}} =
               ExternalOrigins.validate("http://dev.example.com/login", %{})
    end

    test "refuses a different port on an allowlisted host" do
      configure(["https://dev.example.com"])

      assert {:error, %{error: :external_origin_not_allowed}} =
               ExternalOrigins.validate("https://dev.example.com:8443/login", %{})
    end

    test "names the env var when nothing is allowlisted" do
      Application.delete_env(:casein, :preview_external_origins)

      assert {:error, error} = ExternalOrigins.validate("https://dev.example.com/login", %{})
      assert error.error == :external_previews_not_configured
      assert error.env_var == "CASEIN_PREVIEW_EXTERNAL_ORIGINS"
      assert error.workspace_metadata_key == "external_preview_origins"
    end

    test "lists what is allowed when the origin is refused" do
      configure(["https://dev.example.com"])

      assert {:error, error} = ExternalOrigins.validate("https://elsewhere.test/login", %{})
      assert error.origin == "https://elsewhere.test:443"
      assert error.allowed_origins == ["https://dev.example.com:443"]
    end

    test "refuses non-http(s) and non-string urls before consulting the allowlist" do
      configure(["https://dev.example.com"])

      assert {:error, %{error: :invalid_external_url}} =
               ExternalOrigins.validate("file:///etc/passwd", %{})

      assert {:error, %{error: :invalid_external_url}} =
               ExternalOrigins.validate("dev.example.com/login", %{})

      assert {:error, %{error: :invalid_external_url}} = ExternalOrigins.validate(nil, %{})
    end

    test "a workspace-scoped allowlist does not leak to a workspace that lacks it" do
      configure([])
      allowed = %{metadata: %{"external_preview_origins" => ["https://dev.example.com"]}}

      assert {:ok, _} = ExternalOrigins.validate("https://dev.example.com/login", allowed)

      assert {:error, %{error: :external_previews_not_configured}} =
               ExternalOrigins.validate("https://dev.example.com/login", %{metadata: %{}})
    end
  end
end
