defmodule Casein.Previews.DepsContractTest do
  @moduledoc """
  Contract tests for preview-domain outbound dependency seams.

  Each core-side impl must export every callback of its preview-owned behaviour.
  """

  use ExUnit.Case, async: true

  alias Casein.Panes.PreviewDeps, as: PaneSinkImpl
  alias Casein.Previews.Deps
  alias Casein.Previews.Deps.{PaneSink, Runtimes, Terminals, Workspaces}
  alias Casein.Runtimes.PreviewDeps, as: RuntimesImpl
  alias Casein.Terminals.PreviewDeps, as: TerminalsImpl
  alias Casein.Workspaces.PreviewDeps, as: WorkspacesImpl

  describe "core impls satisfy behaviour callbacks" do
    test "Workspaces.PreviewDeps implements Deps.Workspaces" do
      assert_implements(WorkspacesImpl, Workspaces)
    end

    test "Terminals.PreviewDeps implements Deps.Terminals" do
      assert_implements(TerminalsImpl, Terminals)
    end

    test "Runtimes.PreviewDeps implements Deps.Runtimes" do
      assert_implements(RuntimesImpl, Runtimes)
    end

    test "Panes.PreviewDeps implements Deps.PaneSink" do
      assert_implements(PaneSinkImpl, PaneSink)
    end
  end

  describe "config resolution" do
    test "preview_deps config resolves each seam to its production impl" do
      assert Deps.impl(:workspaces) == WorkspacesImpl
      assert Deps.impl(:terminals) == TerminalsImpl
      assert Deps.impl(:runtimes) == RuntimesImpl
      assert Deps.impl(:pane_sink) == PaneSinkImpl
    end

    test "impl/1 is overridable via Application env (test seam)" do
      previous = Application.get_env(:dev_ide, :preview_deps)

      try do
        Application.put_env(:dev_ide, :preview_deps,
          workspaces: Deps.Test.Fakes.Workspaces,
          terminals: Deps.Test.Fakes.Terminals,
          runtimes: Deps.Test.Fakes.Runtimes,
          pane_sink: Deps.Test.Fakes.PaneSink
        )

        assert Deps.impl(:workspaces) == Deps.Test.Fakes.Workspaces
        assert Deps.impl(:terminals) == Deps.Test.Fakes.Terminals
        assert Deps.impl(:runtimes) == Deps.Test.Fakes.Runtimes
        assert Deps.impl(:pane_sink) == Deps.Test.Fakes.PaneSink
      after
        restore_preview_deps(previous)
      end
    end

    test "shipped fakes implement every behaviour callback" do
      assert_implements(Deps.Test.Fakes.Workspaces, Workspaces)
      assert_implements(Deps.Test.Fakes.Terminals, Terminals)
      assert_implements(Deps.Test.Fakes.Runtimes, Runtimes)
      assert_implements(Deps.Test.Fakes.PaneSink, PaneSink)
    end
  end

  describe "HostMode leaf" do
    test "on_host? reflects :on_devbox config" do
      previous = Application.get_env(:dev_ide, :on_devbox)

      try do
        Application.put_env(:dev_ide, :on_devbox, true)
        assert Casein.HostMode.on_host?()

        Application.put_env(:dev_ide, :on_devbox, false)
        refute Casein.HostMode.on_host?()
      after
        restore(:on_devbox, previous)
      end
    end

    test "Manager delegates on_host? and prepare_local_argv to HostMode" do
      previous = Application.get_env(:dev_ide, :on_devbox)

      try do
        Application.put_env(:dev_ide, :on_devbox, false)
        assert Casein.WorkspaceSource.Manager.on_host?() == Casein.HostMode.on_host?()
        assert Casein.WorkspaceSource.Manager.prepare_local_argv(["echo"]) == ["echo"]
        assert Casein.HostMode.prepare_local_argv(["echo"]) == ["echo"]
      after
        restore(:on_devbox, previous)
      end
    end
  end

  defp assert_implements(impl, behaviour) do
    assert {:module, ^impl} = Code.ensure_loaded(impl)

    missing =
      for {name, arity} <- behaviour.behaviour_info(:callbacks),
          not function_exported?(impl, name, arity),
          do: {name, arity}

    assert missing == [],
           "#{inspect(impl)} missing callbacks for #{inspect(behaviour)}: #{inspect(missing)}"
  end

  defp restore_preview_deps(nil), do: Application.delete_env(:dev_ide, :preview_deps)
  defp restore_preview_deps(val), do: Application.put_env(:dev_ide, :preview_deps, val)

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)
end
