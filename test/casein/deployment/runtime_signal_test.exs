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

  describe "snapshot/1 modules — the S11 failure mode" do
    test "when :tmux_adapter unset, MCP path falls back to Backend.module not Tmux default" do
      snap =
        RuntimeSignal.snapshot(
          version: @deployed,
          remote: {:ok, @remote},
          now: @now,
          env: fn _ -> nil end,
          backend_module: Backends.Tmux
        )

      ta = snap.modules.tmux_adapter

      assert ta.configured == nil
      assert ta.configured? == false
      assert ta.repo_default == "Casein.Terminals.Tmux"
      assert ta.backend_module == "Casein.Terminals.Backends.Tmux"
      # Agents via Shared.tmux/0
      assert ta.mcp_resolved == "Casein.Terminals.Backends.Tmux"
      assert ta.mcp_source == "backend_module_fallback"
      # Legacy get_env(..., Tmux) call sites
      assert ta.ops_resolved == "Casein.Terminals.Tmux"
      assert ta.ops_source == "hardcoded_default_tmux"
      assert ta.paths_disagree? == true
      assert "tmux_adapter_paths_disagree" in snap.attention
      assert snap.diverged? == true
    end

    test "explicit :tmux_adapter env makes both paths agree" do
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
