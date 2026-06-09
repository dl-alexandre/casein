defmodule DevIDE.Agents.TerminalTools do
  @moduledoc """
  Narrow agent-facing tmux operations.

  This is the terminal counterpart to `DevIDE.Agents.PreviewTools`: it lets
  external coding agents (Grok, Claude, Codex, opencode) drive DevIDE's tmux
  sessions the way a human would from the CLI — discover live sessions, read a
  pane's scrollback to debug a server, and send keys/commands — without
  arbitrary shell access on the host.

  Every session-scoped tool is guarded to `devide_`-prefixed sessions
  (`DevIDE.Terminals.Tmux.session_name/2`'s shape), so agents can only see and
  touch DevIDE-managed sessions, never unrelated tmux sessions that happen to
  share the host's tmux server.
  """

  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology

  @session_prefix "devide_"

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    [
      %{
        name: "terminal_list_sessions",
        description:
          "List live DevIDE-managed tmux sessions (name, whether a client is " <>
            "attached, last activity). Start here to discover a session name to " <>
            "operate on. Optional `contains` filters by substring.",
        parameters: %{
          type: "object",
          properties: %{contains: %{type: "string"}},
          required: []
        }
      },
      %{
        name: "terminal_topology",
        description:
          "Inspect a session's structure: its windows and panes with geometry, " <>
            "the running command per pane, and which window/pane is active.",
        parameters: %{
          type: "object",
          properties: %{session: %{type: "string"}},
          required: ["session"]
        }
      },
      %{
        name: "terminal_capture",
        description:
          "Capture a pane's scrollback to read a server log or command output. " <>
            "By default reads the session's active pane and full history; pass " <>
            "`pane` (a pane id from terminal_topology, e.g. \"%3\") to read a " <>
            "specific non-focused pane, `lines` to tail only the last N lines, " <>
            "and `ansi: false` for plain text (fewer tokens).",
        parameters: %{
          type: "object",
          properties: %{
            session: %{type: "string"},
            pane: %{
              type: "string",
              description: "Pane id from terminal_topology (e.g. \"%3\"); default: active pane."
            },
            lines: %{
              type: "integer",
              description: "Return only the last N lines. Omit for full scrollback."
            },
            ansi: %{
              type: "boolean",
              description: "Keep ANSI color/escape codes. Default true; false for plain text."
            }
          },
          required: ["session"]
        }
      },
      %{
        name: "terminal_send_keys",
        description:
          "Send raw keystrokes to a pane WITHOUT a trailing Enter. Use tmux key " <>
            "names for control keys (e.g. \"C-c\", \"Up\", \"Enter\"). Defaults to " <>
            "the active pane; pass `pane` to target a specific one. For running a " <>
            "shell command, prefer terminal_send_command.",
        parameters: %{
          type: "object",
          properties: %{
            session: %{type: "string"},
            keys: %{type: "string"},
            pane: %{
              type: "string",
              description: "Pane id from terminal_topology (e.g. \"%3\"); default: active pane."
            }
          },
          required: ["session", "keys"]
        }
      },
      %{
        name: "terminal_send_command",
        description:
          "Type a shell command into a pane and press Enter. Defaults to the " <>
            "active pane; pass `pane` to target a specific one. Read the result " <>
            "afterward with terminal_capture.",
        parameters: %{
          type: "object",
          properties: %{
            session: %{type: "string"},
            command: %{type: "string"},
            pane: %{
              type: "string",
              description: "Pane id from terminal_topology (e.g. \"%3\"); default: active pane."
            }
          },
          required: ["session", "command"]
        }
      }
    ]
  end

  @doc "Dispatch a named agent terminal tool."
  @spec invoke(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, params) when is_map(params) do
    case tool_name do
      "terminal_list_sessions" -> list_sessions(params)
      "terminal_topology" -> topology(params)
      "terminal_capture" -> capture(params)
      "terminal_send_keys" -> send_keys(params)
      "terminal_send_command" -> send_command(params)
      _ -> {:error, :unknown_tool}
    end
  end

  @doc "List live DevIDE-managed tmux sessions."
  @spec list_sessions(map()) :: {:ok, map()}
  def list_sessions(params \\ %{}) do
    contains = Map.get(params, "contains") || Map.get(params, :contains)

    sessions =
      Tmux.list_sessions()
      |> Enum.filter(&String.starts_with?(&1.session, @session_prefix))
      |> filter_contains(contains)

    {:ok, %{sessions: sessions}}
  end

  @doc "Return a session's window/pane topology."
  @spec topology(map()) :: {:ok, map()} | {:error, term()}
  def topology(params) do
    with {:ok, session} <- session_arg(params) do
      {:ok, TmuxTopology.snapshot(session)}
    end
  end

  @doc "Capture a pane's scrollback for a session (defaults to the active pane)."
  @spec capture(map()) :: {:ok, map()} | {:error, term()}
  def capture(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, target} <- target_arg(session, params) do
      opts = [ansi: Map.get(params, "ansi", true) != false] |> put_lines(Map.get(params, "lines"))
      {:ok, %{session: session, target: target, output: Tmux.capture_scrollback(target, opts)}}
    end
  end

  @doc "Send raw keys to a pane (defaults to the active pane)."
  @spec send_keys(map()) :: {:ok, map()} | {:error, term()}
  def send_keys(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, keys} <- string_arg(params, "keys"),
         {:ok, target} <- target_arg(session, params) do
      case Tmux.send_keys(target, keys) do
        {_out, 0} -> {:ok, %{session: session, target: target, status: "sent"}}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
  end

  @doc "Send a command + Enter to a pane (defaults to the active pane)."
  @spec send_command(map()) :: {:ok, map()} | {:error, term()}
  def send_command(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, command} <- string_arg(params, "command"),
         {:ok, target} <- target_arg(session, params) do
      case Tmux.send_command(target, command) do
        :ok -> {:ok, %{session: session, target: target, status: "sent"}}
        {:error, reason} -> {:error, reason}
        {out, _code} -> {:error, String.trim(out)}
      end
    end
  end

  # Resolve and validate the `session` argument: it must be a non-empty,
  # DevIDE-prefixed name that the tmux server currently knows about.
  defp session_arg(params) do
    with {:ok, session} <- string_arg(params, "session"),
         true <- String.starts_with?(session, @session_prefix) || {:error, :unscoped_session},
         true <- Tmux.session_exists?(session) || {:error, :no_such_session} do
      {:ok, session}
    end
  end

  # Resolve the `pane` argument to a tmux target, defaulting to the session
  # (its active pane). A supplied pane id must belong to this session — that
  # keeps the `devide_` guardrail intact, since raw `%N` ids are server-global
  # and would otherwise let an agent address a pane in another session.
  defp target_arg(session, params) do
    case Map.get(params, "pane") do
      pane when pane in [nil, ""] ->
        {:ok, session}

      pane when is_binary(pane) ->
        if pane in pane_ids(session), do: {:ok, pane}, else: {:error, :pane_not_in_session}

      _ ->
        {:error, :invalid_pane}
    end
  end

  defp pane_ids(session), do: session |> Tmux.list_session_panes() |> Enum.map(& &1.id)

  defp put_lines(opts, n) when is_integer(n) and n > 0, do: [{:lines, min(n, 5000)} | opts]
  defp put_lines(opts, _), do: opts

  # MCP params arrive JSON-decoded with string keys, so a string lookup is
  # sufficient — no atom conversion (Iron Law #10: atom-exhaustion DoS).
  defp string_arg(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  defp filter_contains(sessions, nil), do: sessions
  defp filter_contains(sessions, ""), do: sessions

  defp filter_contains(sessions, needle) when is_binary(needle),
    do: Enum.filter(sessions, &String.contains?(&1.session, needle))
end
