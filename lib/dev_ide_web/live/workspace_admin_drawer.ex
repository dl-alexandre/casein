defmodule DevIdeWeb.WorkspaceAdminDrawer do
  @moduledoc """
  Header workspace-admin drawer for the cockpit shell.

  Houses create / attach-folder / start / stop / admin show-all actions that
  used to live on `WorkspaceLive.Dashboard`, so Stage 4c can retire `/` as a
  full-page dashboard. The workspace *listing* itself lives in the SESSIONS
  sidebar; this drawer is action-only plus a compact start/stop list.
  """

  use DevIdeWeb, :html

  attr :id, :string, default: "workspace-admin-bell"
  attr :open, :boolean, required: true

  def admin_bell(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="workspace_admin:toggle"
      class={[
        "relative inline-flex items-center justify-center rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:p-0",
        @open && "border-primary/50 bg-primary/10 text-primary"
      ]}
      title="Workspace admin"
      aria-label="Open workspace admin drawer"
      aria-expanded={@open}
    >
      <.icon name="hero-cog-6-tooth" class="size-4" />
    </button>
    """
  end

  attr :open, :boolean, required: true
  attr :is_admin, :boolean, required: true
  attr :show_all, :boolean, required: true
  attr :error, :string, default: nil
  attr :create_open, :boolean, required: true
  attr :create_fields, :list, required: true
  attr :create_form, :map, required: true
  attr :folder_form, :any, required: true
  attr :workspaces, :list, required: true
  attr :current_workspace_id, :string, required: true

  def admin_drawer(assigns) do
    ~H"""
    <div
      id="workspace-admin-drawer"
      data-admin-drawer-open={@open || nil}
      class={[
        "fixed inset-y-0 right-0 z-40 flex w-full max-w-md flex-col border-l border-base-300 bg-base-100 shadow-xl transition-transform duration-200",
        @open && "translate-x-0",
        !@open && "translate-x-full pointer-events-none"
      ]}
      role="dialog"
      aria-modal="true"
      aria-labelledby="workspace-admin-drawer-title"
      aria-hidden={!@open}
    >
      <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-300 px-4 py-3">
        <h2 id="workspace-admin-drawer-title" class="text-sm font-semibold">
          Workspace admin
        </h2>
        <button
          type="button"
          phx-click="workspace_admin:close"
          class="rounded border border-base-300 p-1 text-base-content/70 hover:bg-base-200"
          aria-label="Close workspace admin drawer"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
        <p
          :if={@error}
          id="workspace-admin-error"
          class="rounded border border-error/40 bg-error/10 px-3 py-2 text-xs text-error"
        >
          {@error}
        </p>

        <div :if={@is_admin} class="flex items-center justify-between gap-2">
          <span class="text-xs text-base-content/60">Visibility</span>
          <button
            type="button"
            id="workspace-admin-toggle-all"
            phx-click="workspace_admin:toggle_all"
            class="rounded border border-base-300 px-2 py-1 font-mono text-[11px] hover:bg-base-200"
            title="Admin: switch between all users' workspaces and your own"
          >
            {if @show_all, do: "showing: all users", else: "showing: mine"}
          </button>
        </div>

        <section class="space-y-2 rounded border border-base-300 bg-base-200/30 p-3">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Open folder
          </h3>
          <.form
            id="workspace-admin-attach-form"
            for={@folder_form}
            phx-submit="workspace_admin:attach_folder"
            class="flex flex-col gap-2"
          >
            <.input
              field={@folder_form[:path]}
              type="text"
              label="Folder path"
              placeholder="/data/workspaces/user/project"
              class="mt-1 block w-full rounded border border-base-300 bg-base-100 px-2 py-1 font-mono text-sm shadow-sm focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary"
              required
            />
            <button
              type="submit"
              class="rounded bg-base-content px-3 py-1.5 text-sm text-base-100 hover:opacity-90"
            >
              Open terminal here
            </button>
          </.form>
          <button
            type="button"
            id="workspace-admin-create-toggle"
            phx-click="workspace_admin:create_toggle"
            class="text-xs text-primary underline hover:no-underline"
          >
            {if @create_open, do: "Hide create form", else: "+ new workspace"}
          </button>
        </section>

        <section
          :if={@create_open}
          id="workspace-admin-create"
          class="space-y-2 rounded border border-base-300 bg-base-200/30 p-3"
        >
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Create workspace
          </h3>
          <form phx-submit="workspace_admin:create" class="flex flex-col gap-2">
            <%= if :name in @create_fields do %>
              <label class="text-xs">
                Name
                <input
                  name="name"
                  value={@create_form["name"]}
                  class="mt-0.5 block w-full rounded border border-base-300 bg-base-100 px-2 py-1 text-sm"
                  required
                />
              </label>
            <% end %>
            <%= if :user in @create_fields do %>
              <label class="text-xs">
                User
                <input
                  name="user"
                  value={@create_form["user"]}
                  class="mt-0.5 block w-full rounded border border-base-300 bg-base-100 px-2 py-1 text-sm"
                  required
                />
              </label>
            <% end %>
            <%= if :type in @create_fields do %>
              <label class="text-xs">
                Type
                <select
                  name="type"
                  class="mt-0.5 block w-full rounded border border-base-300 bg-base-100 px-2 py-1 text-sm"
                >
                  <option value="v3" selected>v3</option>
                  <option value="legacy">legacy</option>
                </select>
              </label>
            <% end %>
            <div class="flex items-center gap-2">
              <button
                type="submit"
                class="rounded bg-base-content px-3 py-1.5 text-sm text-base-100 hover:opacity-90"
              >
                Create
              </button>
              <button
                type="button"
                phx-click="workspace_admin:create_toggle"
                class="text-xs text-base-content/50 underline"
              >
                cancel
              </button>
            </div>
          </form>
        </section>

        <section class="space-y-2">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Start / stop
          </h3>
          <%= if @workspaces == [] do %>
            <p class="text-xs italic text-base-content/40">No workspaces loaded.</p>
          <% else %>
            <ul
              id="workspace-admin-list"
              class="divide-y divide-base-300/70 rounded border border-base-300"
            >
              <li
                :for={ws <- @workspaces}
                id={"workspace-admin-row-" <> ws.id}
                class={[
                  "flex items-center gap-2 px-3 py-2 text-xs",
                  ws.id == @current_workspace_id && "bg-primary/5"
                ]}
              >
                <span class="min-w-0 flex-1 truncate font-medium" title={ws.name}>{ws.name}</span>
                <span class="shrink-0 font-mono text-[10px] text-base-content/45">
                  {ws.status}
                </span>
                <%= if ws.status == :running do %>
                  <button
                    type="button"
                    phx-click="workspace_admin:stop"
                    phx-value-id={ws.id}
                    class="shrink-0 rounded border border-base-300 px-1.5 py-0.5 hover:bg-base-200"
                  >
                    stop
                  </button>
                <% else %>
                  <button
                    type="button"
                    phx-click="workspace_admin:start"
                    phx-value-id={ws.id}
                    class="shrink-0 rounded border border-base-300 px-1.5 py-0.5 hover:bg-base-200"
                  >
                    start
                  </button>
                <% end %>
              </li>
            </ul>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
