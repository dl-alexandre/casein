defmodule Casein.Agents.JidoSkills.Loader do
  @moduledoc false

  alias Casein.Agents.SkillIntegrity

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/
  @runtime_markers ~w(
    terminal_send_keys terminal_send_command terminal_send_agent
    terminal_paste_agent_text terminal_capture preview_open preview_click
    preview_type tmux agent_pair
  )

  @type skill :: %{
          name: String.t(),
          description: String.t(),
          kind: :task | :runtime,
          actions: [String.t()],
          version: String.t(),
          path: String.t() | nil,
          source: :packaged | :repo | :inline,
          jido: :supported | :unsupported | :runtime_specific
        }

  @spec parse(String.t(), keyword()) :: {:ok, skill()} | {:error, map()}
  def parse(path_or_body, opts \\ [])

  def parse(path, opts) when is_binary(path) do
    if String.contains?(path, "\n") or Keyword.get(opts, :inline, false) do
      parse_body(path, Keyword.put_new(opts, :source, :inline))
    else
      parse_file(path, opts)
    end
  end

  def parse(_other, _opts), do: {:error, error(:invalid, "skill source must be a path or body")}

  @spec parse_file(String.t(), keyword()) :: {:ok, skill()} | {:error, map()}
  def parse_file(path, opts \\ []) when is_binary(path) do
    with :ok <- safe_name(Path.basename(Path.dirname(path))),
         {:ok, body} <- read_skill(path) do
      parse_body(
        body,
        opts
        |> Keyword.put_new(:path, path)
        |> Keyword.put_new(:name, Path.basename(Path.dirname(path)))
      )
    end
  end

  @spec parse_body(String.t(), keyword()) :: {:ok, skill()} | {:error, map()}
  def parse_body(body, opts \\ []) when is_binary(body) do
    {front, markdown} = split_frontmatter(body)
    fields = parse_frontmatter(front)
    name = pick_name(fields, opts)

    if is_binary(name) and Regex.match?(@name_re, name) do
      actions = list_field(fields, "actions")
      kind = kind_of(fields, actions, markdown)
      jido = jido_of(fields, kind)

      {:ok,
       %{
         name: name,
         description: description(fields),
         kind: kind,
         actions: actions,
         version: version(opts, body),
         path: Keyword.get(opts, :path),
         source: Keyword.get(opts, :source, :inline),
         jido: jido
       }}
    else
      {:error, error(:invalid, "skill name is missing or invalid")}
    end
  end

  defp pick_name(fields, opts) do
    Keyword.get(opts, :name) || Map.get(fields, "name")
  end

  defp description(fields) do
    case Map.get(fields, "description") do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp kind_of(fields, actions, markdown) do
    case Map.get(fields, "kind") do
      "task" -> :task
      "runtime" -> :runtime
      _ -> infer_kind(actions, markdown)
    end
  end

  defp infer_kind(_actions, markdown) do
    lowered = String.downcase(markdown || "")

    if Enum.any?(@runtime_markers, &String.contains?(lowered, &1)) do
      :runtime
    else
      :task
    end
  end

  defp jido_of(fields, kind) do
    case Map.get(fields, "jido") do
      "unsupported" -> :unsupported
      "runtime_specific" -> :runtime_specific
      "supported" -> :supported
      _ when kind == :runtime -> :runtime_specific
      _ -> :supported
    end
  end

  defp version(opts, body) do
    cond do
      is_binary(Keyword.get(opts, :version)) ->
        Keyword.fetch!(opts, :version)

      is_binary(Keyword.get(opts, :path)) ->
        case SkillIntegrity.fingerprint(Path.dirname(Keyword.fetch!(opts, :path))) do
          {:ok, hash} -> hash
          _ -> hash_body(body)
        end

      true ->
        hash_body(body)
    end
  end

  defp hash_body(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
  end

  defp split_frontmatter(body) do
    case String.trim_leading(body) do
      "---\n" <> rest ->
        case String.split(rest, ~r/\n---[[:space:]]*\n/, parts: 2) do
          [front, markdown] -> {front, markdown}
          [front] -> {front, ""}
        end

      other ->
        {"", other}
    end
  end

  defp parse_frontmatter(front) do
    front
    |> String.split("\n")
    |> parse_lines(%{}, nil)
  end

  defp parse_lines([], fields, {:list, key, acc}) do
    Map.put(fields, key, Enum.reverse(acc))
  end

  defp parse_lines([], fields, {:block, key, acc}) do
    Map.put(fields, key, acc |> Enum.reverse() |> Enum.join("\n") |> String.trim())
  end

  defp parse_lines([], fields, _), do: fields

  defp parse_lines([line | rest], fields, {:list, key, acc}) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "- ") ->
        parse_lines(
          rest,
          fields,
          {:list, key, [yaml_value(String.trim_leading(trimmed, "- ")) | acc]}
        )

      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_lines(rest, fields, {:list, key, acc})

      true ->
        parse_lines([line | rest], Map.put(fields, key, Enum.reverse(acc)), nil)
    end
  end

  defp parse_lines([line | rest], fields, {:block, key, acc}) do
    cond do
      String.starts_with?(line, "  ") or String.trim(line) == "" ->
        parse_lines(rest, fields, {:block, key, [String.trim_leading(line) | acc]})

      true ->
        value = acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()
        parse_lines([line | rest], Map.put(fields, key, value), nil)
    end
  end

  defp parse_lines([line | rest], fields, nil) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") or trimmed == "---" ->
        parse_lines(rest, fields, nil)

      String.contains?(trimmed, ":") ->
        [key, raw] = String.split(trimmed, ":", parts: 2)
        value = String.trim(raw)

        cond do
          value in ["", "[]"] ->
            parse_lines(rest, fields, {:list, String.trim(key), []})

          value in [">", ">-", "|", "|-"] ->
            parse_lines(rest, fields, {:block, String.trim(key), []})

          true ->
            parse_lines(rest, Map.put(fields, String.trim(key), yaml_value(value)), nil)
        end

      true ->
        parse_lines(rest, fields, nil)
    end
  end

  defp list_field(fields, key) do
    case Map.get(fields, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      value when is_binary(value) and value != "" -> [value]
      _ -> []
    end
  end

  defp yaml_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp safe_name(name) do
    if Regex.match?(@name_re, name) do
      :ok
    else
      {:error, error(:invalid, "skill directory name is invalid")}
    end
  end

  # Path is a SKILL.md under a configured root; name already slug-checked.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_skill(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, error(:not_found, "SKILL.md not found")}
      {:error, reason} -> {:error, error(:unreadable, "could not read SKILL.md: #{reason}")}
    end
  end

  defp error(reason, message) do
    %{error: reason, result: :invalid, message: message, retryable: false}
  end
end
