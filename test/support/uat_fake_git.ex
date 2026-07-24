defmodule Casein.UAT.FakeGit do
  @moduledoc """
  In-memory `Casein.UAT.Git` for tests. Records the proposal (branch + files) into
  the calling process dictionary and returns a fake PR ref — so self-heal proposal
  logic is verifiable without a git remote, and the test can assert nothing was
  written in place.
  """

  @behaviour Casein.UAT.Git

  def last, do: Process.get({__MODULE__, :last})

  @impl true
  def propose(proposal) do
    Process.put({__MODULE__, :last}, proposal)
    {:ok, "pr://fake"}
  end
end
