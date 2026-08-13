defmodule CaseinWeb.WorkspaceLive.Show.PickerLabel do
  @moduledoc false

  # #949 constraint: generated identifiers put their entropy in the suffix
  # (timestamps, worker slugs, NOOP). Middle-truncate those so both ends stay
  # visible. Human prose keeps tail-truncate (this helper returns it unchanged).
  # Presentation only — never rename the underlying session/window/worktree.
  # Search, `title`, and `data-picker-label` must keep the full string.

  @default_max 24
  @min_prefix 8

  @doc """
  True for Casein-generated attach ids, worker window names, agent worktree
  dirs, and tmux session names. Human titles stay false.
  """
  def generated_id?(value) when is_binary(value) do
    value = String.trim(value)

    value != "" and
      (String.contains?(value, "CASEIN_") or
         String.contains?(value, "agent-worktrees") or
         String.match?(value, ~r/^worker[-_]/) or
         String.match?(value, ~r{(^|/)agent-(grok|claude|codex|opencode|agent)-}) or
         String.match?(value, ~r/^[0-9a-f]{8,}(-[0-9a-f]{4,})+/i) or
         String.match?(value, ~r/_NOOP\b/) or
         String.match?(value, ~r/^phx-/i) or
         String.match?(value, ~r/^casein_[a-z0-9._-]+_/i))
  end

  def generated_id?(_), do: false

  @doc """
  Shorten a single label for display. Generated ids are middle-truncated;
  human labels are returned unchanged so CSS `truncate` can tail-clip them.
  """
  def display(value, opts \\ [])

  def display(value, opts) when is_binary(value) do
    max = Keyword.get(opts, :max, @default_max)

    if generated_id?(value) do
      middle_truncate(value, max)
    else
      value
    end
  end

  def display(value, _opts), do: value

  @doc """
  Per-group display forms. Elides the common prefix of generated ids in this
  group (not globally), then middle-truncates the remainder. Human labels pass
  through. Order is preserved; the full strings are not mutated.
  """
  def display_group(values, opts \\ []) when is_list(values) do
    max = Keyword.get(opts, :max, @default_max)
    prefix = common_generated_prefix(values)

    Enum.map(values, fn value ->
      cond do
        not is_binary(value) ->
          value

        not generated_id?(value) ->
          value

        prefix == "" ->
          middle_truncate(value, max)

        String.starts_with?(value, prefix) ->
          remainder = String.replace_prefix(value, prefix, "")
          "…" <> middle_truncate(remainder, max)

        true ->
          middle_truncate(value, max)
      end
    end)
  end

  @doc """
  Attach `:display_label` / `:display_detail` on each item without changing
  `:label` / `:detail`. Nested `:session` maps are annotated the same way.
  """
  def annotate_group(items, opts \\ []) when is_list(items) do
    labels = Enum.map(items, &item_label/1)
    details = Enum.map(items, &item_detail/1)

    Enum.zip_with([items, display_group(labels, opts), display_group(details, opts)], fn
      [item, display_label, display_detail] ->
        item
        |> Map.put(:display_label, display_label)
        |> Map.put(:display_detail, display_detail)
        |> annotate_nested_session(opts)
    end)
  end

  @doc false
  def middle_truncate(value, max \\ @default_max)

  def middle_truncate(value, max) when is_binary(value) and is_integer(max) and max < 5 do
    value |> String.graphemes() |> Enum.take(max) |> Enum.join()
  end

  def middle_truncate(value, max) when is_binary(value) and is_integer(max) do
    graphemes = String.graphemes(value)

    if length(graphemes) <= max do
      value
    else
      keep = max - 1
      head = div(keep, 2)
      tail = keep - head

      Enum.join(Enum.take(graphemes, head) ++ ["…"] ++ Enum.take(graphemes, -tail))
    end
  end

  def middle_truncate(value, _max), do: value

  defp annotate_nested_session(%{session: session} = item, opts) when is_map(session) do
    [annotated] = annotate_group([session], opts)
    Map.put(item, :session, annotated)
  end

  defp annotate_nested_session(item, _opts), do: item

  defp item_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp item_label(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp item_label(%{session: %{label: label}}) when is_binary(label), do: label
  defp item_label(_), do: ""

  defp item_detail(%{detail: detail}) when is_binary(detail), do: detail
  defp item_detail(%{session: %{detail: detail}}) when is_binary(detail), do: detail
  defp item_detail(_), do: ""

  defp common_generated_prefix(values) do
    generated =
      values
      |> Enum.filter(&generated_id?/1)
      |> Enum.map(&String.trim/1)

    case generated do
      [] ->
        ""

      [_] ->
        ""

      [first | rest] ->
        prefix =
          Enum.reduce(rest, first, fn other, acc ->
            lcp(acc, other)
          end)

        prefix
        |> snap_prefix_boundary()
        |> usable_prefix?(generated)
    end
  end

  defp lcp(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join("", &elem(&1, 0))
  end

  defp snap_prefix_boundary(prefix) do
    case Regex.run(~r/^(.*[-_\/])/, prefix) do
      [_, snapped] -> snapped
      _ -> prefix
    end
  end

  defp usable_prefix?(prefix, generated)
       when is_binary(prefix) and byte_size(prefix) >= @min_prefix do
    if Enum.all?(generated, &(String.starts_with?(&1, prefix) and &1 != prefix)) do
      prefix
    else
      ""
    end
  end

  defp usable_prefix?(_prefix, _generated), do: ""
end
