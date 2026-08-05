defmodule Casein.PreviewPanesPaneLivenessTest do
  @moduledoc """
  What keeps a persisted preview-pane registration alive across a Casein restart.

  A browser control session is a Playwright runtime: it dies whenever Casein
  restarts, while the tmux pane and the dev server behind it carry on. Treating
  that as "the registration is gone" made the first `list_for_workspace/1` after
  every deploy permanently close every open registration — which refused previews
  on agent-chosen ports until the pane happened to re-register, and churned
  hundreds of closed rows for a single pane.

  So the pane, and only the pane, decides.
  """
  use Casein.DataCase, async: false

  alias Casein.PreviewPanes
  alias Casein.PreviewPanes.PreviewPaneRegistration

  @session "casein_liveness_test"

  defmodule PaneAliveTerminals do
    @moduledoc false
    def list_session_panes(_session), do: [%{id: "%42"}, %{id: "%43"}]
    def topology_subscribe(_session), do: :ok
  end

  defmodule PaneGoneTerminals do
    @moduledoc false
    def list_session_panes(_session), do: [%{id: "%99"}]
    def topology_subscribe(_session), do: :ok
  end

  setup do
    prev = Application.fetch_env!(:casein, :preview_deps)

    on_exit(fn -> Application.put_env(:casein, :preview_deps, prev) end)

    {:ok, prev_deps: prev}
  end

  defp with_terminals(impl, %{prev_deps: prev}) do
    Application.put_env(:casein, :preview_deps, Keyword.put(prev, :terminals, impl))
  end

  defp registration(opts \\ []) do
    %PreviewPaneRegistration{
      status: Keyword.get(opts, :status, :open),
      tmux_session: Keyword.get(opts, :tmux_session, @session),
      pane_id: Keyword.get(opts, :pane_id, "%42"),
      workspace_id: "d4001a09-524d-4555-8e4a-5e65b8fdc271",
      url: "http://localhost:4003/",
      preview: Keyword.get(opts, :preview),
      control_session: Keyword.get(opts, :control_session)
    }
  end

  # The regression. Both are closed exactly as a restart leaves them, and the
  # registration must survive anyway.
  test "a live pane stays live with a dead browser control pair", ctx do
    with_terminals(PaneAliveTerminals, ctx)

    reg =
      registration(
        preview: %Casein.Previews.Preview{status: :closed},
        control_session: %Casein.Previews.ControlSession{status: :closed}
      )

    assert PreviewPanes.persisted_pane_live?(reg)
  end

  test "a live pane stays live with no control session at all", ctx do
    with_terminals(PaneAliveTerminals, ctx)

    assert PreviewPanes.persisted_pane_live?(registration())
  end

  test "a pane that is gone from tmux is not live", ctx do
    with_terminals(PaneGoneTerminals, ctx)

    refute PreviewPanes.persisted_pane_live?(registration(pane_id: "%42"))
  end

  # Deliberate teardown must still win: those paths set status: :closed, and a
  # closed row must never be revived just because its pane happens to exist.
  test "a closed registration is never live, even with a live pane", ctx do
    with_terminals(PaneAliveTerminals, ctx)

    refute PreviewPanes.persisted_pane_live?(registration(status: :closed))
  end

  test "a registration without a tmux session is not live", ctx do
    with_terminals(PaneAliveTerminals, ctx)

    refute PreviewPanes.persisted_pane_live?(registration(tmux_session: nil))
    refute PreviewPanes.persisted_pane_live?(registration(tmux_session: ""))
  end

  test "non-registration input is not live", ctx do
    with_terminals(PaneAliveTerminals, ctx)

    refute PreviewPanes.persisted_pane_live?(%{pane_id: "%42"})
    refute PreviewPanes.persisted_pane_live?(nil)
  end
end
