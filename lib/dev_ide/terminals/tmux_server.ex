defmodule DevIDE.Terminals.TmuxServer do
  @moduledoc """
  Shared tmux server-label (`-L`) resolution for every tmux invocation.

  ## Why this exists

  DevIDE drives tmux on the host's **default** server, which on the devbox is
  the same server that hosts live user workspaces. The live integration tests
  (e.g. `workspace_pane_split_test.exs`) create, kill, and reconcile real tmux
  sessions. Under GitHub Actions that was harmless — a throwaway runner with
  its own tmux. Run on the devbox itself (pre-push gate or a manual
  `mix test`), those tests share the production server and can churn or kill
  live sessions, including broad `list-sessions` + prefix-kill sweeps.

  Pointing every tmux call at a dedicated server in `:test`
  (`-L devide_test`) sandboxes the suite: it can never see or touch sessions on
  the default server. Prod/dev leave the label unset → default server, so
  behaviour there is byte-for-byte unchanged (`args/0` returns `[]`).

  Set via `config :dev_ide, :tmux_server_label, "devide_test"` (test only).
  """

  @doc "Configured tmux server label, or nil for the default server."
  @spec label() :: String.t() | nil
  def label do
    case Application.get_env(:dev_ide, :tmux_server_label) do
      label when is_binary(label) and label != "" -> label
      _ -> nil
    end
  end

  @doc """
  tmux global args selecting the configured server (`["-L", label]`), or `[]`
  for the default server. Prepend to the subcommand: `["tmux"] ++ args() ++ sub`.
  """
  @spec args() :: [String.t()]
  def args do
    case label() do
      nil -> []
      label -> ["-L", label]
    end
  end
end
