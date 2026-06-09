defmodule DevIDE.Terminals.CleanExec do
  @moduledoc """
  Wraps long-lived terminal child argv so they do not inherit app sockets.

  BEAM and Phoenix keep listener, database, and distribution descriptors open
  above stdio. erlexec/Ghostty PTY children can inherit them unless the command
  closes descriptors after fork and before the final exec. A tmux client holding
  those fds can block deploy restarts even after the app process exits.
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
    ["/bin/sh", "-c", @close_inherited_fds_script, "devide-clean-exec" | argv]
  end
end
