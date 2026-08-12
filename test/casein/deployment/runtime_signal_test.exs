defmodule Casein.Deployment.RuntimeSignalTest do
  use ExUnit.Case, async: true

  alias Casein.Deployment.RuntimeSignal
  alias Casein.Terminals.Backends
  alias Casein.Terminals.Tmux

  @now ~U[2026-08-11 12:00:00Z]
  @remote String.duplicate("a", 40)
  @deployed "aaaaaaa"

  describe "snapshot/1 revision" do
    test "current when deployed prefixes remote head" do
      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:ok, @remote},
          branch: "master",
          now: @now,
          env: fn _ -> nil end,
          backend_module: Backends.Tmux
        )

      assert snap.revision.status == "current"
      assert snap.revision.deployed == @deployed
      assert snap.revision.remote == @remote
      assert snap.revision.branch == "master"
      assert snap.generated_at == DateTime.to_iso8601(@now)
    end

    test "drift when SHA differs" do
      snap =
        RuntimeSignal.snapshot(
          version: "bbbbbbb",
          remote: {:ok, @remote},
          branch: "master",
          now: @now,
          env: fn _ -> nil end,
          backend_module: Backends.Tmux
        )

      assert snap.revision.status == "drift"
      assert snap.revision.drift_reason == "revision_differs"
      assert snap.diverged? == true
      assert "revision_drift" in snap.attention
    end

    test "unknown remote stays unknown not current" do
      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:error, :nxdomain},
          branch: "master",
          now: @now,
          env: fn _ -> nil end,
          backend_module: Backends.Tmux
        )

      assert snap.revision.status == "unknown"
      assert snap.revision.remote_error
      refute snap.revision.status == "current"
      assert "revision_unknown" in snap.attention
    end
  end

  describe "snapshot/1 modules — converged tmux_adapter (#892)" do
    test "when :tmux_adapter unset, MCP and ops share Terminals.Tmux default" do
      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:ok, @remote},
          now: @now,
          env: fn _ -> nil end,
          # Backend.module may still be Backends.Tmux — that is the product
          # engine, not the MCP pane-write adapter after #892.
          backend_module: Backends.Tmux
        )

      ta = snap.modules.tmux_adapter

      assert ta.configured == nil
      assert ta.configured? == false
      assert ta.repo_default == "Casein.Terminals.Tmux"
      assert ta.backend_module == "Casein.Terminals.Backends.Tmux"
      # Agents via Shared.tmux/0 → Terminals.tmux_adapter/0
      assert ta.mcp_resolved == "Casein.Terminals.Tmux"
      assert ta.mcp_source == "tmux_adapter_default"
      # Ops via the same Terminals.tmux_adapter/0
      assert ta.ops_resolved == "Casein.Terminals.Tmux"
      assert ta.ops_source == "tmux_adapter_default"
      assert ta.paths_disagree? == false
      refute "tmux_adapter_paths_disagree" in snap.attention
      # Revision current + paths agree + surface ok → not diverged
      refute snap.diverged?
    end

    test "explicit :tmux_adapter env makes both paths agree on that module" do
      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:ok, @remote},
          now: @now,
          env: fn
            :tmux_adapter -> Tmux
            _ -> nil
          end,
          backend_module: Backends.Tmux
        )

      ta = snap.modules.tmux_adapter
      assert ta.configured == "Casein.Terminals.Tmux"
      assert ta.mcp_resolved == "Casein.Terminals.Tmux"
      assert ta.ops_resolved == "Casein.Terminals.Tmux"
      assert ta.paths_disagree? == false
      refute "tmux_adapter_paths_disagree" in snap.attention
    end

    test "mcp_surface reports missing exports on incomplete adapter module" do
      defmodule IncompleteAdapter do
        def list_sessions, do: []
      end

      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:ok, @remote},
          now: @now,
          env: fn
            :tmux_adapter -> IncompleteAdapter
            _ -> nil
          end,
          backend_module: Backends.Tmux
        )

      surface = snap.modules.tmux_adapter.mcp_surface
      assert surface.ok? == false
      assert "paste_text/3" in surface.missing
      assert "tmux_adapter_mcp_surface_incomplete" in snap.attention
    end

    test "terminal_backend resolved is always present" do
      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:ok, @remote},
          now: @now,
          env: fn _ -> nil end,
          backend_module: Backends.Tmux
        )

      assert snap.modules.terminal_backend.resolved == "Casein.Terminals.Backends.Tmux"
      assert snap.modules.terminal_backend.source == "backend_module_default"
    end
  end
end
