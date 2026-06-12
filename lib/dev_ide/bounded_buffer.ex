defmodule DevIDE.BoundedBuffer do
  @moduledoc false

  @spec append(binary(), iodata(), pos_integer(), keyword()) :: binary()
  defdelegate append(buffer, data, limit, opts \\ []), to: TerminalCtl.Replay
end
