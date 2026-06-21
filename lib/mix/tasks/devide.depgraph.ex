defmodule Mix.Tasks.Devide.Depgraph do
  @moduledoc """
  Render a scoped module-dependency subgraph as terminal box-art.

  Reads an `mix xref graph --format dot` dump, keeps only the depth-1
  neighbourhood around a target path (every file under the path, plus the
  files directly linked to them), builds a `Graph.t()`, and prints it with
  Boxart so it is legible inside a terminal pane.

      mix devide.depgraph lib/dev_ide/previews
      mix devide.depgraph lib/dev_ide/previews --dir lr --dot xref_graph.dot

  Options:

    * `--dot PATH`  dot file to read (default `xref_graph.dot`; regenerate with
      `mix xref graph --format dot`)
    * `--dir td|lr` layout direction (default `td`)

  This is a dev-only investigation tool — it intentionally fails loudly when the
  scoped graph is too wide to be readable, which is the signal that box-art is
  the wrong surface for that slice.
  """
  @shortdoc "Render a scoped dependency subgraph as terminal box-art"

  use Mix.Task

  @switches [dot: :string, dir: :string, internal: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _} = OptionParser.parse(argv, switches: @switches)

    path =
      List.first(rest) ||
        Mix.raise("usage: mix devide.depgraph <path> [--dot FILE] [--dir td|lr]")

    dot = Keyword.get(opts, :dot, "xref_graph.dot")

    dir =
      case Keyword.get(opts, :dir, "td") do
        "td" -> :td
        "lr" -> :lr
        other -> Mix.raise("--dir must be td or lr, got: #{other}")
      end

    unless File.exists?(dot) do
      Mix.raise("dot file #{dot} not found — generate it with: mix xref graph --format dot")
    end

    edges = parse_dot(File.read!(dot))
    scoped = scope(edges, path, Keyword.get(opts, :internal, false))

    if scoped == [] do
      Mix.raise("no edges touch #{path} in #{dot} — check the path or regenerate the dot file")
    end

    graph = build_graph(scoped, path)
    render = Boxart.render(graph, direction: dir)

    width = render |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)

    Mix.shell().info(render)

    Mix.shell().info([
      "\n",
      "scope: #{path}  ·  nodes: #{Graph.num_vertices(graph)}  ·  edges: #{Graph.num_edges(graph)}  ·  width: #{width} cols"
    ])

    if width > 200 do
      Mix.shell().info(
        "\n⚠ #{width} cols is too wide for a pane — box-art is the wrong surface for this slice; scope tighter or keep the .dot."
      )
    end
  end

  # Parse `"a.ex" -> "b.ex" [label="(export)"]` lines into {from, to, label}.
  defp parse_dot(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*"([^"]+)"\s*->\s*"([^"]+)"(?:\s*\[label="([^"]*)"\])?/, line) do
        [_, from, to] -> [{from, to, nil}]
        [_, from, to, label] -> [{from, to, label}]
        _ -> []
      end
    end)
  end

  # `internal?` true  -> keep only edges fully inside `path` (the context's own
  #                      structure; no boundary fan-out).
  # `internal?` false -> depth-1 neighbourhood: at least one endpoint under `path`.
  defp scope(edges, path, internal?) do
    Enum.filter(edges, fn {from, to, _} ->
      a = String.starts_with?(from, path)
      b = String.starts_with?(to, path)
      if internal?, do: a and b, else: a or b
    end)
  end

  defp build_graph(edges, path) do
    Enum.reduce(edges, Graph.new(), fn {from, to, label}, g ->
      g
      |> add_node(from, path)
      |> add_node(to, path)
      |> Graph.add_edge(from, to, label: edge_label(label))
    end)
  end

  defp add_node(graph, file, path) do
    # In-context nodes show just the basename; boundary nodes show context/basename
    # so it is obvious which crossings leave the scope.
    label =
      if String.starts_with?(file, path) do
        Path.basename(file)
      else
        file |> Path.split() |> Enum.take(-2) |> Path.join()
      end

    Graph.add_vertex(graph, file, label: label)
  end

  defp edge_label(nil), do: ""
  defp edge_label(label), do: String.trim(label, "()")
end
