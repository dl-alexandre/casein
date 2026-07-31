defmodule Casein.Test.ProviderConformance do
  @moduledoc """
  Shared conformance assertions for `Casein.AgentSessions.Provider` adapters.

  Any adapter test can `use` this to assert the structural half of the contract
  without a live runtime. That is what makes a third adapter cheap: the shape is
  checked here once, and the adapter's own test only covers its wire behaviour.

  The key assertion is **declared capabilities match exported callbacks**, in
  both directions:

    * declaring `:drive` without exporting `send_turn/3` is a lie the dispatcher
      cannot catch — it would route a call to a function that does not exist;
    * exporting `send_turn/3` without declaring `:drive` is worse, because the
      dispatcher would refuse a call the adapter could actually serve.

  Grok is the case that matters: it must export `respond_to_request/3` but must
  **not** export `send_turn/3`, because it is an observer and the human drives
  the TUI.

      defmodule MyAdapterTest do
        use ExUnit.Case, async: true
        use Casein.Test.ProviderConformance, adapter: MyAdapter
      end
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    quote location: :keep do
      alias Casein.AgentSessions.Provider

      @adapter unquote(adapter)

      describe "#{inspect(unquote(adapter))} provider conformance" do
        test "declares only known capabilities" do
          unknown = @adapter.capabilities() -- Provider.capabilities()

          assert unknown == [],
                 "unknown capability declared: #{inspect(unknown)}"
        end

        test "declares at least one of :drive or :observe" do
          declared = @adapter.capabilities()

          assert :drive in declared or :observe in declared,
                 "an adapter that neither drives nor observes has no purpose"
        end

        test "implements the required callbacks" do
          Code.ensure_loaded!(@adapter)

          for {name, arity} <- [
                {:capabilities, 0},
                {:start_session, 1},
                {:stop_session, 1},
                {:status, 1}
              ] do
            assert function_exported?(@adapter, name, arity),
                   "missing required callback #{name}/#{arity}"
          end
        end

        test "exports exactly the gated callbacks its capabilities allow" do
          Code.ensure_loaded!(@adapter)
          declared = @adapter.capabilities()

          for {{name, arity}, required} <- Provider.gated_callbacks() do
            exported? = function_exported?(@adapter, name, arity)
            allowed? = required in declared

            cond do
              exported? and not allowed? ->
                flunk("""
                #{inspect(@adapter)} exports #{name}/#{arity} but does not declare \
                #{inspect(required)}. The dispatcher would refuse a call this \
                adapter can actually serve.
                """)

              allowed? and not exported? ->
                flunk("""
                #{inspect(@adapter)} declares #{inspect(required)} but does not \
                export #{name}/#{arity}. The dispatcher would route to a function \
                that does not exist.
                """)

              true ->
                :ok
            end
          end
        end

        test "is registered under a provider id" do
          registered =
            Casein.AgentSessions.provider_ids()
            |> Enum.map(fn id ->
              {:ok, module} = Casein.AgentSessions.adapter(id)
              module
            end)

          assert @adapter in registered,
                 "#{inspect(@adapter)} is not in :agent_session_providers config"
        end

        test "rejects a malformed session ref instead of crashing" do
          for fun <- [:stop_session, :status] do
            result = apply(@adapter, fun, [:not_a_session_ref])

            assert match?({:error, _}, result) or result == :ok,
                   "#{fun}/1 on a bad ref returned #{inspect(result)}"
          end
        end
      end
    end
  end
end
