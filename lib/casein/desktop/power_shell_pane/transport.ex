defmodule Casein.Desktop.PowerShellPane.Transport do
  @moduledoc false

  @callback start(Path.t(), map(), pos_integer(), pos_integer(), keyword()) ::
              {:ok, pid(), pid()} | {:error, term()}
  @callback write(pid(), iodata()) :: :ok | {:error, term()}
  @callback resize(pid(), pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback terminal_write(pid(), iodata()) :: :ok | {:error, term()}
  @callback close(pid(), pid()) :: :ok
end
