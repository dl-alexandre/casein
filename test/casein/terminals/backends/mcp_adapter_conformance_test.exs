defmodule Casein.Terminals.Backends.McpAdapterConformanceTest do
  @moduledoc """
  #861 — general MCP backend adapter conformance (follow-up to #854/#870).

  `tmux_mcp_surface_test.exs` pins the specific surface #870 fixed on
  `Backends.Tmux` (arity set + return normalization + RecordingLower path).
  **This** test is the mechanical guard: enumerate every `tmux().<fn>(...)`
  call site under `lib/casein/agents/terminal_tools/**` at the arity actually
  called, and assert `function_exported?/3` against **each configured**
  backend — so a future incomplete adapter is caught without someone updating
  a hand-maintained required list for only the functions last week's bug
  happened to touch.

  Prod once resolved `:tmux_adapter` → `Backends.Tmux` while every local
  default implied `Terminals.Tmux`. Reading the repo default proved the wrong
  thing. The checker therefore runs against every configured candidate, not
  only `Backend.module/0`.

  Falsifiability is mandatory: the checker is shown red against a backend
  missing `paste_text/3` and one that only exports `send_keys/3` while
  `impl/command.ex` calls arity 2.
  """

  use ExUnit.Case, async: false

  alias Casein.Agents.TerminalTools.Impl.Shared
  alias Casein.Terminals.Backend
  alias Casein.Terminals.Backends.Tmux, as: TmuxBackend
  alias Casein.Terminals.Tmux

  # ---------------------------------------------------------------------------
  # Call-site ledger. Arity is the BEAM call arity after Elixir keyword sugar:
  #   paste_text(s, t, target: p, submit: false)  →  paste_text/3
  #   send_keys(target, keys)                     →  send_keys/2
  #   send_keys(session, keys, target: pane)      →  send_keys/3
  # ---------------------------------------------------------------------------
  @mcp_call_sites [
    {:capture_scrollback, 2, "impl/agent.ex:capture_agent"},
    {:capture_scrollback, 2, "impl/session.ex:capture"},
    {:send_keys, 3, "impl/agent.ex:send_agent_keys"},
    {:send_keys, 3, "impl/agent.ex:confirm Enter"},
    {:send_keys, 2, "impl/command.ex:send_keys"},
    {:send_command, 3, "impl/agent.ex:send_agent_command"},
    {:send_command, 2, "impl/command.ex:send_command"},
    {:paste_text, 3, "impl/agent.ex:paste_agent_text"},
    {:list_session_panes, 1, "impl/agent.ex:paste_target_pane"},
    {:list_session_panes, 1, "impl/agent.ex:find_agent_pane"},
    {:list_session_panes, 1, "impl/shared.ex:pane_ids"},
    {:list_sessions, 0, "impl/session.ex:list_sessions"},
    {:list_sessions, 0, "impl/shared.ex:workspace sessions"}
  ]

  @required_exports @mcp_call_sites
                    |> Enum.map(fn {fun, arity, _} -> {fun, arity} end)
                    |> Enum.uniq()
                    |> Enum.sort()

  setup do
    prev = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      terminal_backend: Application.get_env(:casein, :terminal_backend),
      tmux_adapter_inner: Application.get_env(:casein, :tmux_adapter_inner)
    }

    on_exit(fn ->
      restore(:tmux_adapter, prev.tmux_adapter)
      restore(:terminal_backend, prev.terminal_backend)
      restore(:tmux_adapter_inner, prev.tmux_adapter_inner)
    end)

    :ok
  end

  describe "MCP call-site surface (general guard)" do
    test "ledger matches every tmux(). call under terminal_tools" do
      on_disk = scan_tmux_call_sites()
      ledger = MapSet.new(Enum.map(@mcp_call_sites, fn {f, a, _} -> {f, a} end))
      disk = MapSet.new(Enum.map(on_disk, fn {f, a, _} -> {f, a} end))

      missing_from_ledger = MapSet.difference(disk, ledger)
      stale_in_ledger = MapSet.difference(ledger, disk)

      assert missing_from_ledger == MapSet.new(),
             """
             New tmux(). call site(s) not in @mcp_call_sites — extend the ledger
             or the general guard will not protect them:
             #{inspect(MapSet.to_list(missing_from_ledger))}
             scanned: #{inspect(on_disk)}
             """

      assert stale_in_ledger == MapSet.new(),
             """
             @mcp_call_sites lists fun/arity no longer called on disk:
             #{inspect(MapSet.to_list(stale_in_ledger))}
             """
    end

    test "every configured MCP backend exports the called arities" do
      for mod <- configured_mcp_backends() do
        assert_exports_mcp_surface!(mod)
      end
    end

    test "production candidates Backends.Tmux and Terminals.Tmux both satisfy surface" do
      # Prod once pointed :tmux_adapter at Backends.Tmux while repo defaults
      # implied Terminals.Tmux. Both must remain complete.
      for mod <- [TmuxBackend, Tmux] do
        assert_exports_mcp_surface!(mod)
      end
    end

    test "Shared.tmux/0 default resolution satisfies the surface" do
      Application.delete_env(:casein, :tmux_adapter)
      Application.delete_env(:casein, :terminal_backend)

      mod = Shared.tmux()
      assert is_atom(mod)
      assert_exports_mcp_surface!(mod)
    end

    test "Shared.tmux/0 honors explicit :tmux_adapter over Backend.module/0" do
      Application.put_env(:casein, :tmux_adapter, Tmux)
      Application.put_env(:casein, :terminal_backend, TmuxBackend)

      assert Shared.tmux() == Tmux
      assert_exports_mcp_surface!(Shared.tmux())
    end
  end

  describe "falsifiability (incomplete backends must fail the checker)" do
    test "backend missing paste_text/3 is rejected" do
      missing = missing_exports(__MODULE__.MissingPasteAdapter)

      assert {:paste_text, 3} in missing,
             "checker must flag missing paste_text/3, got: #{inspect(missing)}"
    end

    test "backend with send_keys/3 only (no arity 2) is rejected" do
      missing = missing_exports(__MODULE__.SendKeysArity3OnlyAdapter)

      assert {:send_keys, 2} in missing,
             "checker must flag missing send_keys/2 (command.ex), got: #{inspect(missing)}"
    end

    test "assert_exports_mcp_surface!/1 raises on incomplete backends" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_exports_mcp_surface!(__MODULE__.MissingPasteAdapter)
      end

      assert_raise ExUnit.AssertionError, fn ->
        assert_exports_mcp_surface!(__MODULE__.SendKeysArity3OnlyAdapter)
      end
    end
  end

  # Return-contract dual match is covered end-to-end by tmux_mcp_surface_test
  # (Command.send_keys :ok and {out,0}). Here we only assert production
  # candidates still export the mutation surface the case clauses invoke.
  describe "mutation surface still present after #870" do
    test "required mutation fun/arities remain exported on Backends.Tmux" do
      for {fun, arity} <- [
            {:send_keys, 2},
            {:send_keys, 3},
            {:send_command, 2},
            {:send_command, 3},
            {:paste_text, 3}
          ] do
        assert function_exported?(TmuxBackend, fun, arity),
               "Backends.Tmux lost #{fun}/#{arity} — #870 regression"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Checker + scanners
  # ---------------------------------------------------------------------------

  defp configured_mcp_backends do
    [
      Application.get_env(:casein, :tmux_adapter),
      Application.get_env(:casein, :terminal_backend),
      Backend.module(),
      TmuxBackend,
      Tmux
    ]
    |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
    |> Enum.uniq()
  end

  defp assert_exports_mcp_surface!(mod) when is_atom(mod) do
    assert {:module, ^mod} = Code.ensure_loaded(mod)
    missing = missing_exports(mod)

    assert missing == [],
           """
           #{inspect(mod)} is missing MCP call-site exports:
             #{Enum.map_join(missing, "\n  ", &inspect/1)}
           required (from terminal_tools call sites):
             #{Enum.map_join(@required_exports, "\n  ", &inspect/1)}
           """
  end

  defp missing_exports(mod) do
    Code.ensure_loaded(mod)

    for {fun, arity} <- @required_exports,
        not function_exported?(mod, fun, arity),
        do: {fun, arity}
  end

  defp scan_tmux_call_sites do
    root = Path.expand("../../../../lib/casein/agents/terminal_tools", __DIR__)

    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      text = File.read!(path)
      rel = Path.relative_to(path, root)

      for match <- Regex.scan(~r/tmux\(\)\.(\w+)/, text, return: :index) do
        [{fun_start, fun_len}, {name_start, name_len}] = match
        fun = String.to_atom(binary_part(text, name_start, name_len))
        after_fun = fun_start + fun_len
        rest = binary_part(text, after_fun, byte_size(text) - after_fun)
        arity = call_arity_after(rest)
        line = text |> binary_part(0, fun_start) |> String.split("\n") |> length()
        {fun, arity, "#{rel}:#{line}"}
      end
    end)
  end

  # Parse the parenthesized argument list immediately after `tmux().fun`.
  # Elixir keyword sugar `target: x, submit: y` is ONE argument (a keyword list),
  # so commas inside a trailing keyword list must not inflate arity.
  defp call_arity_after(rest) do
    rest = String.trim_leading(rest)

    case rest do
      "(" <> body ->
        args = take_paren_body(body)
        count_elixir_call_args(args)

      _ ->
        # Capture form: then(&tmux().capture_scrollback(&1, opts)) — the call
        # is still parenthesized after the fun name inside the capture. Walk to '('.
        case Regex.run(~r/^\s*\(/, rest) do
          nil -> 0
          _ -> call_arity_after(String.trim_leading(rest))
        end
    end
  end

  defp take_paren_body(body) do
    take_paren_body(body, 1, [])
  end

  defp take_paren_body("", _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_paren_body(<<ch::utf8, rest::binary>>, depth, acc) do
    cond do
      ch == ?( -> take_paren_body(rest, depth + 1, [acc, "("])
      ch == ?) and depth == 1 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      ch == ?) -> take_paren_body(rest, depth - 1, [acc, ")"])
      true -> take_paren_body(rest, depth, [acc, <<ch::utf8>>])
    end
  end

  defp count_elixir_call_args(args) do
    trimmed = String.trim(args)
    if trimmed == "", do: 0, else: do_count_args(trimmed, 0, 0, false, 1)
  end

  # Track paren/bracket depth and whether we have entered a bare keyword tail
  # (`ident:` at depth 0). Once in a keyword tail, further top-level commas do
  # not add arguments.
  defp do_count_args("", _depth, _kw, _in_kw, count), do: count

  defp do_count_args(<<ch::utf8, rest::binary>>, depth, kw_run, in_kw, count) do
    cond do
      ch in [?(, ?[, ?{] ->
        do_count_args(rest, depth + 1, 0, in_kw, count)

      ch in [?), ?], ?}] ->
        do_count_args(rest, max(depth - 1, 0), 0, in_kw, count)

      depth == 0 and ch == ?, and not in_kw ->
        # Peek whether the next top-level token starts a keyword (`foo:`).
        # A trailing keyword list is still one NEW argument
        # (send_keys(s, k, target: p) → arity 3).
        if keyword_start?(rest) do
          do_count_args(rest, depth, 0, true, count + 1)
        else
          do_count_args(rest, depth, 0, false, count + 1)
        end

      depth == 0 and ch == ?, and in_kw ->
        # Commas inside the trailing keyword list do not add arguments.
        do_count_args(rest, depth, 0, true, count)

      depth == 0 and keyword_char?(ch) ->
        do_count_args(rest, depth, kw_run + 1, in_kw, count)

      depth == 0 and ch == ?: and kw_run > 0 ->
        # Saw `ident:` at depth 0 — this argument is (or starts) a keyword list.
        do_count_args(rest, depth, 0, true, count)

      true ->
        do_count_args(rest, depth, 0, in_kw, count)
    end
  end

  defp keyword_char?(ch) when ch >= ?a and ch <= ?z, do: true
  defp keyword_char?(ch) when ch >= ?A and ch <= ?Z, do: true
  defp keyword_char?(ch) when ch >= ?0 and ch <= ?9, do: true
  defp keyword_char?(?_), do: true
  defp keyword_char?(_), do: false

  defp keyword_start?(rest) do
    case Regex.run(~r/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/, rest) do
      [_ | _] -> true
      nil -> false
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  # ---------------------------------------------------------------------------
  # Deliberately incomplete adapters — falsifiability only.
  # ---------------------------------------------------------------------------

  defmodule MissingPasteAdapter do
    @moduledoc false
    # #854 crash shape: everything except paste_text/3.
    def list_sessions, do: []
    def list_session_panes(_s), do: []
    def capture_scrollback(_s, _opts), do: ""
    def send_keys(_s, _k), do: :ok
    def send_keys(_s, _k, _opts), do: :ok
    def send_command(_s, _c), do: :ok
    def send_command(_s, _c, _opts), do: :ok
  end

  defmodule SendKeysArity3OnlyAdapter do
    @moduledoc false
    # Looks complete in a Backend callback audit (send_keys/3) but fails the
    # command.ex arity-2 call site — the other half of #854.
    def list_sessions, do: []
    def list_session_panes(_s), do: []
    def capture_scrollback(_s, _opts), do: ""
    def send_keys(_s, _k, _opts), do: :ok
    def send_command(_s, _c), do: :ok
    def send_command(_s, _c, _opts), do: :ok
    def paste_text(_s, _t, _opts), do: :ok
  end
end
