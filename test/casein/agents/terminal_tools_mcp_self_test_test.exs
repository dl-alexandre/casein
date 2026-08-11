defmodule Casein.Agents.TerminalToolsMcpSelfTestTest do
  @moduledoc """
  Runtime MCP self-test: proves the probe names the resolved adapter and
  reports UNDEFINED for missing adapter functions at the arities MCP impls call.
  """
  use ExUnit.Case, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Agents.TerminalTools.Impl.SelfTest
  alias Casein.Terminals.Backend
  alias Casein.Test.FakeTmuxAdapter

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      terminal_backend: Application.get_env(:casein, :terminal_backend)
    }

    on_exit(fn ->
      restore(:tmux_adapter, previous.tmux_adapter)
      restore(:terminal_backend, previous.terminal_backend)
    end)

    :ok
  end

  describe "definitions" do
    test "mcp_self_test is advertised as a read-only diagnostic" do
      tool = Enum.find(TerminalTools.definitions(), &(&1.name == "mcp_self_test"))
      assert tool
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_read in tool.metadata.capabilities
      assert Map.has_key?(tool.parameters.properties, :workspace_id)
    end
  end

  describe "run/1 against a complete fake adapter" do
    setup do
      Application.put_env(:casein, :tmux_adapter, FakeTmuxAdapter)
      # Fake adapter has no real ensure_session; self-test falls back to export checks.
      :ok
    end

    test "names the resolved adapter module" do
      assert {:ok, report} = SelfTest.run(%{})
      assert report.resolved_adapter == "Casein.Test.FakeTmuxAdapter"
      assert is_binary(report.terminal_backend)
      assert report.tmux_adapter_env == "Casein.Test.FakeTmuxAdapter"
    end

    test "reports ok or error (never undefined) when FakeTmuxAdapter exports the surface" do
      assert {:ok, report} = SelfTest.run(%{})

      for verb <- report.verbs do
        refute verb.status == "undefined",
               "expected #{verb.verb} (#{verb.fun}/#{verb.arity}) not undefined, got #{inspect(verb)}"
      end

      # Fake has no ensure_session path that creates a real pane, so writes may
      # error — but paste_text/3 and send_keys/2 must not be undefined.
      paste = Enum.find(report.verbs, &(&1.verb == "terminal_paste_agent_text"))
      assert paste
      assert paste.fun == "paste_text"
      assert paste.arity == 3
      refute paste.status == "undefined"

      send_keys = Enum.find(report.verbs, &(&1.verb == "terminal_send_keys"))
      assert send_keys.fun == "send_keys"
      assert send_keys.arity == 2
      refute send_keys.status == "undefined"
    end

    test "invoke path works" do
      assert {:ok, report} = TerminalTools.invoke("mcp_self_test", %{})
      assert is_map(report)
      assert Map.has_key?(report, :resolved_adapter)
      assert Map.has_key?(report, :verbs)
    end
  end

  describe "detects #854-class missing functions" do
    setup do
      Application.put_env(:casein, :tmux_adapter, __MODULE__.IncompleteAdapter)
      Code.ensure_loaded(__MODULE__.IncompleteAdapter)
      :ok
    end

    test "paste_text/3 and send_keys/2 report undefined while capture/list stay ok-shaped" do
      assert {:ok, report} = SelfTest.run(%{})
      assert report.resolved_adapter == inspect(__MODULE__.IncompleteAdapter)
      assert report.ok? == false
      assert report.summary.undefined >= 2

      by_verb = Map.new(report.verbs, &{&1.verb, &1})

      assert by_verb["terminal_paste_agent_text"].status == "undefined"
      assert by_verb["terminal_paste_agent_text"].fun == "paste_text"
      assert by_verb["terminal_paste_agent_text"].arity == 3
      assert by_verb["terminal_paste_agent_text"].detail =~ "undefined"

      assert by_verb["terminal_send_keys"].status == "undefined"
      assert by_verb["terminal_send_keys"].fun == "send_keys"
      assert by_verb["terminal_send_keys"].arity == 2

      # Present surface still reported (export check at least).
      assert by_verb["terminal_list_sessions"].status in ["ok", "error"]
      assert by_verb["terminal_capture"].status in ["ok", "error"]
      assert by_verb["terminal_send_command"].status in ["ok", "error"]
    end
  end

  describe "resolved adapter follows Shared.tmux/0, not checkout defaults" do
    test "when :tmux_adapter is unset, reports Backend.module/0" do
      Application.delete_env(:casein, :tmux_adapter)
      Application.delete_env(:casein, :terminal_backend)

      assert {:ok, report} = SelfTest.run(%{})
      assert report.resolved_adapter == inspect(Backend.module())
      # Default Backend.module/0 is Backends.Tmux — the prod divergence surface.
      assert report.resolved_adapter == "Casein.Terminals.Backends.Tmux"
      refute Map.has_key?(report, :tmux_adapter_env)
    end
  end

  # Incomplete adapter: the #854 shape — reads + send_command work; paste_text
  # and send_keys/2 are missing. send_keys/3 only (no default opts) so arity 2
  # is truly undefined — matching Backends.Tmux before the #854 fix.
  defmodule IncompleteAdapter do
    def list_sessions, do: []
    def list_session_panes(_session), do: []
    def capture_scrollback(_session, _opts), do: ""
    def send_command(_session, _cmd), do: :ok
    def send_command(_session, _cmd, _opts), do: :ok
    def send_keys(_session, _keys, _opts), do: :ok
    def ensure_session(_session, _cwd), do: :ok
    def kill(_session), do: :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
