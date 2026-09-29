defmodule Mix.Tasks.Casein.Tmux.Orphans do
  @moduledoc """
  Lists live `casein_*` tmux sessions whose workspace Casein no longer knows
  about (#20702).

      mix casein.tmux.orphans

  Deleting a workspace leaves its tmux session running: the milc-devbox manager
  owns workspace lifecycle and never tells Casein, so the session is in nobody's
  teardown. It keeps holding an agent-budget slot, and the UI close control
  cannot reach it because that control resolves a pane through its workspace.

  This task only *finds* them. It kills nothing, by design — see
  `Casein.Terminals.OrphanSessions` and the note in
  `Casein.Workspaces.Reconciler` on why reaping is a separately gated pass.

  Two confidences, and they must not be collapsed:

    * `retired` — Casein observed the manager stop vouching for the workspace.
      Safe to retire deliberately once you have confirmed it.
    * `unknown` — no workspace record matches. On a shared box this may simply
      be another developer's workspace that Casein never listed. **Go and look;
      do not treat it as a deletion.**

  Retire a confirmed one with `tmux kill-session -t <session>`.
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  alias Casein.Terminals.OrphanSessions

  @shortdoc "List tmux sessions whose workspace is gone"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    case OrphanSessions.list() do
      {:ok, []} ->
        Mix.shell().info("No orphan casein_* tmux sessions.")

      {:ok, orphans} ->
        report(orphans)

      {:error, reason} ->
        # Never printed as "no orphans": a failed inventory is not a clean box.
        Mix.raise("could not read the tmux session inventory: #{inspect(reason)}")
    end
  end

  defp report(orphans) do
    {retired, unknown} = Enum.split_with(orphans, &(&1.confidence == :retired))

    print_group(
      retired,
      "Workspace retired by the reconciler — Casein saw the manager drop it:"
    )

    print_group(
      unknown,
      "No matching workspace record — MAY BELONG TO ANOTHER USER, confirm before killing:"
    )

    Mix.shell().info("\nRetire one with: tmux kill-session -t <session>")
  end

  defp print_group([], _heading), do: :ok

  defp print_group(orphans, heading) do
    Mix.shell().info("\n#{heading}")

    Enum.each(orphans, fn orphan ->
      Mix.shell().info("  #{orphan.session}#{workspace_suffix(orphan)}#{attached_suffix(orphan)}")
    end)
  end

  defp workspace_suffix(%{workspace: nil}), do: ""
  defp workspace_suffix(%{workspace: name}), do: "  (workspace #{name})"

  defp attached_suffix(%{attached: true}), do: "  [attached]"
  defp attached_suffix(_), do: ""
end
