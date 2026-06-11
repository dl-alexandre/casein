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
end
