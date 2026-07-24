defmodule CaseinPreviewBrowser.Supervisor do
  @moduledoc """
  Dynamic supervisor for preview browser sessions.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec start_session(DynamicSupervisor.supervisor(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_session(supervisor, opts \\ []) do
    DynamicSupervisor.start_child(supervisor, {CaseinPreviewBrowser.Session, opts})
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
