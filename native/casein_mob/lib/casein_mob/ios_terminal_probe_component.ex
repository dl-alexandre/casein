defmodule CaseinMob.IosTerminalProbeComponent do
  @moduledoc false

  use Mob.Component

  @impl Mob.Component
  def render(_assigns) do
    %{
      renderer: "casein_canvas",
      fixture: "synthetic_only",
      read_only: true
    }
  end
end
