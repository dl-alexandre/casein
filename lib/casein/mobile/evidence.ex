defmodule Casein.Mobile.Evidence do
  @moduledoc """
  Bounded, read-only evidence projected from an authoritative mobile card.

  Cards remain the source of truth. This module only validates and compresses
  evidence already attached to a card, and it fails closed when the workspace,
  path, artifact, or viewer cannot be re-authorized.
  """

  alias Casein.Export.Sanitizer
  alias Casein.Files.PathSafety
  alias Casein.Mobile.ResumeCard
  alias Casein.Origin
  alias Casein.Previews
  alias Casein.Workspaces

  @version 1
  @max_files 8
  @max_path_bytes 240
  @max_diff_lines 24
  @max_diff_bytes 4_096

  @spec project(map(), map()) :: map() | nil
  def project(card, viewer) when is_map(card) and is_map(viewer) do
    with workspace_id when is_binary(workspace_id) <- value(card, :workspace_id),
         {:ok, workspace} <- Workspaces.get(workspace_id),
         true <- Workspaces.viewer_terminal_owner?(workspace, viewer),
         {:ok, {:local, root}} <- Workspaces.safe_host_loc(workspace) do
      changed_files = changed_files(card, root)
      diff = diff_excerpt(card)
      artifact = artifact(card, workspace_id)

      if changed_files.files == [] and is_nil(diff) and is_nil(artifact) do
        nil
      else
        resume = ResumeCard.project(card)

        %{
          version: @version,
          origin: Origin.public_descriptor(),
          freshness: %{kind: "live", observed_at: value(card, :updated_at)},
          changed_files: changed_files,
          diff: diff,
          artifact: artifact,
          links: links(card, resume.locator, changed_files, diff, artifact)
        }
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def project(_card, _viewer), do: nil

  defp changed_files(card, root) do
    candidates =
      card
      |> evidence_value(:files_changed)
      |> case do
        values when is_list(values) -> values
        _ -> []
      end

    valid =
      candidates
      |> Enum.map(&path_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&workspace_path?(&1, root))

    files = Enum.take(valid, @max_files)

    %{
      count: length(files),
      files: files,
      truncated: length(valid) > length(files)
    }
  end

  defp path_text(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" -> nil
      byte_size(path) > @max_path_bytes -> nil
      not String.valid?(path) -> nil
      Regex.match?(~r/[\x00-\x1F\x7F]/u, path) -> nil
      PathSafety.ignored?(path) -> nil
      true -> path
    end
  end

  defp path_text(%{} = item), do: path_text(value(item, :path))
  defp path_text(_path), do: nil

  defp workspace_path?(path, root) do
    case PathSafety.resolve(root, path) do
      {:ok, resolved} ->
        relative = Path.relative_to(resolved, Path.expand(root))
        relative not in ["", "."] and not String.starts_with?(relative, "..")

      _ ->
        false
    end
  end

  defp diff_excerpt(card) do
    case evidence_value(card, :diff_preview) do
      value when is_binary(value) and value != "" ->
        sanitized = sanitize_text(value)

        bounded_lines =
          sanitized
          |> String.split("\n")
          |> Enum.take(@max_diff_lines)
          |> Enum.join("\n")

        excerpt = cap_utf8_bytes(bounded_lines, @max_diff_bytes)

        if excerpt == "" do
          nil
        else
          %{
            excerpt: excerpt,
            truncated:
              length(String.split(sanitized, "\n")) > @max_diff_lines or
                byte_size(bounded_lines) > @max_diff_bytes
          }
        end

      _ ->
        nil
    end
  end

  defp sanitize_text(value) do
    value
    |> Sanitizer.redact_text()
    |> String.replace(
      ~r/(["']?(?:token|password|secret|api[_-]?key|authorization)["']?\s*:\s*)["'][^"']*["']/i,
      "\\1\"[REDACTED]\""
    )
    |> String.replace(
      ~r/\b(token|password|secret|api[_-]?key|authorization)\b(\s*[:=]\s*)[^\s,]+/i,
      "\\1\\2[REDACTED]"
    )
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "�")
    |> String.trim()
  end

  defp cap_utf8_bytes(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp cap_utf8_bytes(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> trim_to_bytes(max_bytes)
  end

  defp trim_to_bytes("", _max_bytes), do: ""

  defp trim_to_bytes(value, max_bytes) do
    if String.valid?(value) do
      value
    else
      value |> binary_part(0, byte_size(value) - 1) |> trim_to_bytes(max_bytes)
    end
  end

  defp artifact(card, workspace_id) do
    with raw when is_binary(raw) <- locator_value(card, :artifact),
         {:ok, filename, public_path} <- preview_artifact(raw, workspace_id),
         path <- Previews.safe_artifact_path!(workspace_id, filename),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular do
      %{
        kind: "preview_artifact",
        filename: filename,
        media_type: media_type(filename),
        byte_size: stat.size,
        pwa_path: public_path
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp preview_artifact(raw, workspace_id) do
    path = URI.parse(raw).path || raw

    case String.split(path, "/", trim: true) do
      ["preview-artifacts", ^workspace_id, encoded_filename] ->
        filename = URI.decode(encoded_filename)

        if filename == Path.basename(filename) and
             filename not in ["", ".", ".."] and
             not String.contains?(filename, ["/", "\\", ".."]) do
          {:ok, filename, "/preview-artifacts/#{workspace_id}/#{URI.encode(filename)}"}
        else
          {:error, :invalid_artifact}
        end

      _ ->
        {:error, :artifact_scope_mismatch}
    end
  end

  defp links(card, locator, changed_files, diff, artifact) do
    []
    |> maybe_link(
      not is_nil(diff) or changed_files.files != [],
      "diff",
      "Open full diff in PWA",
      workspace_url(card, locator, "diff")
    )
    |> maybe_link(
      not is_nil(artifact),
      "preview",
      "Open preview in PWA",
      artifact && artifact.pwa_path
    )
    |> maybe_link(
      not is_nil(artifact),
      "artifacts",
      "Open artifacts in PWA",
      workspace_url(card, locator, "artifacts", artifact)
    )
  end

  defp maybe_link(links, true, kind, label, path) when is_binary(path) do
    links ++ [%{kind: kind, label: label, path: path}]
  end

  defp maybe_link(links, _include?, _kind, _label, _path), do: links

  defp workspace_url(card, locator, tab, artifact \\ nil) do
    workspace_id = value(card, :workspace_id)

    query =
      %{
        "session" => value(locator, :session_id) || value(card, :session_id),
        "tmux_session" => value(locator, :tmux_session),
        "window" => value(locator, :window),
        "pane" => value(locator, :pane),
        "tab" => tab,
        "artifact" => artifact && artifact.filename
      }
      |> Enum.reject(fn {_key, nested} -> not present?(nested) end)
      |> URI.encode_query()

    "/workspaces/" <> URI.encode_www_form(workspace_id) <> "?" <> query
  end

  defp media_type(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      _ -> "application/octet-stream"
    end
  end

  defp evidence_value(card, key) do
    value(value(card, :context) || %{}, key) ||
      value(value(card, :meta) || %{}, key)
  end

  defp locator_value(card, key) do
    card
    |> value(:context)
    |> value(:locator)
    |> value(key)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nested} -> nested
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
