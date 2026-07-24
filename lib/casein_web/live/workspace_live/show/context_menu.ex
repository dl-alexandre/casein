defmodule CaseinWeb.WorkspaceLive.Show.ContextMenu do
  @moduledoc """
  Shared right-click context menu for the workspace cockpit.

  One menu instance is rendered by `Show` (see `render_context_menu/1`); the
  `ContextMenu` JS hook opens it by pushing `ctx:open` with a menu id and a
  small ctx payload harvested from the trigger's `data-ctx-*` attributes.
  Item lists are built server-side in `items/3` so policy gating
  (`Policy.can_edit_file?`, tmux mutation locks) stays on the server — a
  client can fabricate `ctx:open` payloads but never sees items it is not
  allowed to use, and every mutating item dispatches to an existing gated
  `handle_event` that re-validates.

  Item shapes:

    * `%{id:, label:, event:, params:}` — pushes `event` then `ctx:close`;
      add `confirm: "…"` for a browser confirm before the push
    * `%{id:, label:, copy: text}` — client-side clipboard copy (CopyText hook)
    * `%{id:, label:, href: path}` — open a same-origin path in a new tab
    * `%{id:, label:, action: name, target: selector}` — dispatch a
      `casein:ctx-action` CustomEvent to `target` (client-side actions owned
      by another hook, e.g. terminal copy/paste)
    * `%{divider: true}` — separator
    * plus optional `danger: true` / `disabled: true` on any button shape

  Ctx payload keys arrive camelCased by the hook's dataset harvest
  (`data-ctx-session-id` → `"sessionId"`).
  """

  use CaseinWeb, :html

  alias Casein.Policy
  alias Casein.Policy.Decision
  alias Phoenix.LiveView.JS

  @max_ctx_value_bytes 4096

  @doc """
  Build the item list for `menu` given the client-supplied `ctx` and the
  LiveView assigns. Returns `[]` for unknown menus or oversized/invalid ctx
  payloads, which `ContextMenuEvents` treats as "don't open".
  """
  def items(menu, ctx, assigns)

  def items("tree_node", %{"path" => path, "kind" => kind} = _ctx, assigns)
      when is_binary(path) and byte_size(path) <= @max_ctx_value_bytes and
             kind in ["file", "dir"] do
    node_items(kind, path, can_edit?(assigns), tmux_session_live?(assigns))
  end

  def items("tree_root", _ctx, assigns) do
    dir = assigns.selected_dir || ""

    if can_edit?(assigns) do
      [
        %{
          id: "new-file",
          label: "New file…",
          event: "tree:new_form_at",
          params: %{"dir" => dir, "kind" => "file"}
        },
        %{
          id: "new-dir",
          label: "New folder…",
          event: "tree:new_form_at",
          params: %{"dir" => dir, "kind" => "dir"}
        },
        %{divider: true},
        %{id: "refresh", label: "Refresh", event: "tree:refresh", params: %{}}
      ]
    else
      [%{id: "refresh", label: "Refresh", event: "tree:refresh", params: %{}}]
    end
  end

  def items("session_tab", %{"sessionId" => sid} = ctx, assigns) when is_binary(sid) do
    tmux = ctx["tmuxSession"]

    attach_params =
      %{"session-id" => sid, "kind" => ctx["kind"] || "tmux"}
      |> maybe_put("tmux-session", tmux)

    attach = [
      %{id: "attach", label: "Attach", event: "attach_terminal_session", params: attach_params}
    ]

    # Rename is deliberately absent: the strip has no inline rename form
    # (that affordance lives in the session dropdown).
    mutations =
      if tmux_mutations?(assigns) and is_binary(tmux) and tmux != "" do
        [
          %{divider: true},
          %{
            id: "kill",
            label: "Kill session…",
            event: "terminal:kill_session",
            params: %{"session-id" => sid, "tmux-session" => tmux},
            confirm: "Kill this tmux session and everything running in it?",
            danger: true
          }
        ]
      else
        []
      end

    attach ++ open_in_new_tab_item(ctx["href"]) ++ mutations
  end

  def items("window_tab", %{"windowId" => window_id} = ctx, assigns)
      when is_binary(window_id) do
    select = [
      %{
        id: "select",
        label: "Select window",
        event: "tmux:select_window",
        params: %{"window-id" => window_id}
      }
    ]

    mutations =
      if tmux_mutations?(assigns) do
        windows =
          assigns[:tmux_windows]
          |> List.wrap()
          |> Enum.sort_by(&Map.get(&1, :index, 0))

        idx = Enum.find_index(windows, &(&1.id == window_id))
        at_left_edge = idx == 0
        at_right_edge = idx == length(windows) - 1

        [
          %{divider: true},
          %{
            id: "rename",
            label: "Rename…",
            event: "tmux:rename_start",
            params: %{"window-id" => window_id}
          },
          %{
            id: "move-left",
            label: "Move left",
            event: "tmux:move_window",
            params: %{"window-id" => window_id, "dir" => "left"},
            disabled: at_left_edge
          },
          %{
            id: "move-right",
            label: "Move right",
            event: "tmux:move_window",
            params: %{"window-id" => window_id, "dir" => "right"},
            disabled: at_right_edge
          },
          %{id: "new-window", label: "New window", event: "tmux:new_window", params: %{}},
          %{divider: true},
          %{
            id: "kill",
            label: "Close window…",
            event: "tmux:kill_window",
            params: %{"window-id" => window_id},
            confirm: "Kill this tmux window and everything running in it?",
            danger: true
          }
        ]
      else
        []
      end

    select ++ open_in_new_tab_item(ctx["href"]) ++ mutations
  end

  def items("terminal", %{"targetId" => target_id} = ctx, assigns) do
    with true <- valid_dom_id?(target_id) do
      # Attribute selector, not "#id" — tmux-derived ids contain "%"
      # ("ghostty-%12"), which is invalid in an id selector.
      target = "[id='" <> target_id <> "']"
      has_selection = ctx["hasSelection"] == "true"
      pane_id = ctx["paneId"]

      client = [
        %{
          id: "copy",
          label: "Copy",
          action: "copy",
          target: target,
          disabled: not has_selection
        },
        %{id: "paste", label: "Paste", action: "paste", target: target},
        %{id: "select-all", label: "Select all", action: "select_all", target: target},
        %{id: "clear", label: "Clear", action: "clear", target: target}
      ]

      pane_ops =
        if is_binary(pane_id) and pane_id != "" do
          history = [
            %{divider: true},
            %{
              id: "history",
              label: "Pane history",
              event: "pane:history_open",
              params: %{"pane-id" => pane_id}
            }
          ]

          mutations =
            if tmux_mutations?(assigns) do
              [
                %{
                  id: "split-right",
                  label: "Split right",
                  event: "tmux:split_pane",
                  params: %{"pane-id" => pane_id, "direction" => "h"}
                },
                %{
                  id: "split-down",
                  label: "Split down",
                  event: "tmux:split_pane",
                  params: %{"pane-id" => pane_id, "direction" => "v"}
                },
                %{id: "zoom", label: "Zoom pane", event: "pane:zoom_focused", params: %{}},
                %{divider: true},
                %{
                  id: "kill-pane",
                  label: "Close pane…",
                  event: "tmux:kill_pane",
                  params: %{"pane-id" => pane_id},
                  confirm: "Close this tmux pane and everything running in it?",
                  danger: true
                }
              ]
            else
              []
            end

          history ++ mutations
        else
          []
        end

      client ++ pane_ops
    else
      _ -> []
    end
  end

  def items("editor", %{"targetId" => target_id} = ctx, assigns) do
    with true <- valid_dom_id?(target_id),
         true <- ctx["hasFile"] == "true" do
      target = "[id='" <> target_id <> "']"
      has_selection = ctx["hasSelection"] == "true"
      can_edit? = can_edit?(assigns)

      clipboard = [
        %{
          id: "cut",
          label: "Cut",
          action: "cut",
          target: target,
          disabled: not (has_selection and can_edit?)
        },
        %{id: "copy", label: "Copy", action: "copy", target: target, disabled: not has_selection},
        %{id: "paste", label: "Paste", action: "paste", target: target, disabled: not can_edit?},
        %{id: "select-all", label: "Select all", action: "select_all", target: target}
      ]

      file_ops =
        if can_edit? do
          [
            %{divider: true},
            %{id: "save", label: "Save", action: "save", target: target},
            %{id: "rename", label: "Rename file…", event: "file:rename_form", params: %{}},
            %{
              id: "delete",
              label: "Delete file…",
              event: "file:delete_request",
              params: %{},
              danger: true
            }
          ]
        else
          []
        end

      agent =
        if tmux_mutations?(assigns) do
          [
            %{divider: true},
            %{
              id: "send-agent",
              label: "Send selection to agent",
              action: "send_to_agent",
              target: target,
              disabled: not has_selection
            },
            %{
              id: "explain",
              label: "Ask agent to explain",
              action: "explain",
              target: target,
              disabled: not has_selection
            }
          ]
        else
          []
        end

      clipboard ++ file_ops ++ agent
    else
      _ -> []
    end
  end

  # File-pane editor body. Like "editor" but scoped to a file pane: the clipboard
  # + save actions run against the pane's own CodeMirror view, "Copy path" copies
  # the active tab's path, and rename/delete are intentionally absent (those live
  # on the file tree). All client actions dispatch to the pane overlay's root.
  def items("file_pane_editor", %{"targetId" => target_id} = ctx, assigns) do
    with true <- valid_dom_id?(target_id),
         true <- ctx["hasFile"] == "true" do
      target = "[id='" <> target_id <> "']"
      path = ctx["path"]
      has_selection = ctx["hasSelection"] == "true"
      can_edit? = can_edit?(assigns)

      clipboard = [
        %{
          id: "cut",
          label: "Cut",
          action: "cut",
          target: target,
          disabled: not (has_selection and can_edit?)
        },
        %{id: "copy", label: "Copy", action: "copy", target: target, disabled: not has_selection},
        %{id: "paste", label: "Paste", action: "paste", target: target, disabled: not can_edit?},
        %{id: "select-all", label: "Select all", action: "select_all", target: target}
      ]

      save =
        if can_edit?, do: [%{id: "save", label: "Save", action: "save", target: target}], else: []

      path_items =
        if is_binary(path) and path != "" and byte_size(path) <= @max_ctx_value_bytes do
          [%{id: "copy-path", label: "Copy path", copy: path}]
        else
          []
        end

      agent =
        if tmux_mutations?(assigns) and has_selection do
          [
            %{divider: true},
            %{
              id: "send-agent",
              label: "Send selection to agent",
              action: "send_to_agent",
              target: target
            },
            %{id: "explain", label: "Ask agent to explain", action: "explain", target: target}
          ]
        else
          []
        end

      clipboard ++ [%{divider: true}] ++ save ++ path_items ++ agent
    else
      _ -> []
    end
  end

  # A file-pane tab. Close / Close others route back to the overlay (which owns
  # the dirty-buffer confirm) via client actions carrying the tab path; "Copy
  # path" is a direct clipboard copy.
  def items("file_pane_tab", %{"path" => path, "targetId" => target_id} = _ctx, _assigns)
      when is_binary(path) and path != "" and byte_size(path) <= @max_ctx_value_bytes do
    if valid_dom_id?(target_id) do
      target = "[id='" <> target_id <> "']"

      [
        %{
          id: "close",
          label: "Close",
          action: "close_tab",
          target: target,
          detail: %{path: path}
        },
        %{
          id: "close-others",
          label: "Close others",
          action: "close_others",
          target: target,
          detail: %{path: path}
        },
        %{divider: true},
        %{id: "copy-path", label: "Copy path", copy: path}
      ]
    else
      []
    end
  end

  # A preview pane. All items are server-driven (no client hook needed): reload/
  # reopen/close push existing gated preview events; "Copy URL" and "Open in new
  # tab" carry the pane's display URL (scheme-validated for the anchor).
  def items("preview_pane", %{"paneId" => pane_id} = ctx, _assigns)
      when is_binary(pane_id) and pane_id != "" and byte_size(pane_id) <= @max_ctx_value_bytes do
    url = ctx["url"]

    controls = [
      %{
        id: "reload",
        label: "Reload",
        event: "preview-pane:refresh",
        params: %{"pane-id" => pane_id}
      },
      %{
        id: "reopen",
        label: "Reopen",
        event: "preview-pane:recover",
        params: %{"pane-id" => pane_id}
      }
    ]

    url_items =
      if is_binary(url) and byte_size(url) <= @max_ctx_value_bytes and url != "" do
        [%{divider: true}, %{id: "copy-url", label: "Copy URL", copy: url}] ++
          preview_open_in_tab_item(url)
      else
        []
      end

    close = [
      %{divider: true},
      %{
        id: "close",
        label: "Close preview",
        event: "preview-pane:close",
        params: %{"pane-id" => pane_id}
      }
    ]

    controls ++ viewport_items(pane_id, ctx["viewport"]) ++ url_items ++ close
  end

  def items("run_entry", %{"runId" => run_id} = ctx, _assigns) when is_binary(run_id) do
    command_id = ctx["commandId"]

    base = [
      %{
        id: "select",
        label: "Open run details",
        event: "run_ledger:select",
        params: %{"id" => run_id}
      },
      %{id: "copy-run-id", label: "Copy run id", copy: run_id}
    ]

    # run:start re-validates against the command allowlist and policy server-side.
    rerun =
      if is_binary(command_id) and command_id != "" do
        [
          %{divider: true},
          %{
            id: "rerun",
            label: "Rerun command",
            event: "run:start",
            params: %{"id" => command_id}
          },
          %{id: "copy-command-id", label: "Copy command id", copy: command_id}
        ]
      else
        []
      end

    base ++ rerun
  end

  def items(_menu, _ctx, _assigns), do: []

  defp node_items("dir", path, can_edit?, _tmux_live?) do
    open = [
      %{id: "toggle", label: "Expand / collapse", event: "tree:toggle", params: %{"path" => path}}
    ]

    mutations =
      if can_edit? do
        [
          %{divider: true},
          %{
            id: "new-file",
            label: "New file here…",
            event: "tree:new_form_at",
            params: %{"dir" => path, "kind" => "file"}
          },
          %{
            id: "new-dir",
            label: "New folder here…",
            event: "tree:new_form_at",
            params: %{"dir" => path, "kind" => "dir"}
          },
          %{divider: true},
          %{
            id: "rename",
            label: "Rename…",
            event: "tree:rename_form_node",
            params: %{"path" => path}
          },
          %{
            id: "duplicate",
            label: "Duplicate",
            event: "tree:duplicate",
            params: %{"path" => path}
          },
          %{divider: true},
          %{
            id: "delete",
            label: "Delete…",
            event: "tree:delete_node_request",
            params: %{"path" => path},
            danger: true
          }
        ]
      else
        []
      end

    open ++ [copy_path_item(path)] ++ mutations
  end

  defp node_items("file", path, can_edit?, tmux_live?) do
    open =
      [%{id: "open", label: "Open", event: "tree:open", params: %{"path" => path}}] ++
        if tmux_live? do
          # Splits/reuses a CodeMirror file pane beside the active terminal
          # pane (tree:open_in_pane falls back to tree:open server-side when
          # the tmux session turns out to be gone).
          [
            %{
              id: "open-in-pane",
              label: "Open in pane",
              event: "tree:open_in_pane",
              params: %{"path" => path}
            }
          ]
        else
          []
        end

    mutations =
      if can_edit? do
        [
          %{divider: true},
          %{
            id: "rename",
            label: "Rename…",
            event: "tree:rename_form_node",
            params: %{"path" => path}
          },
          %{
            id: "duplicate",
            label: "Duplicate",
            event: "tree:duplicate",
            params: %{"path" => path}
          },
          %{divider: true},
          %{
            id: "delete",
            label: "Delete…",
            event: "tree:delete_node_request",
            params: %{"path" => path},
            danger: true
          }
        ]
      else
        []
      end

    open ++ [copy_path_item(path)] ++ mutations
  end

  defp copy_path_item(path), do: %{id: "copy-path", label: "Copy path", copy: path}

  # Only relative same-origin paths — the href rides in from a client dataset,
  # so absolute/scheme URLs (javascript:, https://elsewhere) are refused.
  defp open_in_new_tab_item(href) do
    if is_binary(href) and String.starts_with?(href, "/") and
         not String.starts_with?(href, "//") do
      [%{id: "open-tab", label: "Open in new tab", href: href}]
    else
      []
    end
  end

  # Preview URLs are absolute (the workspace's https origin), unlike the
  # relative session/window hrefs, so this accepts http(s) only — the scheme
  # check is what keeps a crafted ctx from smuggling a javascript:/data: URL
  # into the anchor's href.
  # Device presets for a preview pane's locked viewport. The overlay sizes the
  # iframe to these exact CSS pixels and scales it to fit the pane, so the
  # embedded app lays out at a real device width instead of the pane's.
  #
  # "" clears the lock. The entry matching the pane's current viewport is
  # disabled rather than check-marked — the menu renderer has no checked state,
  # and a dimmed row reads as "already applied" without inventing one.
  @preview_viewports [
    {"phone", "Phone · 390×844", "390x844"},
    {"tablet", "Tablet · 820×1180", "820x1180"},
    {"desktop", "Desktop · 1280×900", "1280x900"},
    {"fit", "Fit pane", ""}
  ]

  defp viewport_items(pane_id, current) do
    current = if is_binary(current), do: current, else: ""

    [%{divider: true}] ++
      Enum.map(@preview_viewports, fn {id, label, viewport} ->
        %{
          id: "viewport-" <> id,
          label: label,
          event: "pane:input",
          params: %{
            "pane-id" => pane_id,
            "type" => "set_viewport",
            "viewport" => viewport
          },
          disabled: String.downcase(current) == viewport
        }
      end)
  end

  defp preview_open_in_tab_item(url) do
    if is_binary(url) and String.match?(url, ~r{^https?://}) do
      [%{id: "open-tab", label: "Open in new tab", href: url}]
    else
      []
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Client-action targets become CSS attribute selectors ([id='…']); accept
  # only plain DOM ids so a crafted ctx can't smuggle in a broader selector
  # (no quotes, backslashes, or brackets).
  defp valid_dom_id?(id),
    do: is_binary(id) and Regex.match?(~r/^[A-Za-z][A-Za-z0-9_%:.-]*$/, id)

  defp tmux_mutations?(assigns), do: assigns[:tmux_mutations_enabled?] == true

  # "Open in pane" needs a live tmux session to split against — a session name
  # always exists on the socket, so require actual topology (windows) too.
  defp tmux_session_live?(assigns) do
    is_binary(assigns[:tmux_session]) and assigns[:tmux_session] != "" and
      (assigns[:tmux_windows] || []) != []
  end

  # Menu visibility mirrors the write gate the mutating handlers enforce via
  # gate/3; no audit event is emitted here — that happens when an item fires.
  defp can_edit?(assigns) do
    %{assigns: assigns}
    |> CaseinWeb.WorkspaceLive.Show.Context.policy_ctx()
    |> Policy.can_edit_file?()
    |> Decision.allow?()
  end

  @doc """
  The single context-menu overlay. Expects `@context_menu` to be `nil` or
  `%{menu:, ctx:, x:, y:, items:}` (set by `ContextMenuEvents`).
  """
  def render_context_menu(assigns) do
    ~H"""
    <div id="ctx-menu-anchor" phx-hook="ContextMenu" class="hidden" aria-hidden="true"></div>
    <%= if @context_menu do %>
      <div
        id="ctx-menu"
        role="menu"
        aria-label="Context menu"
        phx-click-away="ctx:close"
        phx-mounted={JS.dispatch("casein:ctx-menu-mounted")}
        style={"left: #{@context_menu.x}px; top: #{@context_menu.y}px;"}
        class="fixed z-[70] min-w-44 max-w-72 overflow-hidden rounded border border-base-300 bg-base-100 py-1 text-sm text-base-content shadow-2xl"
      >
        <%= for item <- @context_menu.items do %>
          <%= cond do %>
            <% item[:divider] -> %>
              <div role="separator" class="my-1 border-t border-base-300"></div>
            <% item[:copy] -> %>
              <button
                type="button"
                role="menuitem"
                id={"ctx-item-" <> item.id}
                phx-hook="CopyText"
                data-copy-text={item.copy}
                phx-click="ctx:close"
                class={item_class(item)}
              >
                {item.label}
              </button>
            <% item[:href] -> %>
              <a
                role="menuitem"
                id={"ctx-item-" <> item.id}
                href={item.href}
                target="_blank"
                rel="noreferrer"
                phx-click="ctx:close"
                class={item_class(item)}
              >
                {item.label}
              </a>
            <% item[:action] -> %>
              <button
                type="button"
                role="menuitem"
                id={"ctx-item-" <> item.id}
                disabled={item[:disabled]}
                phx-click={
                  JS.dispatch("casein:ctx-action",
                    to: item.target,
                    detail: Map.merge(%{action: item.action}, item[:detail] || %{})
                  )
                  |> JS.push("ctx:close")
                }
                class={item_class(item)}
              >
                {item.label}
              </button>
            <% true -> %>
              <button
                type="button"
                role="menuitem"
                id={"ctx-item-" <> item.id}
                disabled={item[:disabled]}
                data-confirm={item[:confirm]}
                phx-click={JS.push(item.event, value: item.params) |> JS.push("ctx:close")}
                class={item_class(item)}
              >
                {item.label}
              </button>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp item_class(item) do
    [
      "block w-full px-3 py-1.5 text-left focus:outline-none",
      if(item[:disabled],
        do: "cursor-default text-base-content/35",
        else: "hover:bg-base-200 focus:bg-base-200"
      ),
      item[:danger] && "text-error"
    ]
  end
end
