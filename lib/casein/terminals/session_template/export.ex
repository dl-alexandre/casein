defmodule Casein.Terminals.SessionTemplate.Export do
  @moduledoc """
  Exports live tmux topology into Casein session template v2 maps.

  The exporter is intentionally conservative. It only infers nested
  horizontal/vertical splits when pane rectangles form a clean partition; for
  custom layouts it falls back to a tiled node so no geometry is silently
  misrepresented.
  """

  @type topology :: map()
  @type template :: map()

  @spec from_topology(topology(), keyword()) :: {:ok, template()} | {:error, atom()}
  def from_topology(%{} = topology, opts \\ []) do
    windows = Map.get(topology, :windows, Map.get(topology, "windows", []))

    if windows == [] do
      {:error, :empty_topology}
    else
      workspace_root = Keyword.get(opts, :workspace_root)
      session = Map.get(topology, :session, Map.get(topology, "session"))
      name = Keyword.get(opts, :name) || default_name(session)

      template =
        %{
          "version" => 2,
          "name" => name,
          "root" => root_expr(workspace_root),
          "metadata" =>
            compact(%{
              "source" => "casein_topology_export",
              "session" => session,
              "topology_version" => Map.get(topology, :version, Map.get(topology, "version"))
            }),
          "windows" => export_windows(windows, workspace_root),
          "startup" => startup(topology, windows)
        }
        |> compact()
        |> tag_feature_panes(feature_pane_lookup(opts))

      {:ok, template}
    end
  end

  # Live tmux topology can't tell a feature-overlaid pane (preview, file) from a
  # plain terminal — the overlay is a Casein concept, not a tmux one. A caller that
  # holds the pane registries passes a lookup so matching leaves are retagged with
  # the feature type + payload and round-trip back to a live feature pane on apply.
  #
  # Accepts two opts, merged into one `%{pane_id => {type, command}}` lookup:
  #
  #   * `:preview_panes` — legacy `%{pane_id => url}` (each becomes `{"preview", url}`).
  #   * `:feature_panes` — `%{pane_id => {type, command}}`, e.g. built from
  #     `Casein.Panes.snapshot/1` (`{"file", active_path}` / `{"preview", url}`).
  defp feature_pane_lookup(opts) do
    preview =
      opts
      |> Keyword.get(:preview_panes, %{})
      |> Map.new(fn {pane_id, url} -> {pane_id, {"preview", url}} end)

    feature = Keyword.get(opts, :feature_panes, %{})

    Map.merge(preview, feature)
  end

  defp tag_feature_panes(template, lookup) when map_size(lookup) == 0, do: template

  defp tag_feature_panes(%{"windows" => windows} = template, lookup) do
    %{template | "windows" => Enum.map(windows, &tag_feature_window(&1, lookup))}
  end

  defp tag_feature_panes(template, _lookup), do: template

  defp tag_feature_window(%{"layout" => layout} = window, lookup) do
    %{window | "layout" => tag_feature_node(layout, lookup)}
  end

  defp tag_feature_window(window, _lookup), do: window

  defp tag_feature_node(%{"panes" => panes} = node, lookup) when is_list(panes) do
    %{node | "panes" => Enum.map(panes, &tag_feature_node(&1, lookup))}
  end

  defp tag_feature_node(leaf, lookup) when is_map(leaf) do
    case lookup[get_in(leaf, ["metadata", "source_pane_id"])] do
      {type, command} when is_binary(type) and is_binary(command) and command != "" ->
        leaf |> Map.put("type", type) |> Map.put("command", command)

      _ ->
        leaf
    end
  end

  defp tag_feature_node(node, _lookup), do: node

  @spec to_yaml(template()) :: String.t()
  def to_yaml(%{} = template) do
    template
    |> encode_yaml(0)
    |> Kernel.<>("\n")
  end

  defp export_windows(windows, workspace_root) do
    windows
    |> Enum.sort_by(&field(&1, :index, 0))
    |> Enum.map(&export_window(&1, workspace_root))
  end

  defp export_window(window, workspace_root) do
    panes =
      window
      |> field(:pane_list, [])
      |> Enum.sort_by(&field(&1, :index, 0))

    pane_names = pane_names(panes)
    window_root = window_root(panes)

    %{
      "name" => field(window, :name) || "window-#{field(window, :index, 0)}",
      "root" => path_expr(window_root, workspace_root),
      "focus" => field(window, :active, false),
      "layout" => export_layout(panes, pane_names, workspace_root, window_root)
    }
    |> compact()
  end

  defp export_layout([], _pane_names, _workspace_root, _window_root) do
    %{"direction" => "tiled", "panes" => []}
  end

  defp export_layout([pane], pane_names, workspace_root, window_root) do
    export_pane(pane, pane_names, workspace_root, window_root)
  end

  defp export_layout(panes, pane_names, workspace_root, window_root) do
    panes =
      Enum.sort_by(panes, fn pane ->
        {field(pane, :top, 0), field(pane, :left, 0), field(pane, :index, 0)}
      end)

    case split_partition(panes) do
      {:ok, direction, first, second} ->
        %{
          "direction" => direction,
          "panes" => [
            child_layout(first, pane_names, workspace_root, window_root, direction),
            child_layout(second, pane_names, workspace_root, window_root, direction)
          ]
        }
        |> compact()

      :error ->
        %{
          "direction" => "tiled",
          "panes" => Enum.map(panes, &export_pane(&1, pane_names, workspace_root, window_root))
        }
    end
  end

  defp child_layout(panes, pane_names, workspace_root, window_root, parent_direction) do
    panes
    |> export_layout(pane_names, workspace_root, window_root)
    |> Map.put("size", partition_size(panes, parent_direction))
    |> compact()
  end

  defp split_partition(panes) do
    split_on_x(panes) || split_on_y(panes) || :error
  end

  defp split_on_x(panes) do
    panes
    |> split_boundaries(:left, :width)
    |> Enum.find_value(fn boundary ->
      case partition_by_boundary(panes, boundary, :left, :width) do
        {:ok, first, second} -> {:ok, "horizontal", first, second}
        :error -> nil
      end
    end)
  end

  defp split_on_y(panes) do
    panes
    |> split_boundaries(:top, :height)
    |> Enum.find_value(fn boundary ->
      case partition_by_boundary(panes, boundary, :top, :height) do
        {:ok, first, second} -> {:ok, "vertical", first, second}
        :error -> nil
      end
    end)
  end

  defp split_boundaries(panes, offset_key, size_key) do
    max_end =
      panes
      |> Enum.map(&(field(&1, offset_key, 0) + field(&1, size_key, 0)))
      |> Enum.max(fn -> 0 end)

    panes
    |> Enum.map(&(field(&1, offset_key, 0) + field(&1, size_key, 0)))
    |> Enum.reject(&(&1 in [0, max_end]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp partition_by_boundary(panes, boundary, offset_key, size_key) do
    {first, rest} =
      Enum.split_with(panes, fn pane ->
        field(pane, offset_key, 0) + field(pane, size_key, 0) <= boundary
      end)

    {second, spanning} =
      Enum.split_with(rest, fn pane ->
        field(pane, offset_key, 0) >= boundary
      end)

    if first != [] and second != [] and spanning == [] do
      {:ok, first, second}
    else
      :error
    end
  end

  defp partition_size(panes, "horizontal") do
    bounds_size(panes, :left, :width)
  end

  defp partition_size(panes, "vertical") do
    bounds_size(panes, :top, :height)
  end

  defp partition_size(_panes, _direction), do: nil

  defp bounds_size(panes, offset_key, size_key) do
    min_offset =
      panes
      |> Enum.map(&field(&1, offset_key, 0))
      |> Enum.min(fn -> 0 end)

    max_end =
      panes
      |> Enum.map(&(field(&1, offset_key, 0) + field(&1, size_key, 0)))
      |> Enum.max(fn -> 0 end)

    max(max_end - min_offset, 0)
  end

  defp export_pane(pane, pane_names, workspace_root, window_root) do
    cwd = field(pane, :current_path)
    command = export_command(field(pane, :current_command))

    %{
      "name" => Map.fetch!(pane_names, field(pane, :id)),
      "cwd" => pane_cwd(cwd, window_root, workspace_root),
      "command" => command,
      "focus" => field(pane, :active, false),
      "metadata" =>
        compact(%{
          "source_pane_id" => field(pane, :id),
          "index" => field(pane, :index)
        })
    }
    |> compact()
  end

  defp pane_names(panes) do
    panes
    |> Enum.map(fn pane ->
      base =
        pane
        |> field(:current_command)
        |> command_name()
        |> fallback("pane-#{field(pane, :index, 0)}")

      {field(pane, :id), base}
    end)
    |> unique_names()
    |> Map.new()
  end

  defp unique_names(pairs) do
    {_counts, named} =
      Enum.reduce(pairs, {%{}, []}, fn {id, base}, {counts, named} ->
        count = Map.get(counts, base, 0) + 1
        name = if count == 1, do: base, else: "#{base}-#{count}"

        {Map.put(counts, base, count), [{id, name} | named]}
      end)

    Enum.reverse(named)
  end

  defp startup(topology, windows) do
    active_window_id = Map.get(topology, :active_window_id, Map.get(topology, "active_window_id"))
    active_pane_id = Map.get(topology, :active_pane_id, Map.get(topology, "active_pane_id"))

    active_window = Enum.find(windows, &(field(&1, :id) == active_window_id))
    panes = field(active_window || %{}, :pane_list, [])
    pane_names = pane_names(panes)

    compact(%{
      "window" => active_window && field(active_window, :name),
      "pane" => active_pane_id && Map.get(pane_names, active_pane_id)
    })
  end

  defp window_root([]), do: nil

  defp window_root(panes) do
    pane = Enum.find(panes, &field(&1, :active, false)) || List.first(panes)
    field(pane, :current_path)
  end

  defp root_expr(nil), do: nil
  defp root_expr(root) when is_binary(root), do: path_expr(root, root)

  defp pane_cwd(nil, _window_root, _workspace_root), do: nil
  defp pane_cwd(cwd, cwd, _workspace_root), do: nil
  defp pane_cwd(cwd, _window_root, workspace_root), do: path_expr(cwd, workspace_root)

  defp path_expr(nil, _workspace_root), do: nil
  defp path_expr(path, nil) when is_binary(path), do: path

  defp path_expr(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    path = Path.expand(path)
    root = Path.expand(workspace_root)

    cond do
      path == root ->
        "${workspace_root}"

      String.starts_with?(path, root <> "/") ->
        "${workspace_root}/" <> Path.relative_to(path, root)

      true ->
        path
    end
  end

  defp export_command(command) do
    command
    |> blank_to_nil()
    |> case do
      nil -> nil
      shell when shell in ["bash", "sh", "zsh", "fish"] -> nil
      command -> command
    end
  end

  defp command_name(command) do
    command
    |> blank_to_nil()
    |> case do
      nil -> nil
      shell when shell in ["bash", "sh", "zsh", "fish"] -> "shell"
      command -> Path.basename(command)
    end
  end

  defp default_name(nil), do: "exported_session"

  defp default_name(session) when is_binary(session) do
    "exported_" <> String.replace(session, ~r/[^A-Za-z0-9_-]+/, "_")
  end

  defp fallback(nil, value), do: value
  defp fallback("", value), do: value
  defp fallback(value, _fallback), do: value

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp field(value, key, default \\ nil)

  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp encode_yaml(value, indent) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, child} -> encode_yaml_pair(key, child, indent) end)
  end

  defp encode_yaml(value, indent) when is_list(value) do
    Enum.map_join(value, "\n", &encode_yaml_list_item(&1, indent))
  end

  defp encode_yaml(value, _indent), do: encode_scalar(value)

  defp encode_yaml_pair(key, value, indent) when is_map(value) or is_list(value) do
    "#{spaces(indent)}#{key}:\n#{encode_yaml(value, indent + 2)}"
  end

  defp encode_yaml_pair(key, value, indent) do
    "#{spaces(indent)}#{key}: #{encode_scalar(value)}"
  end

  defp encode_yaml_list_item(value, indent) when is_map(value) do
    encoded = encode_yaml(value, indent + 2)
    [first | rest] = String.split(encoded, "\n")

    ([spaces(indent) <> "- " <> String.trim_leading(first)] ++ rest)
    |> Enum.join("\n")
  end

  defp encode_yaml_list_item(value, indent) when is_list(value) do
    "#{spaces(indent)}-\n#{encode_yaml(value, indent + 2)}"
  end

  defp encode_yaml_list_item(value, indent), do: "#{spaces(indent)}- #{encode_scalar(value)}"

  defp encode_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp encode_scalar(value) when is_boolean(value), do: to_string(value)
  defp encode_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_scalar(value) when is_float(value), do: Float.to_string(value)
  defp encode_scalar(nil), do: "null"

  defp spaces(count), do: String.duplicate(" ", count)
end
