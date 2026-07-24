defmodule Casein.UAT.Manifest do
  @moduledoc """
  A UAT scenario manifest (`priv/uat/<scenario>/manifest.json`) — the contract a
  scenario must declare before it can run in a tier.

  Fields:

    * `scenario_id` — stable id; matches the directory name
    * `identity` — the forward-auth identity to run as (workspace owner email)
    * `seed_cmd` — command run inside the seeded workspace to put the
      app-under-test into a deterministic state (e.g. `mix run priv/uat/seeds/checkout.exs`)
    * `tiers` — which tiers this scenario is eligible for (`:tier_a`, `:tier_b`)
    * `baselines` — optional artifact baselines (e.g. screenshot paths)
    * `fixtures_dir` — directory copied into the ephemeral `CASEIN_WORKSPACES_ROOT`

  **Tier A determinism is a contract, not a convention:** a scenario eligible for
  `:tier_a` MUST declare a `seed_cmd`. A scenario that cannot be made
  deterministic declares only `:tier_b` and is skipped by the Tier A runner
  instead of flaking.

  > **Security:** a manifest is trusted input — `seed_cmd` is run via `bash -lc`
  > (arbitrary code execution by design) and `scenario_id` builds file paths
  > (validated `^[a-z0-9_-]+$`). Never load a manifest from an unreviewed
  > `scenario_dir`/PR; treat committing one as committing code.
  """

  @valid_tiers [:tier_a, :tier_b]
  @tier_strings Enum.map(@valid_tiers, &Atom.to_string/1)

  @enforce_keys [:scenario_id]
  defstruct scenario_id: nil,
            identity: nil,
            seed_cmd: nil,
            tiers: [:tier_a],
            baselines: %{},
            fixtures_dir: nil

  @type t :: %__MODULE__{
          scenario_id: String.t(),
          identity: String.t() | nil,
          seed_cmd: String.t() | nil,
          tiers: [atom()],
          baselines: map(),
          fixtures_dir: String.t() | nil
        }

  @doc "Valid tier atoms."
  @spec valid_tiers() :: [atom()]
  def valid_tiers, do: @valid_tiers

  @doc "Load and validate a manifest from a JSON file path."
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  # UAT manifests are operator-owned scenario files; callers choose the scenario path explicitly.
  # sobelow_skip ["Traversal.FileModule"]
  def load(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body),
         manifest <- from_map(map),
         :ok <- validate(manifest) do
      {:ok, manifest}
    end
  end

  @doc "Build a manifest struct from a decoded JSON map (does not validate)."
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      scenario_id: map["scenario_id"],
      identity: map["identity"],
      seed_cmd: map["seed_cmd"],
      tiers: parse_tiers(map["tiers"]),
      baselines: map["baselines"] || %{},
      fixtures_dir: map["fixtures_dir"]
    }
  end

  @doc "Is this scenario eligible to run in `tier`?"
  @spec tier_eligible?(t(), atom()) :: boolean()
  def tier_eligible?(%__MODULE__{tiers: tiers}, tier), do: tier in tiers

  @doc """
  Validate the contract: a scenario id, a non-empty valid tier set, and — when
  `:tier_a` is claimed — a `seed_cmd` so the run is deterministic.
  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = m) do
    errors =
      []
      |> reject_blank(m.scenario_id, "scenario_id is required")
      |> reject(
        is_binary(m.scenario_id) and not valid_id?(m.scenario_id),
        "scenario_id must match ^[a-z0-9_-]+$ (it builds file paths)"
      )
      |> reject(m.tiers == [], "tiers must not be empty")
      |> reject(invalid_tiers(m.tiers) != [], "invalid tiers: #{inspect(invalid_tiers(m.tiers))}")
      |> reject(
        :tier_a in m.tiers and blank?(m.seed_cmd),
        "tier_a scenarios must declare a seed_cmd (determinism contract)"
      )
      |> reject(
        not safe_relative_path?(m.fixtures_dir),
        "fixtures_dir must be a relative path without traversal"
      )

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc "True for nil or repo-style relative paths that cannot traverse upward."
  @spec safe_relative_path?(String.t() | nil | term()) :: boolean()
  def safe_relative_path?(nil), do: true

  def safe_relative_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and
      path |> Path.split() |> Enum.all?(&(&1 not in ["..", ".git"]))
  end

  def safe_relative_path?(_), do: false

  defp parse_tiers(nil), do: [:tier_a]
  defp parse_tiers(tiers) when is_list(tiers), do: Enum.map(tiers, &parse_tier/1)
  defp parse_tiers(_), do: []

  defp parse_tier(tier) when tier in @tier_strings, do: String.to_existing_atom(tier)
  # Keep unknown tiers as-is (a string) so validate/1 can flag them by value.
  defp parse_tier(tier), do: tier

  defp invalid_tiers(tiers), do: Enum.reject(tiers, &(&1 in @valid_tiers))

  defp valid_id?(id), do: id =~ ~r/\A[a-z0-9_-]+\z/

  defp reject(errors, true, msg), do: [msg | errors]
  defp reject(errors, _false, _msg), do: errors

  defp reject_blank(errors, value, msg), do: reject(errors, blank?(value), msg)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
