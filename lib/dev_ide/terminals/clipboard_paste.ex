defmodule DevIDE.Terminals.ClipboardPaste do
  @moduledoc """
  Workspace-backed clipboard paste helpers for browser terminals.

  Text paste is delivered directly to the PTY. Clipboard images and dropped
  files cannot be typed into a terminal byte stream, so we save them as
  workspace files and paste the resulting path, matching the practical behavior
  users expect from drag/paste workflows in native terminals.
  """

  @max_file_bytes 25 * 1024 * 1024
  @clipboard_exclude ".devide/clipboard/"
  @image_extensions %{
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/jpg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/bmp" => ".bmp"
  }

  @type image_result :: %{
          path: String.t(),
          relative_path: String.t(),
          bytes: non_neg_integer(),
          content_type: String.t()
        }

  @spec save_image(String.t(), map()) :: {:ok, image_result()} | {:error, atom()}
  def save_image(root, attrs) when is_binary(root) and is_map(attrs) do
    type = attrs["type"] || attrs[:type]

    with {:ok, _ext} <- extension_for(type) do
      save_file(root, attrs)
    end
  end

  def save_image(_, _), do: {:error, :invalid_root}

  @spec save_file(String.t(), map()) :: {:ok, image_result()} | {:error, atom()}
  def save_file(root, attrs) when is_binary(root) and is_map(attrs) do
    type = attrs["type"] || attrs[:type] || "application/octet-stream"
    name = attrs["name"] || attrs[:name] || default_name(type)
    data = attrs["data"] || attrs[:data]

    with {:ok, binary} <- decode_data(data),
         :ok <- validate_size(binary),
         {:ok, path, rel} <- target_path(root, name, type),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, binary, [:binary]) do
      _ = ensure_clipboard_excluded(root)

      {:ok, %{path: path, relative_path: rel, bytes: byte_size(binary), content_type: type}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :write_failed}
      false -> {:error, :too_large}
      _ -> {:error, :invalid_file}
    end
  end

  def save_file(_, _), do: {:error, :invalid_root}

  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: @max_file_bytes

  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  defp default_name(type) when is_binary(type) do
    case extension_for(type) do
      {:ok, ext} -> "clipboard-file#{ext}"
      _ -> "clipboard-file"
    end
  end

  defp default_name(_), do: "clipboard-file"

  defp extension_for(type) when is_binary(type) do
    case Map.fetch(@image_extensions, String.downcase(type)) do
      {:ok, ext} -> {:ok, ext}
      :error -> {:error, :unsupported_type}
    end
  end

  defp extension_for(_), do: {:error, :unsupported_type}

  defp decode_data(data) when is_binary(data) do
    data
    |> strip_data_url()
    |> Base.decode64()
    |> case do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_data(_), do: {:error, :invalid_base64}

  defp strip_data_url("data:" <> _ = data) do
    case String.split(data, ",", parts: 2) do
      [_header, encoded] -> encoded
      _ -> data
    end
  end

  defp strip_data_url(data), do: data

  defp validate_size(binary) when byte_size(binary) <= @max_file_bytes, do: :ok
  defp validate_size(_), do: {:error, :too_large}

  defp target_path(root, name, type) do
    root = Path.expand(root)
    safe_name = safe_filename(name, type)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = System.unique_integer([:positive]) |> Integer.to_string(36)
    rel = Path.join([".devide", "clipboard", "#{stamp}-#{suffix}-#{safe_name}"])
    path = Path.expand(Path.join(root, rel))

    if String.starts_with?(path, root <> "/") do
      {:ok, path, rel}
    else
      {:error, :invalid_path}
    end
  end

  defp ensure_clipboard_excluded(root) do
    with {:ok, path, pattern} <- git_exclude(root),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, existing} <- read_or_empty(path),
         false <- exclude_present?(existing, pattern) do
      append_exclude(path, existing, pattern)
    else
      _ -> :ok
    end
  end

  defp git_exclude(root) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        with {:ok, path} <- git_output(git, root, ["rev-parse", "--git-path", "info/exclude"]),
             {:ok, prefix} <- git_output(git, root, ["rev-parse", "--show-prefix"]),
             false <- path == "" do
          {:ok, expand_git_path(root, path), prefix <> @clipboard_exclude}
        else
          _ -> {:error, :not_git}
        end
    end
  end

  defp git_output(git, root, args) do
    case System.cmd(git, ["-C", root | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:error, :not_git}
    end
  end

  defp expand_git_path(root, path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exclude_present?(body, pattern) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in [pattern, "/" <> pattern]))
  end

  defp append_exclude(path, existing, pattern) do
    prefix = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
    File.write(path, prefix <> pattern <> "\n", [:append])
  end

  defp safe_filename(name, type) when is_binary(name) do
    basename =
      name
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim(".-_")
      |> String.slice(0, 96)

    basename =
      case basename do
        "" -> default_name(type)
        value -> value
      end

    if Path.extname(basename) == "" do
      case extension_for(type) do
        {:ok, ext} -> basename <> ext
        _ -> basename
      end
    else
      basename
    end
  end

  defp safe_filename(_, type), do: default_name(type)
end
