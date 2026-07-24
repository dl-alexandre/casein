defmodule Casein.ProposalApply.Adapter do
  @moduledoc "Behaviour for shelling out to apply a unified-diff patch."

  @callback check(root :: String.t(), patch_path :: String.t()) :: :ok | {:error, term()}
  @callback apply(root :: String.t(), patch_path :: String.t()) :: :ok | {:error, term()}
end
