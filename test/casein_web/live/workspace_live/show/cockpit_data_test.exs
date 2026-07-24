defmodule CaseinWeb.WorkspaceLive.Show.CockpitDataTest do
  @moduledoc """
  Direct unit coverage for the DB-free public functions of
  `CaseinWeb.WorkspaceLive.Show.CockpitData`.

  Covers only `lan_path_error/2` and `visible_workspace_summaries/2`. DB/HTTP
  helpers (`resolve_mount_workspace/3`, `fetch_agents_panels/3`,
  `workspace_summaries_for/1`) are intentionally out of scope.
  """
  use ExUnit.Case, async: false

  alias CaseinWeb.WorkspaceLive.Show.CockpitData

  setup do
    prev = Application.get_env(:casein, :lan_path_root)
    Application.put_env(:casein, :lan_path_root, "/lanroot")

    on_exit(fn ->
      if prev do
        Application.put_env(:casein, :lan_path_root, prev)
      else
        Application.delete_env(:casein, :lan_path_root)
      end
    end)

    :ok
  end

  describe "lan_path_error/2" do
    @params %{"lan_path" => ["foo", "bar"]}

    test "returns full map for :not_found with path segments" do
      error = CockpitData.lan_path_error(@params, :not_found)

      assert error.reason == :not_found
      assert error.title == "Directory not found"
      assert error.message == "directory was not found"
      assert error.route_path == "/foo/bar"
      assert error.relative_path == "foo/bar"
      assert error.root_path == "/lanroot"
      assert error.target_path == "/lanroot/foo/bar"
    end

    test "returns full map for :invalid_path with nil target_path" do
      error = CockpitData.lan_path_error(@params, :invalid_path)

      assert error.reason == :invalid_path
      assert error.title == "Invalid path"
      assert error.message == "path is invalid"
      assert error.route_path == "/foo/bar"
      assert error.relative_path == "foo/bar"
      assert error.root_path == "/lanroot"
      assert error.target_path == nil
    end

    test "returns reserved title and message for :reserved_prefix" do
      error = CockpitData.lan_path_error(@params, :reserved_prefix)

      assert error.reason == :reserved_prefix
      assert error.title == "Reserved path"
      assert error.message == "path is reserved by Casein"
      assert error.route_path == "/foo/bar"
      assert error.relative_path == "foo/bar"
      assert error.root_path == "/lanroot"
      assert error.target_path == nil
    end

    test "empty lan_path yields root route and empty relative path" do
      error = CockpitData.lan_path_error(%{}, :not_found)

      assert error.route_path == "/"
      assert error.relative_path == ""
      assert error.root_path == "/lanroot"
      assert error.target_path == "/lanroot"
    end
  end

  describe "visible_workspace_summaries/2" do
    @summaries [:a, :b]

    test "returns summaries unchanged for admin user with atom email key" do
      assert CockpitData.visible_workspace_summaries(@summaries, %{email: "x@y.z"}) == @summaries
    end

    test "returns summaries unchanged for admin user with string email key" do
      assert CockpitData.visible_workspace_summaries(@summaries, %{"email" => "x@y.z"}) ==
               @summaries
    end

    test "returns empty list for blank email" do
      assert CockpitData.visible_workspace_summaries(@summaries, %{email: "  "}) == []
    end

    test "returns empty list for empty map" do
      assert CockpitData.visible_workspace_summaries(@summaries, %{}) == []
    end

    test "returns empty list for nil user" do
      assert CockpitData.visible_workspace_summaries(@summaries, nil) == []
    end
  end
end
