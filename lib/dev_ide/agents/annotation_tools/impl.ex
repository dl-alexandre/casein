defmodule Casein.Agents.AnnotationTools.Impl do
  @moduledoc false

  alias Casein.Annotations
  alias Casein.Annotations.Annotation

  @default_limit 20
  @max_limit 100

  def list(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params) do
      opts =
        []
        |> put_opt(:limit, limit_arg(params))
        |> put_opt(:approval_state, enum_arg(params, "approval_state", &approval_state_atom/1))
        |> put_opt(:file_path, string_arg(params, "file_path"))
        |> put_opt(:session_id, string_arg(params, "session_id"))
        |> put_opt(:pane_id, string_arg(params, "pane_id"))

      annotations =
        workspace_id
        |> Annotations.list_for_workspace(opts)
        |> Enum.map(&serialize/1)

      {:ok, %{workspace_id: workspace_id, annotations: annotations, count: length(annotations)}}
    end
  end

  @spec propose(map()) :: {:ok, map()} | {:error, term()}
  def propose(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, attrs} <- propose_attrs(params) do
      case Annotations.propose_from_agent(workspace_id, attrs) do
        {:ok, annotation} ->
          {:ok, %{annotation: serialize(annotation)}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, {:invalid_annotation, format_changeset_errors(changeset)}}
      end
    end
  end

  defp propose_attrs(params) do
    attrs =
      params
      |> Map.take([
        "content",
        "author_type",
        "visibility",
        "session_id",
        "pane_id",
        "preview_id",
        "file_path",
        "file_range",
        "terminal_range",
        "linked_entities",
        "metadata",
        "actor_id"
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    with :ok <- require_field(attrs, "content"),
         :ok <- require_field(attrs, "author_type"),
         {:ok, author_type} <- parse_author_type(Map.get(attrs, "author_type")) do
      attrs =
        attrs
        |> Map.put("author_type", author_type)
        |> maybe_put_enum("visibility", &visibility_atom/1)

      {:ok, attrs}
    end
  end

  defp serialize(%Annotation{} = annotation) do
    %{
      id: annotation.id,
      content: annotation.content,
      author_type: Atom.to_string(annotation.author_type),
      visibility: Atom.to_string(annotation.visibility),
      approval_state: Atom.to_string(annotation.approval_state),
      workspace_id: annotation.workspace_id,
      session_id: annotation.session_id,
      pane_id: annotation.pane_id,
      preview_id: annotation.preview_id,
      file_path: annotation.file_path,
      file_range: annotation.file_range,
      terminal_range: annotation.terminal_range,
      linked_entities: annotation.linked_entities,
      metadata: annotation.metadata,
      inserted_at: annotation.inserted_at,
      updated_at: annotation.updated_at
    }
  end

  defp workspace_id_arg(params) do
    case Map.get(params, "workspace_id") || Map.get(params, :workspace_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_workspace_id}
    end
  end

  defp limit_arg(params) do
    case Map.get(params, "limit") || Map.get(params, :limit) do
      n when is_integer(n) and n > 0 ->
        min(n, @max_limit)

      n when is_binary(n) ->
        case Integer.parse(n) do
          {parsed, ""} when parsed > 0 -> min(parsed, @max_limit)
          _ -> @default_limit
        end

      _ ->
        @default_limit
    end
  end

  defp string_arg(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp enum_arg(params, key, parser) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" ->
        case parser.(value) do
          {:ok, atom} -> atom
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp require_field(attrs, key) do
    case blank_string(Map.get(attrs, key)) do
      nil -> {:error, {:missing_field, key}}
      _ -> :ok
    end
  end

  defp blank_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_string(_), do: nil

  defp maybe_put_enum(attrs, key, parser) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case parser.(value) do
          {:ok, atom} -> Map.put(attrs, key, atom)
          _ -> attrs
        end

      _ ->
        attrs
    end
  end

  defp parse_author_type(value) when is_binary(value) do
    case String.trim(value) do
      "human" -> {:ok, :human}
      "agent_grok" -> {:ok, :agent_grok}
      "agent_codex" -> {:ok, :agent_codex}
      "agent_claude" -> {:ok, :agent_claude}
      other -> {:error, {:invalid_author_type, other}}
    end
  end

  defp approval_state_atom("pending"), do: {:ok, :pending}
  defp approval_state_atom("approved"), do: {:ok, :approved}
  defp approval_state_atom("rejected"), do: {:ok, :rejected}
  defp approval_state_atom(_), do: :error

  defp visibility_atom("private"), do: {:ok, :private}
  defp visibility_atom("shared"), do: {:ok, :shared}
  defp visibility_atom("per_agent"), do: {:ok, :per_agent}
  defp visibility_atom(_), do: :error

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
