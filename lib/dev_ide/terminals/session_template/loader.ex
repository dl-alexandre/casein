defmodule DevIDE.Terminals.SessionTemplate.Loader do
  @moduledoc """
  Loads session templates from all sources.

  Built-in templates are hard-coded structs, always available regardless of
  workspace. Saved templates are persisted exports scoped to a workspace and
  returned alongside built-ins when a `workspace_id` is supplied.

  The `get/1` function resolves built-ins by their stable string ID. Saved
  templates are resolved by the caller through `DevIDE.Terminals.Templates`
  because saved templates need workspace scoping for apply/diff operations.
  """

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Pane
  alias DevIDE.Terminals.SessionTemplate.Window
  alias DevIDE.Terminals.Templates

  @spec list :: [SessionTemplate.t()]
  def list, do: list(nil)

  @spec list(String.t() | nil) :: [SessionTemplate.t()]
  def list(workspace_id) do
    saved = saved_stubs(workspace_id)

    built_in()
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Kernel.++(saved)
  end

  @spec get(String.t()) :: {:ok, SessionTemplate.t()} | {:error, :template_not_found}
  def get(id) when is_binary(id) do
    case Map.fetch(built_in(), id) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, :template_not_found}
    end
  end

  @spec built_in :: %{String.t() => SessionTemplate.t()}
  def built_in do
    [
      agent_pair(),
      agent_preview_demo(),
      generic_project(),
      phoenix_dev()
    ]
    |> Map.new(&{&1.id, &1})
  end

  # Returns saved templates as minimal SessionTemplate stubs for listing.
  # The stub carries the saved name, description and a placeholder window list.
  # Full body is available via Templates.get_by_id/1 when applying (M3.2).
  defp saved_stubs(nil), do: []

  defp saved_stubs(workspace_id) do
    workspace_id
    |> Templates.list_for_workspace()
    |> Enum.map(&saved_to_template/1)
  end

  defp saved_to_template(saved) do
    windows = saved_windows(saved.body)

    %SessionTemplate{
      id: saved.id,
      name: saved.name,
      description: saved.description || "Saved export",
      windows: windows
    }
  end

  # Build minimal Window stubs from a v2 body map so `template_payload/1` can
  # count windows and panes. The pane count comes from the layout tree.
  defp saved_windows(body) when is_map(body) do
    windows = Map.get(body, "windows", [])

    Enum.map(windows, fn w ->
      layout = Map.get(w, "layout", %{})
      pane_count = count_layout_panes(layout)

      extra_panes =
        if pane_count > 1,
          do: List.duplicate(%Pane{split_direction: "h"}, pane_count - 1),
          else: []

      %Window{
        id: Map.get(w, "name", "window"),
        name: Map.get(w, "name", "window"),
        focus: Map.get(w, "focus", false),
        panes: extra_panes
      }
    end)
  end

  defp saved_windows(_), do: [%Window{id: "window", name: "window", panes: []}]

  defp count_layout_panes(%{"panes" => panes}) when is_list(panes) do
    case panes do
      [] -> 1
      _ -> Enum.sum(Enum.map(panes, &count_layout_panes/1))
    end
  end

  defp count_layout_panes(_), do: 1

  defp generic_project do
    %SessionTemplate{
      id: "generic_project",
      name: "Generic Project",
      description: "Shell, git status, and a scratch pane.",
      windows: [
        %Window{
          id: "shell",
          name: "shell",
          cwd: ".",
          focus: true,
          panes: [
            %Pane{id: "git", split_direction: "v", command: "git status --short"},
            %Pane{id: "scratch", split_direction: "h"}
          ]
        }
      ]
    }
  end

  defp phoenix_dev do
    %SessionTemplate{
      id: "phoenix_dev",
      name: "Phoenix Dev",
      description: "Server, console, tests, and logs.",
      windows: [
        %Window{
          id: "server",
          name: "server",
          cwd: ".",
          command: "mix phx.server",
          focus: true,
          panes: [
            %Pane{id: "console", split_direction: "v", command: "iex -S mix"}
          ]
        },
        %Window{
          id: "tests",
          name: "tests",
          cwd: ".",
          command: "mix test --stale",
          panes: [
            %Pane{id: "logs", split_direction: "h", command: "tail -n 200 -f log/dev.log"}
          ]
        }
      ]
    }
  end

  defp agent_pair do
    %SessionTemplate{
      id: "agent_pair",
      name: "Agent Pair",
      description: "Operator shell (focused), dedicated agent pane for MCP, and a verify pane.",
      windows: [
        %Window{
          id: "work",
          name: "work",
          cwd: ".",
          focus: true,
          panes: [
            %Pane{
              id: "agent",
              split_direction: "h",
              command:
                "printf '# DevIDE agent pane\\n# MCP: terminal_topology then target this pane\\n'"
            },
            %Pane{id: "verify", split_direction: "v", command: "git status --short"}
          ]
        }
      ]
    }
  end

  defp agent_preview_demo do
    %SessionTemplate{
      id: "agent_preview_demo",
      name: "Agent Preview Demo",
      description:
        "Agent pair layout plus a localhost HTML demo (port 5173) for Preview MCP smoke tests.",
      windows: [
        %Window{
          id: "work",
          name: "work",
          cwd: ".",
          focus: true,
          panes: [
            %Pane{
              id: "agent",
              split_direction: "h",
              command: "bash scripts/run-preview-demo.sh"
            },
            %Pane{
              id: "verify",
              split_direction: "v",
              command:
                "printf '# Preview MCP demo\\n# preview_open_localhost port 5173\\n# preview_click #demo-button\\n'"
            }
          ]
        }
      ]
    }
  end
end
