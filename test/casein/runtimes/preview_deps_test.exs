defmodule Casein.Runtimes.PreviewDepsTest do
  @moduledoc """
  Unit tests for `Casein.Runtimes.PreviewDeps` — the core-side impl of
  `Casein.Previews.Deps.Runtimes`.

  Mirrors the callback surface in `Casein.Previews.Deps.Test.Fakes.Runtimes` and
  asserts each of the four public callbacks reaches `Casein.Runtimes` /
  `Casein.Runtimes.PreviewLauncher` (thin pure delegation; no local logic).
  """

  use Casein.TestCase, async: false

  alias Casein.Previews.Deps.Runtimes, as: RuntimesBehaviour
  alias Casein.Runtimes
  alias Casein.Runtimes.{PreviewDeps, PreviewLauncher, Runtime}
  alias Casein.Test.RuntimeSeed

  setup do
    Runtimes.clear()

    on_exit(fn ->
      Runtimes.clear()
    end)

    :ok
  end

  describe "behaviour contract" do
    test "implements every Casein.Previews.Deps.Runtimes callback" do
      assert {:module, PreviewDeps} = Code.ensure_loaded(PreviewDeps)

      missing =
        for {name, arity} <- RuntimesBehaviour.behaviour_info(:callbacks),
            not function_exported?(PreviewDeps, name, arity),
            do: {name, arity}

      assert missing == [],
             "PreviewDeps missing Deps.Runtimes callbacks: #{inspect(missing)}"

      # Explicit surface check (same four as Deps.Test.Fakes.Runtimes).
      assert function_exported?(PreviewDeps, :list_runtimes, 1)
      assert function_exported?(PreviewDeps, :runtime_preview_surfaces, 1)
      assert function_exported?(PreviewDeps, :runtime_preview_server, 1)
      assert function_exported?(PreviewDeps, :ensure_preview_server_started, 1)
    end
  end

  describe "delegation to Casein.Runtimes / PreviewLauncher" do
    test "list_runtimes/1 reaches Runtimes.list_runtimes/1 with filters" do
      {:ok, seeded} =
        RuntimeSeed.seed_runtime("ws-preview-deps",
          runtime_id: "rt-preview-deps-list",
          status: "provisioned"
        )

      filters = %{"workspace_id" => "ws-preview-deps", "runtime_id" => "rt-preview-deps-list"}

      via_deps = PreviewDeps.list_runtimes(filters)
      via_core = Runtimes.list_runtimes(filters)

      assert via_deps == via_core
      assert [%{id: "rt-preview-deps-list"}] = via_deps
      assert hd(via_deps).id == seeded.id
      # Distinct filters must not silently ignore the adapter path.
      assert PreviewDeps.list_runtimes(%{"workspace_id" => "ws-no-such"}) == []
    end

    test "runtime_preview_server/1 reaches Runtimes.runtime_preview_server/1" do
      server = %{
        "id" => "preview:rt-pd:app",
        "runtime_id" => "rt-pd",
        "port" => 5173,
        "status" => "provisioned"
      }

      runtime = runtime_fixture(%{"preview_server" => server})

      assert PreviewDeps.runtime_preview_server(runtime) ==
               Runtimes.runtime_preview_server(runtime)

      assert PreviewDeps.runtime_preview_server(runtime) == server

      bare = runtime_fixture(%{})
      assert PreviewDeps.runtime_preview_server(bare) == nil
      assert PreviewDeps.runtime_preview_server(bare) == Runtimes.runtime_preview_server(bare)
    end

    test "runtime_preview_surfaces/1 reaches Runtimes.runtime_preview_surfaces/1" do
      runtime =
        runtime_fixture(%{
          "runtime_profile" => %{
            "name" => "vite",
            "kind" => "vite",
            "command" => ["npm", "run", "dev"],
            "env" => %{},
            "ports" => %{"app" => 5173},
            "surfaces" => [%{"name" => "app", "port" => 5173}],
            "health_check" => nil
          }
        })

      via_deps = PreviewDeps.runtime_preview_surfaces(runtime)
      via_core = Runtimes.runtime_preview_surfaces(runtime)

      assert via_deps == via_core

      assert [
               %{
                 "name" => "app",
                 "url" => "http://localhost:5173",
                 "source" => "runtime",
                 "runtime_id" => "rt-preview-deps",
                 "surface_key" => "runtime:rt-preview-deps:app"
               }
             ] = via_deps
    end

    test "ensure_preview_server_started/1 reaches PreviewLauncher.ensure_started/1" do
      # Invalid runtime: same error from both sides (pure delegation).
      assert PreviewDeps.ensure_preview_server_started(:not_a_runtime) ==
               PreviewLauncher.ensure_started(:not_a_runtime)

      assert PreviewDeps.ensure_preview_server_started(:not_a_runtime) ==
               {:error, :invalid_runtime}

      # test.exs disables the launcher (returns :ok for any Runtime). Force the
      # missing-server branch so a hard-coded :ok in PreviewDeps would fail.
      previous = Application.get_env(:casein, :runtime_preview_launcher_enabled)

      try do
        Application.put_env(:casein, :runtime_preview_launcher_enabled, true)
        runtime = runtime_fixture(%{})

        assert PreviewDeps.ensure_preview_server_started(runtime) ==
                 PreviewLauncher.ensure_started(runtime)

        assert PreviewDeps.ensure_preview_server_started(runtime) ==
                 {:error, :runtime_preview_server_missing}
      after
        case previous do
          nil -> Application.delete_env(:casein, :runtime_preview_launcher_enabled)
          value -> Application.put_env(:casein, :runtime_preview_launcher_enabled, value)
        end
      end
    end
  end

  defp runtime_fixture(metadata) when is_map(metadata) do
    %Runtime{
      id: "rt-preview-deps",
      workspace_id: "ws-preview-deps",
      host_id: "local",
      isolation_mode: "worktree",
      status: "provisioned",
      created_at: DateTime.utc_now(),
      metadata: metadata
    }
  end
end
