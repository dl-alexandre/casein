defmodule CaseinWeb.WorkspaceLive.Show.UI do
  @moduledoc false

  use CaseinWeb, :html

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

  @doc """
  The distinguishing tail of a workspace name for cramped chrome.

  Workspace names are often owner/repo style (e.g. `dalexandre/casein`) where
  the owner segment repeats across every workspace and is pure noise — naive
  truncation surfaces only that prefix (`dalexandre…`) and hides the repo. This
  returns the final path segment (`casein`); the full name stays in tooltips.
  """
  def workspace_short_name(name) when is_binary(name) do
    trimmed = name |> String.trim() |> String.trim_trailing("/")

    case Path.basename(trimmed) do
      "" -> trimmed
      base -> base
    end
  end

  def workspace_short_name(name), do: name

  @doc """
  Header breadcrumbs (path-first navigation Stage 3).

  Root crumb links to the dashboard at `/`; in trusted LAN deployments the
  workspace's parent directories follow, each linking to the dashboard scoped
  to that directory (`/?dir=...`). The workspace name itself is rendered by the
  shell right after this slot, so the trail stops at the parent. Untrusted
  deployments (opaque id URLs) get only the root crumb — path shape stays out
  of the page.
  """
  attr :workspace_route, :string, default: nil

  def workspace_breadcrumbs(assigns) do
    assigns =
      Phoenix.Component.assign(assigns, :crumbs, breadcrumb_trail(assigns.workspace_route))

    ~H"""
    <nav
      :if={@crumbs != []}
      class="flex min-w-0 shrink items-center gap-1"
      aria-label="Breadcrumb"
    >
      <span :for={crumb <- @crumbs} class="hidden min-w-0 items-center gap-1 sm:inline-flex">
        <span class="max-w-32 truncate font-mono text-xs text-base-content/60">
          {crumb.label}
        </span>
        <span class="text-base-content/40" aria-hidden="true">/</span>
      </span>
    </nav>
    """
  end

  @doc """
  The intermediate directory crumbs for a workspace route: every segment above
  the workspace itself, as `%{label, dir}` with `dir` the root-relative path
  for the dashboard's `?dir=` param. Empty when path routes are untrusted or
  the route has no parent directories.
  """
  def breadcrumb_trail(workspace_route) do
    if is_binary(workspace_route) and CaseinWeb.WorkspaceRoutes.path_routes_trusted?() do
      segments =
        workspace_route
        |> String.trim_leading("/")
        |> String.split("/", trim: true)
        |> Enum.map(&URI.decode/1)

      segments
      |> Enum.drop(-1)
      |> Enum.with_index(1)
      |> Enum.map(fn {segment, index} ->
        %{label: segment, dir: segments |> Enum.take(index) |> Path.join()}
      end)
    else
      []
    end
  end

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
    <div
      class="leader-key-control relative shrink-0"
      data-shortcut={leader_shortcut(@key)}
      data-leader-second-key={leader_key_label(@key)}
    >
      <button
        type="button"
        id={@id}
        disabled={@disabled}
        class={[
          "rounded border border-base-300 p-0.5 text-base-content/60 transition hover:bg-base-200 hover:text-base-content",
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
