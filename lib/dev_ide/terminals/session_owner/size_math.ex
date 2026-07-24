defmodule DevIDE.Terminals.SessionOwner.SizeMath do
  @moduledoc false

  # No viewer is focused: pick the LARGEST viewport by area, so the shared grid is
  # a real shape some viewer actually requested rather than an independent per-axis
  # max (which could synthesize a {cols, rows} nobody asked for).
  def largest_size(sizes) do
    Enum.max_by(sizes, fn {cols, rows} -> {cols * rows, cols} end)
  end
end
