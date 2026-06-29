defmodule DevIDE.Terminals.TmuxServer do
  @moduledoc """
  Shared tmux server-label (`-L`) resolution for every tmux invocation.

  ## Why this exists

  Every environment runs DevIDE's tmux sessions on its **own** dedicated
  server, so they never collide with each other or with a plain SSH user's
  `tmux` (which uses the host's *default* server). Each `-L <label>` is a fully
  independent server: its own socket, session list, option state, and — for
  host sessions — its own config file (`TmuxRunner` appends `-f`, defaulting to
  `priv/tmux/devide.conf`). One server = one config.

  | Env  | Label (`-L`)  | Set in            |
  |------|---------------|-------------------|
  | prod | `devide`      | `config/prod.exs` |
  | dev  | `devide_dev`  | `config/dev.exs`  |
  | test | `devide_test` | `config/test.exs` |

  The labels must differ per env because the `:4000` dev server and the prod
  release run as the same user on the devbox — a shared label would put both on
  one socket. The test label additionally sandboxes the live integration tests
  (e.g. `workspace_pane_split_test.exs`), which create/kill/reconcile real
  sessions, so they can never see or touch prod sessions.

  Set via `config :dev_ide, :tmux_server_label, "<label>"`. If left unset
  (`args/0` returns `[]`), DevIDE falls back to the host's default server and
  shares it with plain SSH tmux — avoid that on a shared host.

  > **Migration note.** Changing or first-introducing a label points DevIDE at
  > a *fresh, empty* server. Sessions on the previously-used server stay alive
  > but become invisible to DevIDE (it won't list/attach/reconcile them); new
  > sessions are created on the new server as workspaces reopen. See
  > `docs/subsystems/terminals.md` for the operator cutover note.
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
