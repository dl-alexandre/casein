defmodule Casein.Agents.TerminalTools.Impl.SelfTest do
  @moduledoc false

  # Runtime probe of the MCP terminal verb surface against the *running*
  # adapter (`Shared.tmux/0`). Catches the #854 class: a backend that boots
  # cleanly while missing functions callers invoke (e.g. paste_text/3).
  #
  # Safe on a live fleet: creates a throwaway casein_mcp_self_test_* session,
  # confines any writes there, and always kills it. No agent panes, no fleet
  # sessions, no destructive verbs (kill_window/kill_pane/etc.).

  alias Casein.Terminals.Backend

  import Casein.Agents.TerminalTools.Impl.Shared, only: [tmux: 0]

  @session_prefix "casein_mcp_self_test_"
  @probe_marker "casein-mcp-self-test"
  @capture_lines 20

  # MCP verbs → adapter calls at the exact arities Impl.* uses today.
  # Keep this table in lockstep with lib/casein/agents/terminal_tools/impl/*.ex
  # call sites (compile-time conformance is #861; this is the runtime probe).
  @verb_probes [
    %{
      verb: "terminal_list_sessions",
      fun: :list_sessions,
      arity: 0,
      kind: :read
    },
    %{
      verb: "terminal_topology",
      fun: :list_session_panes,
      arity: 1,
      kind: :read
    },
    %{
      verb: "terminal_capture",
      fun: :capture_scrollback,
      arity: 2,
      kind: :read
    },
    %{
      verb: "terminal_capture_agent",
      fun: :capture_scrollback,
      arity: 2,
      kind: :read
    },
    %{
      # Impl.Command calls send_command(target, command) — arity 2.
      verb: "terminal_send_command",
      fun: :send_command,
      arity: 2,
      kind: :write
    },
    %{
      # Impl.Command calls send_keys(target, keys) — arity 2. The #854
      # regression: Backends.Tmux only exported send_keys/3.
      verb: "terminal_send_keys",
      fun: :send_keys,
      arity: 2,
      kind: :write
    },
    %{
      # Impl.Agent calls paste_text(session, text, opts) — arity 3. The
      # incident that motivated this tool: paste_text/3 missing on prod backend.
      verb: "terminal_paste_agent_text",
      fun: :paste_text,
      arity: 3,
      kind: :write
    },
    %{
      verb: "terminal_send_agent_command",
      fun: :send_command,
      arity: 3,
      kind: :write
    },
    %{
      verb: "terminal_send_agent_keys",
      fun: :send_keys,
      arity: 3,
      kind: :write
    }
  ]

  @doc """
  Run the MCP self-test against the live configured adapter.

  Returns `{:ok, report}` always when the probe itself completes; individual
  verbs inside `report.verbs` carry `"ok" | "undefined" | "error"`.
  """
  @spec run(map()) :: {:ok, map()}
  def run(_params \\ %{}) do
    adapter = tmux()
    backend = Backend.module()
    Code.ensure_loaded(adapter)
    Code.ensure_loaded(backend)

    session = @session_prefix <> Integer.to_string(System.unique_integer([:positive]))
    cwd = scratch_cwd()

    try do
      case ensure_scratch_session(adapter, backend, session, cwd) do
        :ok ->
          verbs =
            Enum.map(@verb_probes, fn probe ->
              probe_verb(adapter, session, probe)
            end)

          {:ok, report(adapter, backend, session, verbs, scratch_ok: true)}

        {:error, reason} ->
          # Still report export checks so a missing function is visible even
          # when we cannot open a scratch pane (infra / fake adapter).
          verbs =
            Enum.map(@verb_probes, fn probe ->
              export_only_probe(adapter, probe, {:scratch_unavailable, reason})
            end)

          {:ok,
           report(adapter, backend, session, verbs, scratch_ok: false, scratch_error: reason)}
      end
    after
      _ = safe_kill(adapter, backend, session)
    end
  end

  defp report(adapter, backend, session, verbs, opts) do
    undefined =
      Enum.count(verbs, fn v -> v.status == "undefined" end)

    errors =
      Enum.count(verbs, fn v -> v.status == "error" end)

    oks =
      Enum.count(verbs, fn v -> v.status == "ok" end)

    %{
      ok?: undefined == 0 and errors == 0,
      resolved_adapter: module_name(adapter),
      terminal_backend: module_name(backend),
      tmux_adapter_env: env_module_name(Application.get_env(:casein, :tmux_adapter)),
      terminal_backend_env: env_module_name(Application.get_env(:casein, :terminal_backend)),
      scratch_session: session,
      scratch_ok?: Keyword.get(opts, :scratch_ok, false),
      scratch_error: opts |> Keyword.get(:scratch_error) |> stringify_error(),
      summary: %{ok: oks, undefined: undefined, error: errors, total: length(verbs)},
      verbs: verbs
    }
    |> reject_nils()
  end

  defp probe_verb(adapter, session, %{fun: fun, arity: arity, verb: verb, kind: kind} = probe) do
    base = %{
      verb: verb,
      fun: Atom.to_string(fun),
      arity: arity,
      kind: Atom.to_string(kind)
    }

    cond do
      not function_exported?(adapter, fun, arity) ->
        Map.merge(base, %{
          status: "undefined",
          detail:
            "#{module_name(adapter)}.#{fun}/#{arity} is undefined — MCP #{verb} will raise UndefinedFunctionError"
        })

      true ->
        case apply_probe(adapter, session, probe) do
          :ok ->
            Map.merge(base, %{status: "ok", detail: "exported and live call succeeded"})

          {:error, reason} ->
            Map.merge(base, %{
              status: "error",
              detail: stringify_error(reason)
            })
        end
    end
  rescue
    e in [UndefinedFunctionError] ->
      Map.merge(
        %{
          verb: verb,
          fun: Atom.to_string(fun),
          arity: arity,
          kind: Atom.to_string(kind)
        },
        %{
          status: "undefined",
          detail: Exception.message(e)
        }
      )

    e ->
      Map.merge(
        %{
          verb: verb,
          fun: Atom.to_string(fun),
          arity: arity,
          kind: Atom.to_string(kind)
        },
        %{
          status: "error",
          detail: Exception.message(e)
        }
      )
  end

  defp export_only_probe(adapter, %{fun: fun, arity: arity, verb: verb, kind: kind}, reason) do
    base = %{
      verb: verb,
      fun: Atom.to_string(fun),
      arity: arity,
      kind: Atom.to_string(kind)
    }

    if function_exported?(adapter, fun, arity) do
      Map.merge(base, %{
        status: "error",
        detail: "exported but live call skipped: scratch unavailable (#{stringify_error(reason)})"
      })
    else
      Map.merge(base, %{
        status: "undefined",
        detail:
          "#{module_name(adapter)}.#{fun}/#{arity} is undefined — MCP #{verb} will raise UndefinedFunctionError"
      })
    end
  end

  defp apply_probe(adapter, _session, %{fun: :list_sessions, arity: 0}) do
    case adapter.list_sessions() do
      list when is_list(list) -> :ok
      other -> {:error, {:unexpected_return, other}}
    end
  end

  defp apply_probe(adapter, session, %{fun: :list_session_panes, arity: 1}) do
    case adapter.list_session_panes(session) do
      list when is_list(list) -> :ok
      other -> {:error, {:unexpected_return, other}}
    end
  end

  defp apply_probe(adapter, session, %{fun: :capture_scrollback, arity: 2}) do
    case adapter.capture_scrollback(session, lines: @capture_lines) do
      out when is_binary(out) -> :ok
      other -> {:error, {:unexpected_return, other}}
    end
  end

  # Impl.Command: send_command(target, command) — target is session or pane id.
  defp apply_probe(adapter, session, %{fun: :send_command, arity: 2}) do
    classify_write(adapter.send_command(session, "true # #{@probe_marker}"))
  end

  # Impl.Agent: send_command(session, command, opts)
  defp apply_probe(adapter, session, %{fun: :send_command, arity: 3}) do
    classify_write(adapter.send_command(session, "true # #{@probe_marker}-agent", []))
  end

  # Impl.Command: send_keys(target, keys)
  defp apply_probe(adapter, session, %{fun: :send_keys, arity: 2}) do
    classify_write(adapter.send_keys(session, ""))
  end

  # Impl.Agent: send_keys(session, keys, opts)
  defp apply_probe(adapter, session, %{fun: :send_keys, arity: 3}) do
    classify_write(adapter.send_keys(session, "", []))
  end

  # Impl.Agent: paste_text(session, text, opts)
  defp apply_probe(adapter, session, %{fun: :paste_text, arity: 3}) do
    # submit: false — leave no Enter; scratch pane only.
    classify_write(adapter.paste_text(session, @probe_marker, submit: false))
  end

  defp classify_write(:ok), do: :ok
  defp classify_write({_out, 0}), do: :ok
  defp classify_write({:error, reason}), do: {:error, reason}
  defp classify_write({out, code}) when is_integer(code), do: {:error, {:exit, code, out}}
  defp classify_write(other), do: {:error, {:unexpected_return, other}}

  # Prefer the same module MCP dispatch uses (`adapter` == Shared.tmux/0 ==
  # Terminals.tmux_adapter/0 after #892). Backend.module/0 is only a fallback
  # when the adapter does not export ensure_session/2.
  defp ensure_scratch_session(adapter, backend, session, cwd) do
    Code.ensure_loaded(adapter)
    Code.ensure_loaded(backend)

    cond do
      function_exported?(adapter, :ensure_session, 2) ->
        call_ensure(adapter, session, cwd)

      function_exported?(backend, :ensure_session, 2) ->
        call_ensure(backend, session, cwd)

      true ->
        {:error, :ensure_session_undefined}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp call_ensure(mod, session, cwd) do
    case mod.ensure_session(session, cwd) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  end

  defp safe_kill(adapter, backend, session) do
    cond do
      function_exported?(adapter, :kill, 1) -> adapter.kill(session)
      function_exported?(backend, :kill, 1) -> backend.kill(session)
      true -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp scratch_cwd do
    [System.tmp_dir(), System.get_env("HOME"), "/"]
    |> Enum.find("/", fn d -> is_binary(d) and d != "" and File.dir?(d) end)
  end

  defp module_name(mod) when is_atom(mod), do: inspect(mod)
  defp module_name(other), do: inspect(other)

  defp env_module_name(nil), do: nil
  defp env_module_name(mod) when is_atom(mod), do: inspect(mod)
  defp env_module_name(other), do: inspect(other)

  defp stringify_error(nil), do: nil
  defp stringify_error(reason) when is_binary(reason), do: reason
  defp stringify_error(reason), do: inspect(reason)

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
