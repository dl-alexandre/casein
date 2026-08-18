defmodule Casein.Terminals.TmuxScopeTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxScope
  alias Casein.Workspace
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    on_exit(fn -> MemoryAdapter.clear() end)
  end

  test "accepts tmux sessions prefixed by workspace name or id" do
    workspace = %Workspace{id: "ws-1", name: "alpha"}

    assert TmuxScope.session_in_workspace?(Tmux.session_name("alpha", "u-dev"), workspace)
    assert TmuxScope.session_in_workspace?(Tmux.session_name("ws-1", "u-dev"), workspace)
    refute TmuxScope.session_in_workspace?(Tmux.session_name("other", "u-dev"), workspace)
  end

  test "resolves persisted workspace names for id-only REST checks" do
    {:ok, _record} =
      Casein.Workspaces.State.sync(%Workspace{
        id: "ws-1",
        name: "alpha",
        path: "/workspace",
        status: :running
      })

    assert TmuxScope.session_in_workspace?(Tmux.session_name("alpha", "api"), "ws-1")
    assert TmuxScope.session_in_workspace?(Tmux.session_name("ws-1", "api"), "ws-1")
    refute TmuxScope.session_in_workspace?(Tmux.session_name("beta", "api"), "ws-1")
  end

  test "equivalent_session? treats workspace name and id prefixes as the same sid" do
    workspace = %Workspace{id: "ws-1", name: "alpha"}

    assert TmuxScope.equivalent_session?(
             Tmux.session_name("alpha", "u-dev"),
             Tmux.session_name("ws-1", "u-dev"),
             workspace
           )

    refute TmuxScope.equivalent_session?(
             Tmux.session_name("alpha", "u-dev"),
             Tmux.session_name("alpha", "wt-other"),
             workspace
           )

    refute TmuxScope.equivalent_session?(
             Tmux.session_name("alpha", "u-dev"),
             Tmux.session_name("other", "u-dev"),
             workspace
           )
  end
end
