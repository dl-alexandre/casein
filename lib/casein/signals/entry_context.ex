defmodule Casein.Signals.EntryContext do
  @moduledoc """
  Wraps a LiveView's `handle_event/3` so every user-initiated event runs under
  a fresh `Casein.Signals.Context` root.

  Audit events emitted while handling the event then carry a correlation id,
  and consecutive emits link into a causation chain — the same treatment MCP
  tool calls already get in each `*_mcp.ex` `call_tool/3`. Without this, an
  event handler runs with no active context, so `Casein.Signals.Context.stamp/1`
  no-ops and the resulting audit signals reach the bus untraced.

  `use Casein.Signals.EntryContext` *after* `use CaseinWeb, :live_view`, in a
  module that defines at least one `handle_event/3` clause. Only the event
  entry point is wrapped: background `handle_info/2` is intentionally left
  alone (a PubSub/timer message is not a user-initiated causal root).

  The wrapper is a single `defoverridable`/`super` layer, so it covers every
  `handle_event/3` clause — including those that delegate to sub-modules — and
  `Context.with_new/1` restores the prior context on exit, which matters in a
  long-lived LiveView process where the same reduction stack is reused.
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile Casein.Signals.EntryContext
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable handle_event: 3

      def handle_event(event, params, socket) do
        Casein.Signals.Context.with_new(fn -> super(event, params, socket) end)
      end
    end
  end
end
