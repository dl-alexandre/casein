defmodule Ghostty.LiveTerminal do
  @moduledoc "Input encoding helpers for the native Windows compatibility terminal."

  def handle_text(_term, data) when is_binary(data), do: {:ok, data}

  def handle_key(_term, %{"key" => key}) do
    case key do
      "Enter" -> {:ok, "\r"}
      "Backspace" -> {:ok, "\b"}
      "Tab" -> {:ok, "\t"}
      "Escape" -> {:ok, "\e"}
      "ArrowUp" -> {:ok, "\e[A"}
      "ArrowDown" -> {:ok, "\e[B"}
      "ArrowRight" -> {:ok, "\e[C"}
      "ArrowLeft" -> {:ok, "\e[D"}
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :none
    end
  end

  def handle_key(_term, _params), do: :none
  def handle_mouse(_term, %{"encoded" => data}) when is_binary(data), do: {:ok, data}
  def handle_mouse(_term, _params), do: :none

  def handle_resize(term, cols, rows, pty \\ nil) do
    :ok = Ghostty.Terminal.resize(term, cols, rows)
    if pty, do: Ghostty.PTY.resize(pty, cols, rows)
    :ok
  end

  def handle_focus(focused) when is_boolean(focused) do
    if Application.get_env(:ghostty, :focus_reporting, true) do
      {:ok, if(focused, do: "\e[I", else: "\e[O")}
    else
      :none
    end
  end
end
