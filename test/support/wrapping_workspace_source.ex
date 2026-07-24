defmodule Casein.Test.WrappingWorkspaceSource do
  @moduledoc false

  def prepare_local_argv(argv), do: prepare_local_argv(argv, [])

  def prepare_local_argv(_argv, _opts) do
    ["sh", "-c", "printf wrapped >&2; exit 42"]
  end
end
