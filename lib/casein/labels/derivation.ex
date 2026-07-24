defmodule Casein.Labels.Derivation do
  @moduledoc """
  Derives short conversation-aware pane labels from MCP activity and agent input.
  """

  @max_label_length 48

  @spec from_mcp(String.t(), map(), :ok | {:error, term()}) :: String.t() | nil
  def from_mcp(tool, args, result) when is_binary(tool) and is_map(args) do
    if match?({:error, _}, result), do: nil, else: from_mcp_tool(tool, args)
  end

  @spec from_agent_label(String.t()) :: String.t() | nil
  def from_agent_label(label) when is_binary(label) do
    label |> normalize_label() |> truncate()
  end

  def from_agent_label(_), do: nil

  defp from_mcp_tool("terminal_send_command", args), do: from_command(arg(args, :command))
  defp from_mcp_tool("terminal_send_agent_command", args), do: from_command(arg(args, :command))
  defp from_mcp_tool("annotation_propose", args), do: from_annotation(arg(args, :content))
  defp from_mcp_tool("preview_open_localhost", args), do: from_preview_port_path(args)
  defp from_mcp_tool("preview_open_app", args), do: from_preview_surface(args)
  defp from_mcp_tool("preview_navigate", args), do: from_preview_navigate(args)
  defp from_mcp_tool(_tool, _args), do: nil

  defp from_command(nil), do: nil

  defp from_command(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> case do
      "" ->
        nil

      trimmed ->
        trimmed
        |> String.split(" ", parts: 4)
        |> case do
          ["mix", task | _] -> "mix " <> task
          ["git", sub | _] -> "git " <> sub
          ["npm", "run", script | _] -> "npm run " <> script
          ["bash", script | _] -> Path.basename(script)
          [bin | _] -> Path.basename(bin)
        end
        |> normalize_label()
        |> truncate()
    end
  end

  defp from_annotation(nil), do: nil

  defp from_annotation(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/u, " ")
    |> normalize_label()
    |> truncate()
  end

  defp from_preview_port_path(args) do
    port = arg(args, :port)
    path = arg(args, :path) || "/"

    case port do
      n when is_integer(n) -> truncate(":#{n}#{path}")
      n when is_binary(n) -> truncate(":#{n}#{path}")
      _ -> nil
    end
  end

  defp from_preview_surface(args) do
    case arg(args, :surface) do
      surface when is_binary(surface) and surface != "" -> truncate(surface <> " preview")
      _ -> "app preview" |> truncate()
    end
  end

  defp from_preview_navigate(args) do
    case arg(args, :path) do
      path when is_binary(path) and path != "" -> truncate("→ " <> path)
      _ -> nil
    end
  end

  defp arg(args, key) when is_atom(key) do
    Map.get(args, Atom.to_string(key)) || Map.get(args, key)
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.replace(~r/[\r\n]+/u, " ")
    |> then(fn
      "" -> nil
      value -> value
    end)
  end

  defp truncate(nil), do: nil

  defp truncate(label) when is_binary(label) do
    if String.length(label) > @max_label_length do
      String.slice(label, 0, @max_label_length - 1) <> "…"
    else
      label
    end
  end
end
