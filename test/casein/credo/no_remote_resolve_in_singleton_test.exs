defmodule Casein.Credo.Check.NoRemoteResolveInSingletonTest do
  use Credo.Test.Case

  alias Casein.Credo.Check.NoRemoteResolveInSingleton

  # Credo.Test.Case stores ASTs in Credo.Service.SourceFileAST GenServers.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:credo)
    :ok
  end

  test "flags opts-less viewer_ids/1 inside a use GenServer module" do
    """
    defmodule CredoSampleGenServer do
      use GenServer

      def fanout(id) do
        for viewer <- Aliases.viewer_ids(id) do
          viewer
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(NoRemoteResolveInSingleton)
    |> assert_issue(fn issue ->
      assert issue.trigger == "viewer_ids"
      assert issue.message =~ "resolve_remote?: false"
    end)
  end

  test "does not flag viewer_ids when resolve_remote?: false is passed" do
    """
    defmodule CredoSampleGenServerSafe do
      use GenServer

      def fanout(id) do
        for viewer <- Aliases.viewer_ids(id, resolve_remote?: false) do
          viewer
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(NoRemoteResolveInSingleton)
    |> refute_issues()
  end

  test "does not flag opts-less viewer_ids/1 outside a GenServer module" do
    """
    defmodule CredoSamplePlainModule do
      def fanout(id) do
        Aliases.viewer_ids(id)
      end
    end
    """
    |> to_source_file()
    |> run_check(NoRemoteResolveInSingleton)
    |> refute_issues()
  end

  test "flags chained viewer_ids/1 call on a GenServer module" do
    """
    defmodule CredoSampleChained do
      use GenServer

      def fanout(id) do
        workspaces().viewer_ids(id)
      end

      defp workspaces, do: Aliases
    end
    """
    |> to_source_file()
    |> run_check(NoRemoteResolveInSingleton)
    |> assert_issue()
  end
end
