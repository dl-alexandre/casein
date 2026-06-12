defmodule DevIDE.Git.InspectorCache do
  @moduledoc """
  Owner process for `DevIDE.Git.Inspector`'s ETS result cache.

  The table must outlive the transient callers that read through it
  (SessionDirectory processes stop when their last watcher leaves), so a
  permanent supervised process holds it. All reads/writes happen directly
  against the public table from the caller's process — this GenServer does
  nothing after init.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ =
      :ets.new(GitCtl.Cache.table(), [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
