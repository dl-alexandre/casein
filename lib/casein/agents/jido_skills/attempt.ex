defmodule Casein.Agents.JidoSkills.Attempt do
  @moduledoc false

  alias Casein.Agents.JidoSkills.{Loader, Registry}

  @spec bind_attempt(map()) :: map()
  def bind_attempt(attrs) when is_map(attrs) do
    skill = Map.get(attrs, :skill) || Map.get(attrs, "skill")
    version = Map.get(attrs, :skill_version) || Map.get(attrs, "skill_version")

    catalog =
      Map.get(attrs, :catalog_digest) || Map.get(attrs, "catalog_digest") ||
        Registry.catalog_digest()

    %{
      workspace_id: Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id"),
      task_id: Map.get(attrs, :task_id) || Map.get(attrs, "task_id"),
      attempt_id: Map.get(attrs, :attempt_id) || Map.get(attrs, "attempt_id"),
      worktree_path: Map.get(attrs, :worktree_path) || Map.get(attrs, "worktree_path"),
      backend: backend(attrs),
      skill: skill_name(skill),
      skill_path: skill_path(skill, attrs),
      skill_version: version || skill_version(skill),
      catalog_digest: catalog,
      fallback?: Map.get(attrs, :fallback?) == true,
      fallback_reason: Map.get(attrs, :fallback_reason) || Map.get(attrs, "fallback_reason"),
      completed_mutation_tokens: tokens(attrs),
      headless: true,
      pane_id: nil
    }
  end

  @spec evidence_status(map()) :: :current | :stale
  def evidence_status(%{skill_version: version, catalog_digest: digest} = binding)
      when is_binary(version) and is_binary(digest) do
    if digest == Registry.catalog_digest() and skill_current?(binding, version) do
      :current
    else
      :stale
    end
  end

  def evidence_status(_binding), do: :stale

  defp backend(attrs) do
    case Map.get(attrs, :backend) || Map.get(attrs, :runtime) || Map.get(attrs, "backend") do
      :opencode -> :opencode
      "opencode" -> :opencode
      _ -> :jido
    end
  end

  defp skill_name(%{name: name}), do: name
  defp skill_name(name) when is_binary(name), do: name
  defp skill_name(_), do: nil

  defp skill_version(%{version: version}) when is_binary(version), do: version
  defp skill_version(_), do: nil

  defp skill_path(%{path: path}, _attrs) when is_binary(path), do: path

  defp skill_path(_skill, attrs) do
    Map.get(attrs, :skill_path) || Map.get(attrs, "skill_path")
  end

  defp skill_current?(%{skill_path: path}, version) when is_binary(path) do
    case Loader.parse_file(path) do
      {:ok, skill} -> skill.version == version
      _ -> false
    end
  end

  defp skill_current?(%{skill: name}, version) when is_binary(name) do
    case Registry.get(name) do
      {:ok, skill} -> skill.version == version
      _ -> false
    end
  end

  defp skill_current?(_binding, _version), do: true

  defp tokens(attrs) do
    attrs
    |> Map.get(:completed_mutation_tokens)
    |> Kernel.||(Map.get(attrs, "completed_mutation_tokens"))
    |> Kernel.||([])
    |> Enum.filter(&is_binary/1)
  end
end
