defmodule DevIDEMix do
  @moduledoc """
  Boundary root for repository-local Mix tasks.

  Mix task modules must live under `Mix.Tasks`, so each task manually
  classifies itself into this uniquely named boundary. Keeping the boundary
  outside `Mix.Tasks` avoids case-insensitive BEAM filename collisions between
  command names such as `dev_ide` and `devide` on APFS and NTFS.
  """

  use Boundary,
    top_level?: true,
    deps: [DevIDE, DevIDE.Repo],
    exports: :all
end
