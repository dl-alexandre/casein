defmodule DevIDE.Fleet.ExecutionBackend do
  @moduledoc """
  Execution backend contract.

  Backends provide infrastructure for running a process (local, SSH, tmux).
  They never own orchestration truth; assignment state and execution state stay
  in the controller event/protocol boundary.
  """

  @callback prepare_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback start_session(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback attach(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback resume(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
end
