defmodule Casein.Terminals.CleanExec do
  @moduledoc """
  Wraps long-lived terminal child argv so they do not inherit app sockets.

  BEAM and Phoenix keep listener, database, and distribution descriptors open
  above stdio. erlexec/Ghostty PTY children can inherit them unless the command
  closes descriptors after fork and before the final exec. A process holding
  those fds can block deploy restarts even after the app process exits.

  ## tmux is exempt

  `tmux new-session` (without `-d`) forks a *server* that `daemon()`s — closing
  all inherited descriptors itself — and a short-lived foreground *client* that
  dies with the pane. So tmux does not leak BEAM sockets past a deploy on its
  own. Worse, pre-closing fds in a shell wrapper before `exec`-ing tmux reliably
  breaks the foreground `new-session` attach: the client fails to establish the
  session and exits 0, surfacing as "Terminal exited 0" in the pane (regression
  from wiring this wrapper into the host-shell ghostty path). Empirically, ANY
  fd close/redirect before `exec tmux ...` breaks it, while a bare `exec "$@"`
  works 100%. We therefore pass tmux argv through untouched and only scrub fds
  for genuine non-tmux raw execs.
  """

  @close_inherited_fds_script """
  for fd_path in /proc/$$/fd/*; do
    fd=${fd_path##*/}

    case "$fd" in
      0|1|2|''|*[!0-9]*) ;;
      *) eval "exec ${fd}>&-" 2>/dev/null || true ;;
    esac
  done

  exec "$@"
  """

  @spec wrap_argv([String.t()]) :: [String.t()]
  def wrap_argv(argv) when is_list(argv) do
    if tmux_argv?(argv) do
      # tmux self-daemonizes (server closes inherited fds); wrapping it breaks
      # the foreground new-session attach. Leave it untouched.
      argv
    else
      ["/bin/sh", "-c", @close_inherited_fds_script, "devide-clean-exec" | argv]
    end
  end

  # The argv may be prefixed with `env VAR=... ...` or `docker compose exec
  # <svc> ...` before the real program, so scan every token. Match tmux by
  # basename so a resolved absolute path (`/usr/bin/tmux`) is still recognized —
  # an exact `"tmux"` check would miss it and re-wrap, re-breaking the pane.
  defp tmux_argv?(argv) do
    Enum.any?(argv, &tmux_token?/1)
  end

  defp tmux_token?(token) when is_binary(token), do: Path.basename(token) == "tmux"
  defp tmux_token?(_token), do: false
end
