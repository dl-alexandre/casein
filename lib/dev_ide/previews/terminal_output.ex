defmodule DevIDE.Previews.TerminalOutput do
  @moduledoc false

  alias DevIDE.Previews.Deps

  @session_prefix "devide_"
  @max_lines 300
  @max_panes 12

  @doc """
  Concatenates recent pane scrollback from workspace-scoped tmux sessions.

  Used to discover localhost dev-server URLs printed in terminal output.
  """
  @spec gather(map()) :: String.t()
  def gather(workspace) when is_map(workspace) do
    prefixes = session_prefixes(workspace)

    if prefixes == [] do
      ""
    else
      terminals().list_sessions()
      |> Enum.filter(&workspace_session?(&1.session, prefixes))
      |> Enum.flat_map(&capture_session/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  @doc "Extract unique localhost ports from terminal text."
  @spec ports_from_text(String.t()) :: [integer()]
  def ports_from_text(text) when is_binary(text) do
    text
    |> DevIDE.Previews.Detector.discover()
    |> Enum.map(& &1.port)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def ports_from_text(_), do: []

  defp workspace_session?(name, prefixes) when is_binary(name) do
    String.starts_with?(name, @session_prefix) and
      Enum.any?(prefixes, &String.starts_with?(name, &1))
  end

  defp capture_session(%{session: session}) do
    session
    |> terminals().list_session_panes()
    |> Enum.take(@max_panes)
    |> Enum.map(fn pane ->
      terminals().capture_scrollback(session,
        target: pane.id,
        ansi: false,
        lines: @max_lines
      )
    end)
  end

  defp session_prefixes(workspace) do
    id = workspace_id(workspace)
    name = workspace_name(workspace)

    prefixes =
      for candidate <- [id, name], is_binary(candidate), candidate != "" do
        terminals().workspace_session_prefix(candidate)
      end

    case id do
      id when is_binary(id) ->
        case workspaces().get(id) do
          {:ok, ws} ->
            for candidate <- [ws.id, ws.name], is_binary(candidate), candidate != "" do
              terminals().workspace_session_prefix(candidate)
            end
            |> Kernel.++(prefixes)

          _ ->
            prefixes
        end

      _ ->
        prefixes
    end
    |> Enum.uniq()
  end

  defp workspace_id(%{id: id}) when is_binary(id), do: id
  defp workspace_id(%{"id" => id}) when is_binary(id), do: id
  defp workspace_id(_), do: nil

  defp workspace_name(%{name: name}) when is_binary(name), do: name
  defp workspace_name(%{"name" => name}) when is_binary(name), do: name
  defp workspace_name(_), do: nil

  defp workspaces, do: Deps.impl(:workspaces)
  defp terminals, do: Deps.impl(:terminals)
end
