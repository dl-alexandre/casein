defmodule Casein.Terminals.Backends.TmuxMcpSurfaceTest do
  @moduledoc """
  Pins MCP resolution to `Backends.Tmux` (the #854 live shape) and drives
  send/paste/command paths against a recording lower adapter.

  Guards incomplete surface (`paste_text/3`, `send_keys/2`) and return-contract
  mismatch (`{out, code}` vs `:ok | {:error, _}`) that raised
  UndefinedFunctionError / CaseClauseError on the fleet MCP path.
  """

  use ExUnit.Case, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Agents.TerminalTools.Impl.Agent
  alias Casein.Agents.TerminalTools.Impl.Command
  alias Casein.Agents.TerminalTools.Impl.Shared
  alias Casein.Terminals.Backends.Tmux, as: TmuxBackend

  @session "casein_mcp_surface_ws_1"
  @agent_pane "%2"
  @operator_pane "%1"

  defmodule RecordingLower do
    @moduledoc false

    def configure(pid) when is_pid(pid), do: :persistent_term.put({__MODULE__, :pid}, pid)

    def set_send_keys_return(value),
      do: :persistent_term.put({__MODULE__, :send_keys_return}, value)

    def set_paste_return(value),
      do: :persistent_term.put({__MODULE__, :paste_return}, value)

    def set_send_command_return(value),
      do: :persistent_term.put({__MODULE__, :send_command_return}, value)

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:lower, msg})
        _ -> :ok
      end
    end

    defp take(key, default) do
      case :persistent_term.get({__MODULE__, key}, :__unset__) do
        :__unset__ -> default
        value -> value
      end
    end

    def session_exists?(session) when is_binary(session) do
      notify({:session_exists?, session})
      String.starts_with?(session, "casein_")
    end

    def session_alive?(session), do: session_exists?(session)

    def list_sessions do
      notify(:list_sessions)
      [%{session: "casein_mcp_surface_ws_1", attached: true, activity: 1}]
    end

    def list_session_panes(session) do
      notify({:list_session_panes, session})

      [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          role: "operator",
          current_path: File.cwd!()
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: false,
          role: "agent",
          current_path: File.cwd!(),
          title: "agent"
        }
      ]
    end

    def list_session_windows(session) do
      notify({:list_session_windows, session})
      [%{id: "@1", index: 0, name: "main", active: true, panes: 2}]
    end

    def session_topology(session) do
      {list_session_windows(session), list_session_panes(session)}
    end

    def send_keys(session, keys, opts \\ []) do
      notify({:send_keys, session, keys, opts})
      take(:send_keys_return, :ok)
    end

    def send_command(session, cmd, opts \\ []) do
      notify({:send_command, session, cmd, opts})
      take(:send_command_return, :ok)
    end

    def paste_text(session, text, opts \\ []) do
      notify({:paste_text, session, text, opts})
      take(:paste_return, :ok)
    end

    def capture_scrollback(session, opts \\ []) do
      notify({:capture_scrollback, session, opts})
      "scrollback"
    end

    def capture_recent(session, lines, opts \\ []) do
      notify({:capture_recent, session, lines, opts})
      {:ok, "recent"}
    end

    def ensure_session(session, cwd) do
      notify({:ensure_session, session, cwd})
      :ok
    end

    def kill(session) do
      notify({:kill, session})
      :ok
    end

    def set_environment(session, key, value) do
      notify({:set_environment, session, key, value})
      :ok
    end

    def attach(_session), do: {:ok, :recording}
    def resize_window(_s, _c, _r), do: :ok
    def window_size(_s), do: {:ok, {80, 24}}
    def new_window(_s, _o \\ []), do: {:ok, "@2"}
    def select_window(_s, _w), do: :ok
    def kill_window(_s, _w), do: :ok
    def split_pane(_s, _p, _d, _o \\ []), do: {:ok, "%3"}
    def select_pane(_s, _p), do: :ok
    def kill_pane(_s, _p), do: :ok
    def resize_pane(_s, _p, _d, _a \\ 1), do: :ok
    def set_pane_role(_s, _p, _r), do: :ok
  end

  setup do
    previous_adapter = Application.get_env(:casein, :tmux_adapter)
    previous_backend = Application.get_env(:casein, :terminal_backend)
    previous_inner = Application.get_env(:casein, :tmux_adapter_inner)

    RecordingLower.configure(self())
    RecordingLower.set_send_keys_return(:ok)
    RecordingLower.set_paste_return(:ok)
    RecordingLower.set_send_command_return(:ok)

    on_exit(fn ->
      restore(:tmux_adapter, previous_adapter)
      restore(:terminal_backend, previous_backend)
      restore(:tmux_adapter_inner, previous_inner)
    end)

    :ok
  end

  describe "Backends.Tmux MCP surface completeness" do
    test "exports every function MCP impls call on tmux()" do
      required = [
        {:send_keys, 2},
        {:send_keys, 3},
        {:send_command, 2},
        {:send_command, 3},
        {:paste_text, 2},
        {:paste_text, 3},
        {:capture_scrollback, 1},
        {:capture_scrollback, 2},
        {:list_session_panes, 1},
        {:list_sessions, 0},
        {:session_exists?, 1}
      ]

      missing =
        for {name, arity} <- required,
            not function_exported?(TmuxBackend, name, arity),
            do: {name, arity}

      assert missing == [], "Backends.Tmux missing MCP surface: #{inspect(missing)}"
    end

    test "send_keys/2 and send_keys/3 normalize {out,0} and :ok" do
      pin_backends_tmux_with_inner!()

      RecordingLower.set_send_keys_return({"", 0})
      assert :ok = TmuxBackend.send_keys(@session, "Enter")
      assert_receive {:lower, {:send_keys, @session, "Enter", []}}

      RecordingLower.set_send_keys_return(:ok)
      assert :ok = TmuxBackend.send_keys(@session, "a", target: @agent_pane)
      assert_receive {:lower, {:send_keys, @session, "a", [target: @agent_pane]}}

      RecordingLower.set_send_keys_return({"boom", 1})
      assert {:error, "boom"} = TmuxBackend.send_keys(@session, "x")
    end

    test "paste_text/3 and send_command/3 normalize adapter returns" do
      pin_backends_tmux_with_inner!()

      RecordingLower.set_paste_return({"", 0})
      assert :ok = TmuxBackend.paste_text(@session, "hello", target: @agent_pane, submit: false)
      assert_receive {:lower, {:paste_text, @session, "hello", opts}}
      assert opts[:target] == @agent_pane
      assert opts[:submit] == false

      RecordingLower.set_paste_return(:ok)
      assert :ok = TmuxBackend.paste_text(@session, "x")

      RecordingLower.set_send_command_return({"err", 2})
      assert {:error, "err"} = TmuxBackend.send_command(@session, "ls")

      RecordingLower.set_send_command_return(:ok)
      assert :ok = TmuxBackend.send_command(@session, "ls", target: @agent_pane)
    end

    test "Shared.tmux/0 resolves to Backends.Tmux when :tmux_adapter is that module" do
      pin_backends_tmux_with_inner!()
      assert Shared.tmux() == TmuxBackend
    end
  end

  describe "MCP path with :tmux_adapter => Backends.Tmux (live #854 shape)" do
    # Omit workspace_id so validate_session does not hit Workspaces.get / manager
    # client stubs — the #854 defect is the adapter surface, not workspace scope.

    test "Command.send_keys accepts :ok without CaseClauseError" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_send_keys_return(:ok)

      assert {:ok, %{status: "sent", target: target}} =
               Command.send_keys(%{
                 "session" => @session,
                 "pane" => @operator_pane,
                 "keys" => "C-c"
               })

      assert target == @operator_pane
      assert_receive {:lower, {:send_keys, ^target, "C-c", []}}
    end

    test "Command.send_keys still accepts legacy {out, code} adapters" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_send_keys_return({"", 0})

      assert {:ok, %{status: "sent"}} =
               Command.send_keys(%{
                 "session" => @session,
                 "pane" => @operator_pane,
                 "keys" => "Enter"
               })
    end

    test "Command.send_keys maps non-zero tuple to error" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_send_keys_return({"no pane", 1})

      assert {:error, "no pane"} =
               Command.send_keys(%{
                 "session" => @session,
                 "pane" => @operator_pane,
                 "keys" => "x"
               })
    end

    test "paste_agent_text reaches paste_text/3 on Backends.Tmux" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_paste_return(:ok)

      assert {:ok, %{status: "sent", target: @agent_pane}} =
               Agent.paste_agent_text(%{
                 "session" => @session,
                 "pane" => @agent_pane,
                 "text" => "fleet brief\nline two",
                 "submit" => false
               })

      assert_receive {:lower,
                      {:paste_text, @session, "fleet brief\nline two",
                       [target: @agent_pane, submit: false]}}
    end

    test "paste_agent_text accepts normalized :ok after tuple adapter return" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_paste_return({"", 0})

      assert {:ok, %{status: "sent"}} =
               Agent.paste_agent_text(%{
                 "session" => @session,
                 "pane" => @agent_pane,
                 "text" => "hi",
                 "submit" => false
               })
    end

    test "TerminalTools.invoke terminal_send_keys through Backends.Tmux" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_send_keys_return(:ok)

      assert {:ok, result} =
               TerminalTools.invoke("terminal_send_keys", %{
                 "session" => @session,
                 "pane" => @operator_pane,
                 "keys" => "q"
               })

      status = Map.get(result, :status) || Map.get(result, "status")
      assert status == "sent"
      assert_receive {:lower, {:send_keys, @operator_pane, "q", []}}
    end

    test "Command.send_command works when adapter returns :ok" do
      pin_backends_tmux_with_inner!()
      RecordingLower.set_send_command_return(:ok)

      assert {:ok, %{status: "sent"}} =
               Command.send_command(%{
                 "session" => @session,
                 "pane" => @operator_pane,
                 "command" => "true",
                 "confirm" => false
               })

      assert_receive {:lower, {:send_command, @operator_pane, "true", []}}
    end
  end

  # Production #854: Shared.tmux → Backends.Tmux via :tmux_adapter.
  # Backends.Tmux.adapter/0 would recurse if it only read :tmux_adapter; it
  # prefers :tmux_adapter_inner, else falls through to Casein.Terminals.Tmux
  # when :tmux_adapter is this module.
  defp pin_backends_tmux_with_inner! do
    Application.put_env(:casein, :terminal_backend, TmuxBackend)
    Application.put_env(:casein, :tmux_adapter, TmuxBackend)
    Application.put_env(:casein, :tmux_adapter_inner, RecordingLower)
    assert Shared.tmux() == TmuxBackend
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
