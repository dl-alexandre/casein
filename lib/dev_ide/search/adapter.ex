defmodule Casein.Search.Adapter do
  @moduledoc "Behaviour for workspace search adapters."

  alias Casein.Search.Result

  @callback search(root :: String.t(), query :: String.t(), opts :: keyword()) ::
              {:ok, [Result.t()]}
              | {:error,
                 :rg_missing
                 | :timeout
                 | :too_short
                 | :too_long
                 | :no_root
                 | term()}
  @callback available?() :: boolean()
end
