defmodule Ghostty.LiveTerminal do
  @moduledoc "Input encoding helpers for the native Windows compatibility terminal."

  def handle_text(_term, data) when is_binary(data), do: {:ok, data}

  def handle_key(_term, %{"key" => key} = params) do
    encoded =
      cond do
        params["metaKey"] == true -> :none
        params["ctrlKey"] == true -> encode_control_key(key)
        true -> encode_key(key)
      end

    if params["altKey"] == true and match?({:ok, _}, encoded) do
      {:ok, data} = encoded
      {:ok, "\e" <> data}
    else
      encoded
    end
  end

  def handle_key(_term, _params), do: :none

  defp encode_key(key) do
    case key do
      "Enter" -> {:ok, "\r"}
      "Backspace" -> {:ok, "\b"}
      "Tab" -> {:ok, "\t"}
      "Escape" -> {:ok, "\e"}
      "ArrowUp" -> {:ok, "\e[A"}
      "ArrowDown" -> {:ok, "\e[B"}
      "ArrowRight" -> {:ok, "\e[C"}
      "ArrowLeft" -> {:ok, "\e[D"}
      value when is_binary(value) and byte_size(value) == 1 -> {:ok, value}
      _ -> :none
    end
  end

  defp encode_control_key(key) when key in ["Control", "Shift", "Alt", "Meta"], do: :none
  defp encode_control_key(" "), do: {:ok, <<0>>}
  defp encode_control_key("["), do: {:ok, <<27>>}
  defp encode_control_key("\\"), do: {:ok, <<28>>}
  defp encode_control_key("]"), do: {:ok, <<29>>}
  defp encode_control_key("^"), do: {:ok, <<30>>}
  defp encode_control_key("_"), do: {:ok, <<31>>}

  defp encode_control_key(<<char>>) when char in ?a..?z,
    do: {:ok, <<char - ?a + 1>>}

  defp encode_control_key(<<char>>) when char in ?A..?Z,
    do: {:ok, <<char - ?A + 1>>}

  defp encode_control_key(key), do: encode_key(key)

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
