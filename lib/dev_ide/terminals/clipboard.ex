defmodule DevIDE.Terminals.Clipboard do
  @moduledoc false

  alias DevIDE.Terminals.ClipboardPaste

  @doc "Saves a clipboard image payload under a workspace root."
  @spec save_clipboard_image(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def save_clipboard_image(root, params) do
    ClipboardPaste.save_image(root, params)
  end

  @doc "Saves a clipboard file payload under a workspace root."
  @spec save_clipboard_file(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def save_clipboard_file(root, params) do
    ClipboardPaste.save_file(root, params)
  end

  @doc "Maximum allowed clipboard paste file size in bytes."
  @spec clipboard_max_file_bytes() :: pos_integer()
  def clipboard_max_file_bytes do
    ClipboardPaste.max_file_bytes()
  end
end
