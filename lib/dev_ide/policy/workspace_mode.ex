defmodule DevIDE.Policy.WorkspaceMode do
  @moduledoc """
  Workspace safety mode.

  Modes (M10):

    * `:manual`              — human edits via the IDE; agents are read-only.
    * `:review`              — human edits; agents can produce proposals only;
                               apply is blocked.
    * `:agent_write_locked`  — agent write affordances are visible but locked
                               and require an explicit (future) unlock.
    * `:shared_stage_guarded` — any write-capable agent path is blocked because
                               the workspace uses a shared Stage DB.

  Resolution order:

    1. `:dev_ide, :workspace_modes` (map keyed by workspace id) override.
    2. `:dev_ide, :default_workspace_mode` config value.
    3. `:manual` default.
  """

  @valid ~w(manual review agent_write_locked shared_stage_guarded)a

  @type t :: :manual | :review | :agent_write_locked | :shared_stage_guarded

  @spec valid_modes() :: [t()]
  def valid_modes, do: @valid

  @spec resolve(map() | String.t() | nil) :: t()
  def resolve(%{id: id}), do: resolve(id)
  def resolve(%{"id" => id}), do: resolve(id)

  def resolve(workspace_id) when is_binary(workspace_id) do
    overrides = Application.get_env(:dev_ide, :workspace_modes, %{})

    overrides
    |> Map.get(workspace_id)
    |> ensure_valid()
    |> Kernel.||(default_mode())
  end

  def resolve(_), do: default_mode()

  defp default_mode do
    Application.get_env(:dev_ide, :default_workspace_mode, :manual)
    |> ensure_valid()
    |> Kernel.||(:manual)
  end

  defp ensure_valid(mode) when mode in @valid, do: mode
  defp ensure_valid(_), do: nil
end
