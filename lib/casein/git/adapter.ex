defmodule Casein.Git.Adapter do
  @moduledoc "Behaviour for git status/diff adapters."

  @type status_entry :: %{x: String.t(), y: String.t(), path: String.t()}

  @callback branch(root :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback status_short(root :: String.t()) :: {:ok, [status_entry()]} | {:error, term()}
  @callback diff(root :: String.t(), rel :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback diff_all(root :: String.t()) :: {:ok, String.t()} | {:error, term()}
end
