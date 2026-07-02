defmodule DevIDE.TestCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using opts do
    quote do
      use ExUnit.Case, unquote(opts)
    end
  end

  setup tags do
    DevIDE.Test.ManagerReqTest.setup(tags)
    :ok
  end
end
