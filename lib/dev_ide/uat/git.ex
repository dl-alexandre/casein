defmodule Casein.UAT.Git do
  @moduledoc """
  The seam for opening a self-heal proposal as a reviewable PR. `Casein.UAT.Proposal`
  owns *what* to propose (the diff + artifact); a `Git` implementation owns *how*
  to publish it. The default `Casein.UAT.Git.System` shells out to `git`/`gh`;
  tests inject a fake so proposal logic is verifiable without touching a remote.

  A proposal NEVER mutates a committed trace in place — the new trace is written
  on a fresh branch and merged only by a human.
  """

  @type proposal :: %{
          branch: String.t(),
          files: [{path :: String.t(), content :: String.t()}],
          title: String.t(),
          body: String.t()
        }

  @callback propose(proposal()) :: {:ok, ref :: term()} | {:error, term()}
end
