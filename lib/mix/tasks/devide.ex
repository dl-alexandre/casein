unless match?({:win32, _}, :os.type()) or System.get_env("DEV_IDE_NATIVE_WINDOWS") in ~w(1 true) do
  defmodule Mix.Tasks.Devide do
    @moduledoc """
    Boundary root for repository-local development Mix tasks.
    """

    use Boundary,
      deps: [Mix, Graph, Boxart],
      exports: :all
  end
end
