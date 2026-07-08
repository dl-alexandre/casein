defmodule DevIDE.Signals.EntryContextTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Audit.MemoryAdapter
  alias DevIDE.Signals.Context

  # A stand-in LiveView: `use DevIDE.Signals.EntryContext` wraps its
  # handle_event/3 clauses in a fresh correlation context.
  defmodule FakeLive do
    use DevIDE.Signals.EntryContext

    def handle_event("emit", _params, socket) do
      {:ok, _} = Audit.emit(%{action: "fake.clicked", workspace_id: "wf"})
      {:ok, _} = Audit.emit(%{action: "fake.followed", workspace_id: "wf"})
      {:noreply, Map.put(socket, :trace_id, Context.current().trace_id)}
    end
  end

  # A stand-in controller: the exact action/2 wrapper the API controllers use,
  # exercised without the Phoenix plug pipeline. action_name/1 just reads
  # conn.private.phoenix_action, which we set directly.
  defmodule FakeController do
    import Phoenix.Controller, only: [action_name: 1]
    import Plug.Conn, only: [assign: 3]

    def action(conn, _opts) do
      Context.with_new(fn ->
        apply(__MODULE__, action_name(conn), [conn, conn.params])
      end)
    end

    def ping(conn, _params) do
      {:ok, _} = Audit.emit(%{action: "fake.ping", workspace_id: "wc"})
      assign(conn, :trace_id, Context.current().trace_id)
    end
  end

  setup do
    prev_adapter = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      restore_env(:audit_adapter, prev_adapter)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)

  describe "LiveView handle_event wrapping" do
    test "audit events emitted while handling carry the event's correlation id" do
      assert Context.current() == nil

      {:noreply, socket} = FakeLive.handle_event("emit", %{}, %{})

      assert is_binary(socket.trace_id)
      # Both emits share the one correlation id and link as a causation chain.
      assert Audit.list_by_correlation(socket.trace_id) |> Enum.map(& &1.action) ==
               ["fake.clicked", "fake.followed"]
    end

    test "the context is restored (not leaked) after the handler returns" do
      {:noreply, _socket} = FakeLive.handle_event("emit", %{}, %{})
      assert Context.current() == nil
    end

    test "each event is its own root (distinct correlation ids)" do
      {:noreply, a} = FakeLive.handle_event("emit", %{}, %{})
      {:noreply, b} = FakeLive.handle_event("emit", %{}, %{})
      assert a.trace_id != b.trace_id
    end
  end

  describe "controller action/2 wrapping" do
    test "audit events emitted during an action carry a correlation id" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.fetch_query_params()
        |> Plug.Conn.put_private(:phoenix_action, :ping)

      conn = FakeController.action(conn, [])

      assert is_binary(conn.assigns.trace_id)
      assert [%{action: "fake.ping"}] = Audit.list_by_correlation(conn.assigns.trace_id)
      # No context leaks back to the caller.
      assert Context.current() == nil
    end
  end
end
