defmodule DevIDE.CommandPalette.Item do
  @moduledoc "A single palette result row."

  @type kind :: :file | :action | :command | :tab
  @type category :: :files | :commands | :tmux | :agents | :preview | :view | :actions
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t() | nil,
          score: integer(),
          category: category() | nil,
          payload: map()
        }

  @enforce_keys [:id, :kind, :label]
  defstruct [:id, :kind, :label, :detail, :category, score: 0, payload: %{}]

  @doc """
  Category an item belongs to for the palette's category tabs.

  Honors an explicit `:category` when set (so a `:action`-kind tmux verb can
  live under the Tmux tab), otherwise derives one from `kind`.
  """
  @spec category(t()) :: category()
  def category(%__MODULE__{category: c}) when not is_nil(c), do: c
  def category(%__MODULE__{kind: :file}), do: :files
  def category(%__MODULE__{kind: :command}), do: :commands
  def category(%__MODULE__{kind: _}), do: :actions
end
