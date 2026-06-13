defmodule DevIdeWeb.WorkspaceLive.Show.UI do
  @moduledoc false

  use DevIdeWeb, :html

  def tab_class(current, current),
    do: "px-2.5 py-1 rounded bg-primary text-primary-content text-sm font-medium"

  def tab_class(_, _),
    do:
      "px-2.5 py-1 rounded text-sm text-base-content/70 hover:text-base-content hover:bg-base-200"

  def render_path({:ok, {:remote, host, path}}, _), do: "#{host}:#{path}"
  def render_path({:ok, {:local, path}}, _), do: path
  def render_path(_, {:ok, cwd}), do: cwd
  def render_path(_, {:error, :missing_path}), do: "(no host path)"
  def render_path(_, {:error, :outside_root}), do: "(path outside allowed roots)"
  def render_path(_, _), do: "(no host path)"

  def dom_fragment(value) when is_binary(value),
    do: String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")

  def dom_fragment(value), do: value |> to_string() |> dom_fragment()

  def redundant_workspace_path?(workspace_name, path)
      when is_binary(workspace_name) and is_binary(path) do
    workspace_name = String.trim(workspace_name)

    path
    |> String.trim()
    |> String.trim_trailing("/")
    |> Path.basename()
    |> Kernel.==(workspace_name)
  end

  def redundant_workspace_path?(_, _), do: false

  attr :key, :string, required: true
  attr :class, :string, default: nil
  attr :title, :string, default: nil
  attr :aria_label, :string, default: nil
  attr :phx_click, :string, default: nil
  attr :phx_value_dir, :string, default: nil
  attr :phx_value_mode, :string, default: nil
  attr :phx_value_window_id, :string, default: nil
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false

  slot :inner_block, required: true

  @doc false
  def leader_key_button(assigns) do
    ~H"""
    <div class="leader-key-control shrink-0" data-shortcut={leader_shortcut(@key)}>
      <button
        type="button"
        id={@id}
        disabled={@disabled}
        class={[
          "rounded border border-base-300 p-1 text-base-content/60 transition hover:bg-base-200 hover:text-base-content",
          @class
        ]}
        title={leader_title(@title, @key)}
        aria-label={@aria_label}
        phx-click={@phx_click}
        phx-value-dir={@phx_value_dir}
        phx-value-mode={@phx_value_mode}
        phx-value-window-id={@phx_value_window_id}
      >
        {render_slot(@inner_block)}
      </button>
    </div>
    """
  end

  defp leader_shortcut(key), do: "Ctrl + B, then " <> leader_key_label(key)

  defp leader_title(nil, key), do: "Shortcut: " <> leader_shortcut(key)

  defp leader_title(title, key) when is_binary(title) do
    label =
      title
      |> String.split("·", parts: 2)
      |> hd()
      |> String.trim()

    label <> ". Shortcut: " <> leader_shortcut(key)
  end

  defp leader_key_label(<<letter::binary-size(1)>> = key) do
    if key =~ ~r/[a-z]/, do: String.upcase(letter), else: key
  end

  defp leader_key_label(key), do: key
end
