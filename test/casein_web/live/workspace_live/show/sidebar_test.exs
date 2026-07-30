defmodule CaseinWeb.WorkspaceLive.Show.SidebarTest do
  @moduledoc """
  Direct-call unit tests for pure public functions of
  `CaseinWeb.WorkspaceLive.Show.Sidebar`.

  Avoids functions that need the full session tree (open/1, reveal_sessions/1,
  assign_sessions_sidebar_tree/1). Every socket keeps `window_sidebar_open?: false`
  so `assign_windows_sidebar_tree/1` short-circuits to `[]`.
  """
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show.Sidebar

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}

  defp windows_socket(assigns \\ %{}) do
    socket(
      Map.merge(
        %{
          sidebar_expanded_windows: MapSet.new(),
          window_sidebar_open?: false,
          windows_sidebar_sort: :recency,
          windows_sidebar_tree: []
        },
        assigns
      )
    )
  end

  describe "initial_assigns/0" do
    test "returns closed sidebar defaults" do
      assigns = Sidebar.initial_assigns()

      assert assigns[:sidebar_mode] == :closed
      assert assigns[:window_sidebar_open?] == false
      assert assigns[:sessions_sidebar_open?] == false
      assert assigns[:sessions_sidebar_sort] == :recency
      assert assigns[:windows_sidebar_sort] == :recency
      assert assigns[:sidebar_expanded_windows] == MapSet.new()
    end
  end

  describe "toggle_window/2" do
    test "adds then removes a window id from the expanded set" do
      s = windows_socket()

      result = Sidebar.toggle_window(s, "win-1")
      assert MapSet.member?(result.assigns.sidebar_expanded_windows, "win-1") == true
      assert result.assigns.windows_sidebar_tree == []

      result = Sidebar.toggle_window(result, "win-1")
      assert MapSet.member?(result.assigns.sidebar_expanded_windows, "win-1") == false
      assert result.assigns.windows_sidebar_tree == []
    end
  end

  describe "set_windows_sort/3" do
    test "sets a valid sort mode with persist: false" do
      s = windows_socket(%{windows_sidebar_sort: :recency})
      result = Sidebar.set_windows_sort(s, :name, persist: false)
      assert result.assigns.windows_sidebar_sort == :name
      assert result.assigns.windows_sidebar_tree == []
    end

    test "invalid mode leaves sort unchanged via fallback clause" do
      s = windows_socket(%{windows_sidebar_sort: :recency})
      result = Sidebar.set_windows_sort(s, :bogus, persist: false)
      assert result.assigns.windows_sidebar_sort == :recency
    end
  end

  describe "restore_sort/3" do
    test "restores windows sort from a valid client string" do
      s = windows_socket(%{windows_sidebar_sort: :recency})
      result = Sidebar.restore_sort(s, "windows", "name")
      assert result.assigns.windows_sidebar_sort == :name
    end

    test "invalid windows sort string falls back to :recency" do
      s = windows_socket(%{windows_sidebar_sort: :name})
      result = Sidebar.restore_sort(s, "windows", "garbage")
      assert result.assigns.windows_sidebar_sort == :recency
    end

    test "unknown column leaves sort unchanged" do
      s = windows_socket(%{windows_sidebar_sort: :recency})
      result = Sidebar.restore_sort(s, "other", "name")
      assert result.assigns.windows_sidebar_sort == :recency
    end
  end

  describe "handle_async_warm/3" do
    test "non-ok fallback clears only that batch's pending ids" do
      s = socket(%{sidebar_ws_warm_pending: MapSet.new(["ws-a", "ws-b", "ws-c"])})
      result = Sidebar.handle_async_warm(s, ["ws-a", "ws-b"], :some_error)
      assert result.assigns.sidebar_ws_warm_pending == MapSet.new(["ws-c"])
    end
  end

  describe "warm_sessions/1" do
    test "is a no-op while the sessions rail is closed" do
      s = socket(%{sessions_sidebar_open?: false})
      assert Sidebar.warm_sessions(s) == s
    end
  end
end
