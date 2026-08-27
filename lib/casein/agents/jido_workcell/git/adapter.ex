defmodule Casein.Agents.JidoWorkcell.Git.Adapter do
  @moduledoc "Behaviour for the audited, workcell-scoped Git adapter."

  alias Casein.Agents.JidoWorkcell.Git.Scope

  @callback bind(Scope.t()) :: {:ok, Scope.t()} | {:error, term()}
  @callback status(Scope.t()) :: {:ok, map()} | {:error, term()}
  @callback diff(Scope.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  @callback stage(Scope.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  @callback commit(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback push(Scope.t()) :: {:ok, map()} | {:error, term()}
  @callback head_sha(Scope.t()) :: {:ok, String.t()} | {:error, term()}
end
