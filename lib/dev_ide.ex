unless match?({:win32, _}, :os.type()) or System.get_env("DEV_IDE_NATIVE_WINDOWS") in ~w(1 true) do
  defmodule DevIde do
    @moduledoc """
    Boundary root for app infrastructure (`DevIde.*`): the OTP application,
    Repo, Mailer, and release tasks.

    `DevIde.Application` supervises both domain processes (`DevIDE.*`) and
    the web endpoint (`DevIdeWeb.*`), so this boundary may depend on both.
    The supervision subtree (`DevIde.Supervision`) also names preview-control
    (`PreviewCtl.*`) processes in its child specs, so this boundary lists
    `PreviewCtl` to make it reachable from that nested boundary.
    The domain itself lives under `DevIDE` (see `lib/dev_ide_domain.ex`).
    """

    use Boundary,
      deps: [DevIDE, DevIdeWeb, DevIde.Repo, PreviewCtl],
      exports: :all
  end
end
