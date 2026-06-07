defmodule DevIDE.Terminals.SessionTemplate.Loader do
  @moduledoc """
  Loads built-in session templates.

  This module intentionally starts with hard-coded templates. File-backed or
  persisted templates can be added behind this API without changing callers.
  """

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Pane
  alias DevIDE.Terminals.SessionTemplate.Window

  @spec list :: [SessionTemplate.t()]
  def list do
    built_in()
    |> Map.values()
    |> Enum.sort_by(& &1.id)
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
      generic_project(),
      phoenix_dev(),
      agent_pair()
    ]
    |> Map.new(&{&1.id, &1})
  end

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
      description: "Operator shell with agent and verification panes.",
      windows: [
        %Window{
          id: "work",
          name: "work",
          cwd: ".",
          focus: true,
          panes: [
            %Pane{id: "agent", split_direction: "h", command: "claude", focus: true},
            %Pane{id: "verify", split_direction: "v", command: "git status --short"}
          ]
        }
      ]
    }
  end
end
