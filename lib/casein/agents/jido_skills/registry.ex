defmodule Casein.Agents.JidoSkills.Registry do
  @moduledoc false

  alias Casein.Agents.JidoActions
  alias Casein.Agents.JidoRuntime
  alias Casein.Agents.JidoSkills.Loader

  @type skill :: Loader.skill()

  @default_coding ~w(inspect patch approved-verify human-input progress representative-edit)
  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/

  @spec default_roots() :: [String.t()]
  def default_roots do
    [
      packaged_root(),
      Path.join(checkout(), ".claude/skills")
    ]
  end

  @spec packaged_root() :: String.t()
  def packaged_root do
    :casein
    |> Application.app_dir("priv/jido/skills")
    |> Path.expand()
  end

  @spec default_coding() :: [String.t()]
  def default_coding, do: @default_coding

  @spec default_model() :: String.t()
  def default_model do
    JidoRuntime.profile().model
  end

  @spec default_provider() :: String.t()
  def default_provider do
    JidoRuntime.profile().provider
  end

  @spec catalog_digest() :: String.t()
  def catalog_digest do
    payload =
      JidoActions.catalog()
      |> Enum.map(&{&1.name, &1.supported, &1.capability, &1.mutates})
      |> :erlang.term_to_binary()

    :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
  end

  @spec load(String.t() | [String.t()]) :: {:ok, [skill()]} | {:error, map()}
  def load(roots \\ default_roots())

  def load(root) when is_binary(root), do: load([root])

  def load(roots) when is_list(roots) do
    skills =
      roots
      |> Enum.flat_map(&load_root/1)
      |> Enum.uniq_by(& &1.name)

    {:ok, Enum.sort_by(skills, & &1.name)}
  end

  def load(_), do: {:error, %{error: :invalid, result: :invalid, message: "roots must be paths"}}

  @spec list(String.t() | [String.t()]) :: [skill()]
  def list(roots \\ default_roots()) do
    case load(roots) do
      {:ok, skills} -> skills
      {:error, _} -> []
    end
  end

  @spec get(String.t(), String.t() | [String.t()]) :: {:ok, skill()} | {:error, map()}
  def get(name, roots \\ default_roots())

  def get(name, roots) when is_binary(name) do
    case Enum.find(list(roots), &(&1.name == name)) do
      nil ->
        {:error,
         %{
           error: :unknown_skill,
           result: :invalid,
           skill: name,
           message: "unknown skill #{name}",
           retryable: false
         }}

      skill ->
        {:ok, skill}
    end
  end

  def get(_name, _roots) do
    {:error, %{error: :invalid, result: :invalid, message: "skill name required"}}
  end

  @spec support(skill() | String.t()) :: map()
  def support(%{name: _} = skill) do
    specs = Enum.map(skill.actions, &{&1, JidoActions.spec(&1)})
    missing = for {name, spec} <- specs, unsupported?(name, spec, skill), do: name
    forbidden = Enum.filter(skill.actions, &JidoActions.forbidden?/1)
    reason = support_reason(skill, missing, forbidden)

    %{
      skill: skill.name,
      kind: skill.kind,
      actions: skill.actions,
      supported?: reason == nil,
      missing: missing,
      forbidden: forbidden,
      reason: reason,
      version: skill.version,
      catalog_digest: catalog_digest()
    }
  end

  def support(name) when is_binary(name) do
    case get(name) do
      {:ok, skill} -> support(skill)
      {:error, error} -> Map.merge(error, %{supported?: false, missing: [], forbidden: []})
    end
  end

  defp unsupported?(_name, nil, _skill), do: true
  defp unsupported?(_name, %{supported: false}, _skill), do: true
  defp unsupported?(_name, _spec, %{jido: :unsupported}), do: true
  defp unsupported?(_name, _spec, %{jido: :runtime_specific}), do: true
  defp unsupported?(_name, _spec, %{kind: :runtime}), do: true
  defp unsupported?(_name, _spec, _skill), do: false

  defp support_reason(%{kind: :runtime}, _missing, _forbidden), do: :runtime_specific
  defp support_reason(%{jido: :runtime_specific}, _missing, _forbidden), do: :runtime_specific
  defp support_reason(_skill, _missing, [_ | _]), do: :runtime_specific
  defp support_reason(%{jido: :unsupported}, _missing, _forbidden), do: :not_yet_supported
  defp support_reason(_skill, [_ | _], _forbidden), do: :not_yet_supported
  defp support_reason(_skill, [], []), do: nil

  defp load_root(root) when is_binary(root) do
    source = source_for(root)

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@name_re, &1))
        |> Enum.map(&Path.join([root, &1, "SKILL.md"]))
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(fn path ->
          case Loader.parse_file(path, source: source) do
            {:ok, skill} -> [skill]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp load_root(_), do: []

  defp source_for(root) do
    packaged = packaged_root()

    cond do
      Path.expand(root) == packaged -> :packaged
      String.ends_with?(Path.expand(root), ".claude/skills") -> :repo
      true -> :inline
    end
  end

  defp checkout do
    case System.get_env("CASEIN_CHECKOUT") do
      path when is_binary(path) and path != "" -> path
      _ -> File.cwd!()
    end
  end
end
