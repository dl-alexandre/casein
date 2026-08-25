defmodule Casein.Agents.TerminalTools.Impl.Command do
  @moduledoc false

  alias Casein.Agents.PreviewTools
  alias Casein.FilePanes
  alias Casein.FilePanes.LinkResolver
  alias Casein.Files.BrowserViewable
  alias Casein.Inspectors.Diff
  alias Casein.Previews
  alias Casein.Runs.AgentLifecycle
  alias Casein.Terminals.PaneSubmit
  alias Casein.Terminals.PaneWriteReceipt
  alias Casein.Terminals.SharedWorktreeGuard
  alias Casein.Terminals.TuiSurface
  alias Casein.Terminals.TuiSurfaceGuard
  alias Casein.Workspaces

  import Casein.Agents.TerminalTools.Impl.Shared

  @doc "Send raw keys to a pane (defaults to the active pane)."
  @spec send_keys(map()) :: {:ok, map()} | {:error, term()}
  def send_keys(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, keys} <- string_arg(params, "keys"),
         {:ok, raw_target} <- target_arg(session, params) do
      {target, implicit?} = resolve_implicit_target(session, raw_target)

      with :ok <- guard_shared_worktree(session, target, keys, params) do
        # Backend/Adapter contract is `:ok | {:error, _}`; some adapters still
        # return `{out, code}`. Accept both so pinning `:tmux_adapter` to
        # Backends.Tmux (normalized) or legacy Client does not CaseClauseError.
        case tmux().send_keys(target, keys) do
          :ok -> {:ok, raw_sent_payload(session, target, implicit?, params, keys)}
          {_out, 0} -> {:ok, raw_sent_payload(session, target, implicit?, params, keys)}
          {:error, reason} -> {:error, reason}
          {out, _code} -> {:error, String.trim(out)}
        end
      end
    end
  end

  @doc "Send a command + Enter to a pane (defaults to the active pane)."
  @spec send_command(map()) :: {:ok, map()} | {:error, term()}
  def send_command(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, command} <- string_arg(params, "command"),
         {:ok, raw_target} <- target_arg(session, params) do
      {target, implicit?} = resolve_implicit_target(session, raw_target)

      with :ok <- guard_shared_worktree(session, target, command, params),
           {:ok, _surface} <- guard_tui_surface(session, target, params) do
        case tmux().send_command(target, command) do
          :ok ->
            # Fallback open for silent runtimes (Grok/OpenCode). Primary open is
            # still `:working` via AgentLifecycle.observe_state/1.
            note_lifecycle_send_command(params, session, target, command)
            confirm_raw_sent(session, target, implicit?, params)

          {:error, reason} ->
            {:error, reason}

          {out, _code} ->
            {:error, String.trim(out)}
        end
      end
    end
  end

  # Same contract as the agent-pane send tools: tmux accepting Enter is not the
  # pane consuming it. Fleet ops hit this path with an explicit worker pane id
  # (no agent_pair), so without confirmation `status: "sent"` was the double-
  # Enter folklore. Default confirm:true; pass false for TUI menus / y/n.
  defp confirm_raw_sent(session, target, implicit?, params) do
    written = Map.get(params, "command") || Map.get(params, :command)
    payload = raw_sent_payload(session, target, implicit?, params, written)
    confirm? = Map.get(params, "confirm") != false and Map.get(params, :confirm) != false

    case PaneSubmit.confirm_submit(session, target,
           confirm: confirm?,
           enter_already_sent: true,
           strict: true,
           written: written
         ) do
      {:ok, confirmation} ->
        confirmation = honest_submit(payload, confirmation)

        {:ok,
         payload
         |> Map.merge(stringify_confirmation(confirmation))
         |> PaneWriteReceipt.promote_observed(confirmation.delivery)}

      {:error, error} ->
        {:error, Map.merge(payload, stringify_confirmation(honest_submit(payload, error)))}
    end
  end

  defp guard_tui_surface(session, target, params) do
    TuiSurfaceGuard.check(session, target,
      allow_non_conversation: allow_non_conversation?(params),
      tmux: tmux()
    )
  end

  defp allow_non_conversation?(params) do
    truthy?(Map.get(params, "allow_non_conversation") || Map.get(params, :allow_non_conversation))
  end

  defp honest_submit(payload, result) when is_map(result) do
    Map.put(
      result,
      :submitted,
      TuiSurface.honest_submitted(payload_surface(payload), result[:submitted])
    )
  end

  defp payload_surface(payload) do
    name =
      get_in(payload, [:receipt, :surface]) ||
        get_in(payload, ["receipt", "surface"]) ||
        payload[:surface] || payload["surface"]

    case name do
      "conversation" -> :conversation
      "agents_view" -> :agents_view
      "menu" -> :menu
      "unknown" -> :unknown
      atom when is_atom(atom) and not is_nil(atom) -> atom
      _ -> :unknown
    end
  end

  defp note_lifecycle_send_command(params, session, target, command) do
    case workspace_id(params) do
      id when is_binary(id) and id != "" ->
        AgentLifecycle.note_send_command(%{
          workspace_id: id,
          tmux_session: session,
          pane_id: target,
          actor_id: string_param(params, "actor_id") || "agent",
          tool: "terminal_send_command",
          message: command,
          source: :send_command
        })

      _ ->
        :ok
    end
  end

  # `terminal_topology` has reported shared worktrees for a while, but the
  # warning reaches whoever asked for the topology — not the caller about to run
  # `git reset --hard` in the shared tree. Answer at the write instead. Soft:
  # `allow_shared_worktree: true` goes through, because adoption of an existing
  # worktree is a deliberate mode, not a mistake.
  defp guard_shared_worktree(session, target, command, params) do
    SharedWorktreeGuard.check(session, target, command,
      allow_shared_worktree:
        truthy?(
          Map.get(params, "allow_shared_worktree") || Map.get(params, :allow_shared_worktree)
        ),
      tmux: tmux()
    )
  end

  @doc """
  Open a workspace path in a file pane (or preview pane for browser-viewable
  types). Paths are re-validated via LinkResolver / PathSafety.
  """
  @spec open_file_in_pane(map()) :: {:ok, map()} | {:error, term()}
  def open_file_in_pane(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, path} <- string_arg(params, "path"),
         {:ok, workspace} <- fetch_workspace(workspace_id),
         {:ok, root} <- local_workspace_root(workspace),
         {:ok, rel} <- resolve_workspace_path(root, path),
         {:ok, session} <- session_for_file_open(params) do
      line = line_param(params)
      surface = BrowserViewable.surface(rel)

      case surface do
        :preview -> open_file_preview_surface(workspace, session, rel, params)
        :file -> open_file_editor_surface(workspace, session, rel, line, params)
      end
    end
  end

  defp fetch_workspace(workspace_id) do
    case Workspaces.get(workspace_id) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, :not_found} -> {:error, :workspace_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_workspace_root(workspace) do
    case Workspaces.safe_host_loc(workspace) do
      {:ok, {:local, root}} when is_binary(root) and root != "" -> {:ok, root}
      {:ok, {:remote, _, _}} -> {:error, :remote_workspace_unsupported}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :workspace_not_found}
    end
  end

  # Never trust the raw path — same confinement as terminal:open_file_link.
  defp resolve_workspace_path(root, path) do
    case LinkResolver.resolve(root, path) do
      {:ok, rel} -> {:ok, rel}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_for_file_open(params) do
    case session_or_default_arg(params) do
      {:ok, session} ->
        {:ok, session}

      {:error, :no_workspace_sessions} ->
        {:error, :no_live_session}

      {:error, :no_such_session} ->
        {:error, :no_live_session}

      {:error, %{error: :ambiguous_workspace_sessions} = error} ->
        {:error, error}

      other ->
        other
    end
  end

  defp open_file_editor_surface(workspace, session, rel, line, params) do
    opts =
      [
        tmux_session: session,
        line: line,
        actor_id: string_param(params, "actor_id")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case FilePanes.open_file_in_pane(workspace, rel, opts) do
      {:ok, %{pane_id: pane_id, registration: reg, reused: reused}} ->
        {:ok,
         compact(%{
           workspace_id: workspace_id(params) || workspace.id,
           session: session,
           path: rel,
           line: line,
           surface: "file",
           pane_id: pane_id,
           reused: reused,
           active_path: reg.active_path,
           open_files: Enum.map(reg.open_files, &compact(%{path: &1.path, line: &1.line})),
           status: "opened"
         })}

      {:error, reason} when reason in [:no_tmux_session, :no_active_pane, :window_not_found] ->
        {:error, :no_live_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_file_preview_surface(workspace, session, rel, params) do
    with {:ok, port} <- Previews.ensure_started(workspace, tmux_session: session) do
      url = "http://127.0.0.1:#{port}/" <> URI.encode(rel)

      opts =
        [
          tmux_session: session,
          actor_id: string_param(params, "actor_id")
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case PreviewTools.split_preview_pane(workspace, url, opts) do
        {:ok, %{pane_id: pane_id} = result} ->
          registration = Map.get(result, :registration)

          {:ok,
           compact(%{
             workspace_id: workspace_id(params) || workspace.id,
             session: session,
             path: rel,
             surface: "preview",
             pane_id: pane_id,
             url: url,
             source_url: registration && Map.get(registration, :source_url),
             control_session_id: registration && Map.get(registration, :control_session_id),
             reused: Map.get(result, :reused, false),
             status: "opened"
           })}

        {:error, reason} when reason in [:no_tmux_session, :no_active_pane, :window_not_found] ->
          {:error, :no_live_session}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  One-shot intent: surface a git diff to a connected cockpit viewer.

  Takes **what** (optional path), never **where**. No pane handle is returned.
  When no viewer is watching the workspace the call is a no-op (`status:
  "no_viewer"`) — do not queue or persist.
  """
  @spec open_diff(map()) :: {:ok, map()} | {:error, term()}
  def open_diff(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, workspace} <- fetch_workspace(workspace_id),
         {:ok, path} <- optional_diff_path(workspace, params) do
      Diff.surface(workspace.id, %{
        path: path,
        actor_id: string_param(params, "actor_id")
      })
    end
  end

  @doc """
  One-shot intent: surface the run ledger to a connected cockpit viewer.

  Takes **what** (optional run_id), never **where**. No pane handle is returned.
  A missing run id lands on the ledger with nothing selected. When no viewer is
  watching the workspace the call is a no-op (`status: "no_viewer"`).
  """
  @spec open_run(map()) :: {:ok, map()} | {:error, term()}
  def open_run(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, workspace} <- fetch_workspace(workspace_id) do
      Casein.Inspectors.Run.surface(workspace.id, %{
        run_id: optional_run_id(params),
        actor_id: string_param(params, "actor_id")
      })
    end
  end

  defp optional_run_id(params) do
    case string_param(params, "run_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # Optional path: when present, confine it the same way file opens do. When
  # absent, surface the workspace-wide diff overview.
  defp optional_diff_path(workspace, params) do
    case string_param(params, "path") do
      nil ->
        {:ok, nil}

      path ->
        with {:ok, root} <- local_workspace_root(workspace) do
          resolve_workspace_path(root, path)
        end
    end
  end

  defp line_param(params) do
    case Map.get(params, "line") || Map.get(params, :line) do
      line when is_integer(line) and line > 0 -> line
      _ -> nil
    end
  end

  defp raw_sent_payload(session, target, implicit?, params, written) do
    payload =
      %{session: session, target: target, status: "sent"}
      |> put_next("terminal_capture", capture_next_args(session, target, params))
      |> PaneWriteReceipt.attach(session, target, written)

    if implicit? do
      Map.merge(payload, %{
        safe_to_mutate: false,
        target_was_active_pane: true,
        targeting_warning:
          "No pane was supplied; input went to the operator-focused active pane, which " <>
            "follows the operator across windows. Prefer terminal_send_agent_command or " <>
            "pass an explicit pane id (see terminal_topology caller.adjacent_panes)."
      })
    else
      Map.put(payload, :safe_to_mutate, true)
    end
  end
end
