defmodule DevIDE.Proposals.Adapter do
  @moduledoc "Behaviour for proposal discovery/parsing adapters."

  alias DevIDE.Proposals.Proposal

  @callback discover(root :: String.t()) :: [Proposal.t()]
  @callback parse(root :: String.t(), rel_path :: String.t()) :: {:ok, Proposal.t()}
end
