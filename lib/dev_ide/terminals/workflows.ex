defmodule DevIDE.Terminals.Workflows do
  @moduledoc """
  Repository-scoped governed terminal workflows.

  This intentionally supports a small Warp-compatible YAML subset for safe
  command launchers: `name`, `command`, `description`, and argument names. The
  rendered command is split into argv and revalidated from the workflow spec at
  runner-claim time, so assignments never persist executable argv.
  """

  alias DevIDE.Workspaces.State

  @workflow_dirs [".dev_ide/workflows", ".warp/workflows"]
  @placeholder ~r/\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}/
  @encoded_prefix "workflow:"

  @type spec :: %{
          id: String.t(),
          workspace_id: String.t(),
          path: String.t(),
          name: String.t(),
          command: String.t(),
          description: String.t(),
          arguments: [String.t()]
        }

  @spec resolve_line(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve_line(workspace_id, line) when is_binary(workspace_id) and is_binary(line) do
    argv = split_argv(line)

    with {:ok, argv} <- argv do
      workspace_id
      |> list_specs()
      |> Enum.find_value({:error, :not_allowed}, fn spec ->
        with {:ok, bindings} <- match_spec(spec, argv),
             {:ok, _argv} <- argv_for(spec, bindings) do
          {:ok, encode_command_id(spec, bindings)}
        else
          {:error, _} -> false
        end
      end)
    end
  end

  def resolve_line(_, _), do: {:error, :not_allowed}

  @doc "Encoded workflow command id using default placeholder bindings."
  @spec command_id(spec()) :: String.t()
  def command_id(spec), do: encode_command_id(spec, default_bindings(spec))

  @doc "True when the workflow can run from the palette without extra arguments."
  @spec palette_runnable?(spec()) :: boolean()
  def palette_runnable?(%{arguments: []}), do: true
  def palette_runnable?(_), do: false

  @spec list_command_ids() :: [String.t()]
  def list_command_ids do
    State.list()
    |> Enum.flat_map(fn record ->
      record.external_id
      |> list_specs()
      |> Enum.map(&encode_command_id(&1, default_bindings(&1)))
    end)
  end

  @spec fetch_command(String.t()) :: {:ok, map()} | :error
  def fetch_command(@encoded_prefix <> encoded) do
    with {:ok, payload} <- decode_payload(encoded),
         {:ok, spec} <- fetch_spec(payload["workspace_id"], payload["spec_id"]),
         bindings when is_map(bindings) <- payload["bindings"],
         {:ok, argv} <- argv_for(spec, bindings) do
      {:ok,
       %{
         id: encode_command_id(spec, bindings),
         command_id: @encoded_prefix <> encoded,
         argv: argv,
         description: workflow_description(spec)
       }}
    else
      _ -> :error
    end
  end

  def fetch_command(_), do: :error

  @spec list_specs(String.t()) :: [spec()]
  def list_specs(workspace_id) when is_binary(workspace_id) do
    with {:ok, record} <- State.get(workspace_id),
         root when is_binary(root) <- record.host_path,
         true <- File.dir?(root) do
      @workflow_dirs
      |> Enum.flat_map(&workflow_files(root, &1))
      |> Enum.flat_map(&parse_file(workspace_id, &1))
    else
      _ -> []
    end
  end

  def list_specs(_), do: []

  defp workflow_files(root, rel_dir) do
    dir = Path.join(root, rel_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, [".yaml", ".yml"]))
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp parse_file(workspace_id, path) do
    with {:ok, body} <- read_workflow_file(path),
         {:ok, fields} <- parse_yaml_subset(body),
         command when is_binary(command) and command != "" <- fields["command"] do
      [
        %{
          id: spec_id(path),
          workspace_id: workspace_id,
          path: path,
          name: fields["name"] || spec_id(path),
          command: command,
          description: fields["description"] || "Run repository workflow #{spec_id(path)}.",
          arguments: argument_names(fields, command)
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_yaml_subset(body) do
    fields =
      body
      |> String.split("\n")
      |> parse_lines(%{}, nil)

    {:ok, fields}
  end

  defp parse_lines([], fields, _), do: fields

  defp parse_lines([line | rest], fields, {:block, key, acc}) do
    cond do
      String.starts_with?(line, "  ") or String.trim(line) == "" ->
        parse_lines(rest, fields, {:block, key, [String.trim_trailing(line) | acc]})

      true ->
        value = acc |> Enum.reverse() |> Enum.join("\n") |> String.trim()
        parse_lines([line | rest], Map.put(fields, key, value), nil)
    end
  end

  defp parse_lines([line | rest], fields, section) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") or trimmed == "---" ->
        parse_lines(rest, fields, section)

      trimmed in ["arguments:", "arguments: []"] ->
        parse_lines(rest, Map.put_new(fields, "arguments", []), :arguments)

      section == :arguments and String.starts_with?(trimmed, "- name:") ->
        name = trimmed |> String.replace_prefix("- name:", "") |> yaml_value()
        parse_lines(rest, update_in(fields["arguments"], &((&1 || []) ++ [name])), section)

      String.contains?(trimmed, ":") ->
        [key, raw] = String.split(trimmed, ":", parts: 2)
        value = String.trim(raw)

        if value in ["|-", "|"] do
          parse_lines(rest, fields, {:block, key, []})
        else
          parse_lines(rest, Map.put(fields, key, yaml_value(value)), nil)
        end

      true ->
        parse_lines(rest, fields, section)
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

  defp argument_names(fields, command) do
    declared = fields["arguments"] || []

    placeholders =
      @placeholder
      |> Regex.scan(command, capture: :all_but_first)
      |> List.flatten()

    (declared ++ placeholders)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  defp match_spec(spec, argv) do
    with {:ok, template_argv} <- split_argv(spec.command),
         true <- length(template_argv) == length(argv) do
      template_argv
      |> Enum.zip(argv)
      |> Enum.reduce_while({:ok, %{}}, &match_token/2)
    else
      _ -> {:error, :not_allowed}
    end
  end

  defp match_token({"{{" <> _ = template, value}, {:ok, bindings}) do
    case Regex.run(~r/^\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}$/, template) do
      [_, name] -> {:cont, {:ok, Map.put(bindings, name, value)}}
      _ -> {:halt, {:error, :not_allowed}}
    end
  end

  defp match_token({same, same}, {:ok, bindings}), do: {:cont, {:ok, bindings}}
  defp match_token(_, _), do: {:halt, {:error, :not_allowed}}

  defp argv_for(spec, bindings) do
    with :ok <- validate_bindings(spec, bindings) do
      spec.command
      |> render(bindings)
      |> split_argv()
    end
  end

  defp validate_bindings(spec, bindings) do
    allowed = MapSet.new(spec.arguments)

    cond do
      Enum.any?(Map.keys(bindings), &(not MapSet.member?(allowed, &1))) ->
        {:error, :unknown_argument}

      Enum.any?(bindings, fn {_k, v} -> unsafe_argument?(v) end) ->
        {:error, :unsafe_argument}

      true ->
        :ok
    end
  end

  defp unsafe_argument?(value) when is_binary(value) do
    String.contains?(value, ["\0", "\n", "\r"]) or Path.type(value) == :absolute or
      String.split(value, "/", trim: true) |> Enum.any?(&(&1 == ".."))
  end

  defp unsafe_argument?(_), do: true

  defp render(command, bindings) do
    Regex.replace(@placeholder, command, fn _, name -> Map.fetch!(bindings, name) end)
  end

  defp split_argv(line) do
    case OptionParser.split(line) do
      [] -> {:error, :blank}
      argv -> {:ok, argv}
    end
  rescue
    _ -> {:error, :not_allowed}
  catch
    _, _ -> {:error, :not_allowed}
  end

  defp encode_command_id(spec, bindings) do
    payload = %{
      "workspace_id" => spec.workspace_id,
      "spec_id" => spec.id,
      "bindings" => bindings
    }

    @encoded_prefix <> Base.url_encode64(Jason.encode!(payload), padding: false)
  end

  defp decode_payload(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} when is_map(payload) <- Jason.decode(json) do
      {:ok, payload}
    end
  end

  defp fetch_spec(workspace_id, spec_id) when is_binary(workspace_id) and is_binary(spec_id) do
    case Enum.find(list_specs(workspace_id), &(&1.id == spec_id)) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  defp fetch_spec(_, _), do: :error

  defp default_bindings(spec), do: Map.new(spec.arguments, &{&1, &1})
  defp spec_id(path), do: path |> Path.basename() |> Path.rootname()
  defp workflow_description(spec), do: "Run repository workflow #{spec.name}: #{spec.description}"

  # sobelow_skip ["Traversal.FileModule"]
  defp read_workflow_file(path), do: File.read(path)
end
