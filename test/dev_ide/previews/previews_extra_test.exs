defmodule DevIDE.PreviewsExtraTest do
  use DevIde.DataCase, async: true

  alias DevIDE.Previews
  alias DevIDE.Previews.{Preview, Surface}

  @workspace %{id: "ws-extra-1"}

  describe "extract_title_from_url/1" do
    test "derives host:port for a non-default port" do
      assert Previews.extract_title_from_url("http://localhost:4000/path") == "localhost:4000"
      assert Previews.extract_title_from_url("http://example.com:8080") == "example.com:8080"
    end

    test "omits the port for standard http (80) and https (443)" do
      assert Previews.extract_title_from_url("http://example.com") == "example.com"
      assert Previews.extract_title_from_url("https://example.com") == "example.com"
    end

    test "falls back to the \"preview\" host when the URL has no host" do
      # No host -> host defaults to "preview"; no port -> ":#{nil}" suffix.
      assert Previews.extract_title_from_url("/relative/path") == "preview:"
    end

    test "non-binary input falls back to \"Preview\"" do
      assert Previews.extract_title_from_url(nil) == "Preview"
      assert Previews.extract_title_from_url(%{}) == "Preview"
      assert Previews.extract_title_from_url(:atom) == "Preview"
    end
  end

  describe "surface_key_for_url/1" do
    test "localhost http URLs collapse to localhost:port" do
      assert Previews.surface_key_for_url("http://localhost:4000/route") == "localhost:4000"
      assert Previews.surface_key_for_url("http://127.0.0.1:4000") == "localhost:4000"
      assert Previews.surface_key_for_url("http://0.0.0.0:5173/x") == "localhost:5173"
    end

    test "localhost https URLs are prefixed and keep the scheme" do
      assert Previews.surface_key_for_url("https://localhost:8443") == "https://localhost:8443"
    end

    test "non-loopback hosts produce an origin key" do
      assert Previews.surface_key_for_url("http://example.com/page") ==
               "origin:http://example.com:80"

      assert Previews.surface_key_for_url("https://example.com:9000") ==
               "origin:https://example.com:9000"
    end

    test "non-http and non-binary URLs return nil" do
      assert Previews.surface_key_for_url("file:///etc/passwd") == nil
      assert Previews.surface_key_for_url("not a url") == nil
      assert Previews.surface_key_for_url(nil) == nil
      assert Previews.surface_key_for_url(123) == nil
    end
  end

  describe "surface_key_for_surface/1" do
    test "named surfaces normalize the name (trim + downcase)" do
      surface = %Surface{name: "  App  ", url: "http://localhost:4000", source: :manager}
      assert Previews.surface_key_for_surface(surface) == "app"
    end

    test "blank-named surfaces fall back to the URL key" do
      surface = %Surface{name: "   ", url: "http://localhost:4000", source: :manager}
      assert Previews.surface_key_for_surface(surface) == "localhost:4000"
    end

    test "atom and binary names normalize to a string key" do
      assert Previews.surface_key_for_surface(:Tidewave) == "tidewave"
      assert Previews.surface_key_for_surface("API Gateway") == "api gateway"
    end

    test "unsupported inputs return nil" do
      assert Previews.surface_key_for_surface(nil) == nil
      assert Previews.surface_key_for_surface(123) == nil
    end
  end

  describe "trusted_url?/1,2,3" do
    test "arity 1 trusts loopback http and rejects non-http" do
      assert Previews.trusted_url?("http://localhost:4000")
      refute Previews.trusted_url?("file:///etc/passwd")
      refute Previews.trusted_url?(nil)
    end

    test "arity 2 with a workspace map trusts that workspace's declared origins" do
      ws = %{
        id: "ws-trust",
        metadata: %{
          type: :v3,
          domain_base: "alice.devbox.example.com",
          ports: %{"app" => 10_100}
        }
      }

      assert Previews.trusted_url?("https://alice.devbox.example.com", ws)
      assert Previews.trusted_url?("http://localhost:4000", ws)
    end

    test "arity 3 with an explicit allowed-origins list" do
      origins = ["http://localhost:4000"]
      assert Previews.trusted_url?("http://localhost:4000/path", origins)
      refute Previews.trusted_url?("file:///etc/passwd", origins)
    end
  end

  describe "find_open_for_attrs/2" do
    test "non-binary workspace_id hits the catch-all and returns nil" do
      assert Previews.find_open_for_attrs(nil, %{url: "http://localhost:4000"}) == nil
      assert Previews.find_open_for_attrs(:ws, %{url: "http://localhost:4000"}) == nil
    end

    test "non-map attrs hit the catch-all and return nil" do
      assert Previews.find_open_for_attrs("ws-extra-1", nil) == nil
      assert Previews.find_open_for_attrs("ws-extra-1", "url") == nil
    end

    test "returns nil when attrs carry neither a surface key nor a URL" do
      assert Previews.find_open_for_attrs("ws-extra-1", %{}) == nil
    end

    test "matches the open preview for the same workspace + URL" do
      {:ok, preview} = Previews.open(@workspace, %{url: "http://example.com:7000"})

      assert %Preview{id: id} =
               Previews.find_open_for_attrs("ws-extra-1", %{url: "http://example.com:7000"})

      assert id == preview.id
    end
  end

  describe "discover_candidates/1" do
    test "extracts localhost URLs from terminal output" do
      [candidate | _] =
        Previews.discover_candidates("Server running at http://localhost:5173/ ready")

      assert candidate.url == "http://localhost:5173/"
      assert candidate.port == 5173
      assert candidate.title == "localhost:5173"
    end

    test "returns [] for output with no host markers" do
      assert Previews.discover_candidates("compiling deps, nothing to preview here") == []
    end

    test "returns [] for non-binary input" do
      assert Previews.discover_candidates(nil) == []
      assert Previews.discover_candidates(%{}) == []
    end
  end

  describe "get_for_workspace/2 and get_for_workspace!/2" do
    test "returns nil for an unknown id in a valid workspace" do
      assert Previews.get_for_workspace(-1, "ws-extra-1") == nil
    end

    test "get_for_workspace!/2 returns the record when present" do
      {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:4000"})
      assert %Preview{} = found = Previews.get_for_workspace!(preview.id, "ws-extra-1")
      assert found.id == preview.id
    end

    test "get_for_workspace!/2 raises NoResultsError when absent" do
      assert_raise Ecto.NoResultsError, fn ->
        Previews.get_for_workspace!(-1, "ws-extra-1")
      end
    end
  end

  describe "update_url/4" do
    test "returns nil when the preview does not exist" do
      assert Previews.update_url(-1, "ws-extra-1", "http://localhost:4000") == nil
    end

    test "updates url, recomputes title, and records source_url metadata" do
      {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:4000"})

      assert {:ok, %Preview{} = updated} =
               Previews.update_url(preview.id, "ws-extra-1", "http://localhost:5173/dash",
                 source_url: "https://whitehouse.gov"
               )

      assert updated.url == "http://localhost:5173/dash"
      assert updated.title == "localhost:5173"
      assert updated.metadata["display_url"] == "http://localhost:5173/dash"
      assert updated.metadata["source_url"] == "https://whitehouse.gov"
    end

    test "clears a stale source_url when none is supplied" do
      {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:4000"})

      {:ok, _} =
        Previews.update_url(preview.id, "ws-extra-1", "http://localhost:4000",
          source_url: "https://example.com"
        )

      assert {:ok, %Preview{} = cleared} =
               Previews.update_url(preview.id, "ws-extra-1", "http://localhost:4000")

      refute Map.has_key?(cleared.metadata, "source_url")
    end

    test "returns a changeset error when the new url is not embeddable" do
      {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:4000"})

      assert {:error, %Ecto.Changeset{}} =
               Previews.update_url(preview.id, "ws-extra-1", "ftp://localhost:21/file")
    end
  end

  describe "get_for_viewer/2" do
    test "returns the preview directly when it belongs to the viewer workspace" do
      {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:4000"})

      assert %Preview{id: id} = Previews.get_for_viewer(preview.id, @workspace)
      assert id == preview.id
    end

    test "returns nil for an unknown id with no linked source workspace" do
      assert Previews.get_for_viewer(-1, %{id: "ws-extra-unlinked"}) == nil
    end
  end
end
