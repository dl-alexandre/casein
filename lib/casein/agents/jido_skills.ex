defmodule Casein.Agents.JidoSkills do
  @moduledoc """
  Jido skill registry, runtime selector, and OpenCode parity (#1017).

  Loads repository `SKILL.md` files, separates reusable task skills from
  OpenCode/TUI instructions, and maps each skill onto the typed
  `Casein.Agents.JidoActions` catalog. Unsupported skills fail with a
  machine-readable reason. Provider/tool/runtime failures fall back to
  OpenCode without replaying completed mutations.
  """

  alias Casein.Agents.JidoSkills.{Attempt, Fixture, Loader, Parity, Registry, Selector}

  @type skill :: Registry.skill()
  @type selection :: Selector.selection()
  @type fallback :: Selector.fallback()

  @doc "Default skill roots: packaged task skills, then repo `.claude/skills`."
  @spec default_roots() :: [String.t()]
  defdelegate default_roots(), to: Registry

  @spec default_coding() :: [String.t()]
  defdelegate default_coding(), to: Registry

  @spec default_model() :: String.t()
  defdelegate default_model(), to: Registry

  @spec catalog_digest() :: String.t()
  defdelegate catalog_digest(), to: Registry

  @spec load(String.t() | [String.t()]) :: {:ok, [skill()]} | {:error, map()}
  defdelegate load(roots \\ default_roots()), to: Registry

  @spec list(String.t() | [String.t()]) :: [skill()]
  defdelegate list(roots \\ default_roots()), to: Registry

  @spec get(String.t(), String.t() | [String.t()]) :: {:ok, skill()} | {:error, map()}
  defdelegate get(name, roots \\ default_roots()), to: Registry

  @spec parse(String.t(), keyword()) :: {:ok, skill()} | {:error, map()}
  defdelegate parse(path_or_body, opts \\ []), to: Loader

  @spec support(skill() | String.t()) :: map()
  defdelegate support(skill), to: Registry

  @spec select(String.t(), keyword() | map()) :: {:ok, selection()} | {:error, map()}
  defdelegate select(workspace_id, opts \\ []), to: Selector

  @spec fallback(map(), atom()) :: fallback()
  defdelegate fallback(prior, reason), to: Selector

  @spec remaining_actions(fallback() | map(), [map()]) :: [map()]
  defdelegate remaining_actions(receipt, actions), to: Selector

  @spec parity_matrix() :: [map()]
  defdelegate parity_matrix(), to: Parity, as: :matrix

  @spec bind_attempt(map()) :: map()
  defdelegate bind_attempt(attrs), to: Attempt

  @spec evidence_status(map()) :: :current | :stale
  defdelegate evidence_status(binding), to: Attempt

  @spec run_fixture(atom(), map()) :: {:ok, map()} | {:error, map()}
  defdelegate run_fixture(backend, opts), to: Fixture
end
