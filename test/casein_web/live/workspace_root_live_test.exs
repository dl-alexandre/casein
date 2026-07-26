defmodule CaseinWeb.WorkspaceRootLiveTest do
  @moduledoc """
  Root `/` lands in the cockpit on the synthetic scratch workspace (Stage 4c).
  There is no full-page dashboard or workspace-admin drawer.
  """

  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Workspaces.Scratch
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    home = Path.join(System.tmp_dir!(), "casein-root-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    prev_home = Application.get_env(:casein, :home_workspace_path)
    Application.put_env(:casein, :home_workspace_path, home)

    on_exit(fn ->
      MemoryAdapter.clear()
      File.rm_rf(home)

      if is_nil(prev_home),
        do: Application.delete_env(:casein, :home_workspace_path),
        else: Application.put_env(:casein, :home_workspace_path, prev_home)
    end)

    {:ok, home: home}
  end

  test "GET / mounts the scratch cockpit without redirect loop", %{conn: conn, home: home} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ Scratch.id() or html =~ "Scratch" or
             has_element?(view, "#workspace-header-" <> Scratch.id())

    assert has_element?(view, "#workspace-header-" <> Scratch.id())
    assert has_element?(view, "#notifications-open-" <> Scratch.id())
    refute has_element?(view, "#workspace-admin-bell-" <> Scratch.id())
    # Mounted at home-rooted scratch — no bounce back through /.
    refute_redirected(view, ~p"/")
    assert Path.expand(home) == Scratch.home_path()
  end

  test "GET /workspaces redirects to root scratch cockpit", %{conn: conn} do
    conn = get(conn, ~p"/workspaces")
    assert redirected_to(conn) == ~p"/"
  end

  test "GET /notifications redirects to cockpit drawer deep link", %{conn: conn} do
    conn = get(conn, ~p"/notifications")
    assert redirected_to(conn) == ~p"/?drawer=notifications"
  end
end
