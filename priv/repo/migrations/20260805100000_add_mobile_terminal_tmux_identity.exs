defmodule Casein.Repo.Migrations.AddMobileTerminalTmuxIdentity do
  use Ecto.Migration

  def change do
    alter table(:mobile_terminal_sessions) do
      add :tmux_native_id, :text
      add :tmux_lease_marker, :text
    end
  end
end
