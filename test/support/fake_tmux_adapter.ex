defmodule TmuxCtl.Test.FakeAdapter do
  @moduledoc false

  @behaviour TmuxCtl.Adapter

  alias TmuxCtl.Test.FakeState

  def session_alive?("alive-session"), do: true
  def session_alive?("session-" <> _), do: true

  def session_alive?(session) do
    MapSet.member?(fake_alive_sessions(), session) or Map.has_key?(fake_windows(), session)
  end

  def create_session(execution_id, _opts), do: {:ok, "session-#{execution_id}"}

  def capture("alive-session"), do: {:ok, "captured pane\n"}
  def capture(_session), do: {:error, :session_not_alive}

  def attach_command(session), do: "tmux attach -t #{session}"

  def list_sessions do
    meta = FakeState.get(:fake_tmux_session_meta, %{})

    fake_windows()
    |> Enum.map(fn {session, windows} ->
      %{session: session, attached: false, activity: session_activity(windows)}
      |> Map.merge(Map.get(meta, session, %{}))
    end)
  end

  def send_keys(session, keys, opts \\ [])

  def send_keys("alive-session", keys, _opts) do
    send_to_test({:fake_tmux_keys, "alive-session", keys})
    :ok
  end

  def send_keys(_session, _keys, []), do: {:error, :session_not_alive}

  def send_keys(session, keys, opts) do
    target = Keyword.get(opts, :target, session)
    send_to_test({:fake_tmux_keys, session, target, keys, opts})
    :ok
  end

  def send_command(session, command, opts \\ [])

  def send_command(session, command, opts) do
    target = Keyword.get(opts, :target, session)
    send_to_test({:fake_tmux_send_command, session, target, command, opts})

    update_fake_panes(session, fn panes ->
      Enum.map(panes, fn pane ->
        if pane.id == target do
          %{pane | current_command: command}
        else
          pane
        end
      end)
    end)

    :ok
  end

  def attach(_session), do: {:ok, :fake}

  def session_topology(session) do
    {list_session_windows(session), list_session_panes(session)}
  end

  def list_windows, do: []

  def list_panes, do: []

  def kill(_session), do: :ok

  def apply_defaults(_session), do: :ok

  def set_environment(session, key, value) do
    send_to_test({:fake_tmux_set_environment, session, key, value})
    :ok
  end

  def set_environments(session, env) when is_map(env) do
    send_to_test({:fake_tmux_set_environments, session, env})
    :ok
  end

  def resize_window(_session, _cols, _rows), do: :ok

  def resize_amount_default, do: TmuxCtl.Client.resize_amount_default()

  def resize_amount_max, do: TmuxCtl.Client.resize_amount_max()

  def tail_lines(output, n), do: TmuxCtl.Client.tail_lines(output, n)

  def ensure_session(session, cwd) do
    send_to_test({:fake_tmux_ensure_session, session, cwd})
    :ok
  end

  def list_session_windows(session) do
    fake_windows()
    |> Map.get(session, [])
  end

  def list_session_panes(session) do
    fake_panes()
    |> Map.get(session, [])
    |> Enum.map(&pane_with_alert_defaults/1)
  end

  # Mirrors Tmux.directory_inventory/0: all windows and panes keyed by
  # session, in one "call". The fake state maps already have that shape.
  def directory_inventory do
    {:ok, %{windows: fake_windows(), panes: fake_panes()}}
  end

  def capture_scrollback(session, opts \\ []) do
    target = Keyword.get(opts, :target, session)
    Map.get(fake_scrollback(), {session, target}, Map.get(fake_scrollback(), target, ""))
  end

  def session_exists?(session), do: session_alive?(session)

  def new_window(session, opts \\ []) do
    id = Map.get(fake_next_window(), session, "@2")
    name = Keyword.get(opts, :name, "bash")
    send_to_test({:fake_tmux_new_window, session, opts})

    update_fake_windows(session, fn windows ->
      windows =
        Enum.map(windows, &Map.put(&1, :active, false)) ++
          [
            %{
              id: id,
              index: length(windows),
              name: name,
              active: true,
              panes: 1,
              activity: 0,
              current_command: "bash"
            }
          ]

      windows
    end)

    update_fake_panes(session, fn panes ->
      new_pane_id = next_pane_id(panes)

      Enum.map(panes, &Map.put(&1, :active, false)) ++
        [
          %{
            id: new_pane_id,
            window_id: id,
            index: 0,
            active: true,
            left: 0,
            top: 0,
            width: 120,
            height: 40,
            current_command: "bash",
            current_path: Keyword.get(opts, :cwd, "/workspace"),
            activity: 0,
            activity_flag: false,
            bell: false,
            unseen_changes: false
          }
        ]
    end)

    {:ok, id}
  end

  def select_window(session, window_id) do
    send_to_test({:fake_tmux_select_window, session, window_id})

    update_fake_windows(session, fn windows ->
      Enum.map(windows, &Map.put(&1, :active, &1.id == window_id))
    end)

    update_fake_panes(session, fn panes ->
      activate_first_pane_in_window(panes, window_id)
    end)

    :ok
  end

  def select_pane(session, pane_id) do
    send_to_test({:fake_tmux_select_pane, session, pane_id})

    update_fake_panes(session, fn panes ->
      Enum.map(panes, &Map.put(&1, :active, &1.id == pane_id))
    end)

    :ok
  end

  def navigate_pane(session, dir) do
    send_to_test({:fake_tmux_navigate_pane, session, dir})
    :ok
  end

  def zoom_pane(session, pane_id) do
    send_to_test({:fake_tmux_zoom_pane, session, pane_id})

    update_fake_panes(session, fn panes ->
      Enum.map(panes, fn pane ->
        if Map.get(pane, :id) == pane_id do
          Map.put(pane, :zoomed?, !Map.get(pane, :zoomed?, false))
        else
          pane
        end
      end)
    end)

    :ok
  end

  def ensure_zoomed(session, pane_id, desired?) when is_boolean(desired?) do
    actual? = pane_zoomed?(session, pane_id)

    cond do
      desired? == actual? ->
        :ok

      true ->
        zoom_pane(session, pane_id)
    end
  end

  def pane_zoomed?(session, pane_id) do
    fake_panes()
    |> Map.get(session, [])
    |> Enum.find_value(false, fn pane ->
      if pane.id == pane_id, do: Map.get(pane, :zoomed?, false)
    end)
  end

  def kill_other_panes(session, pane_id) do
    panes = Map.get(fake_panes(), session, [])

    case Enum.find(panes, &(&1.id == pane_id)) do
      nil ->
        {:error, :pane_not_found}

      %{window_id: window_id} ->
        send_to_test({:fake_tmux_kill_other_panes, session, pane_id})

        update_fake_panes(session, fn panes ->
          panes
          |> Enum.reject(&(&1.window_id == window_id and &1.id != pane_id))
          |> Enum.map(fn pane ->
            if pane.id == pane_id, do: %{pane | active: true}, else: pane
          end)
        end)

        update_fake_windows(session, fn windows ->
          Enum.map(windows, fn window ->
            if window.id == window_id, do: %{window | panes: 1}, else: window
          end)
        end)

        :ok
    end
  end

  def select_layout(session, layout) do
    send_to_test({:fake_tmux_select_layout, session, layout})
    :ok
  end

  def next_layout(session) do
    send_to_test({:fake_tmux_next_layout, session})
    :ok
  end

  def cycle_window(session, dir) when dir in ["next", "prev"] do
    send_to_test({:fake_tmux_cycle_window, session, dir})

    update_fake_windows(session, fn windows ->
      active_idx = Enum.find_index(windows, & &1.active) || 0
      count = length(windows)

      next_idx =
        if dir == "next",
          do: rem(active_idx + 1, count),
          else: rem(active_idx - 1 + count, count)

      Enum.with_index(windows, fn w, i -> Map.put(w, :active, i == next_idx) end)
    end)

    :ok
  end

  def rename_window(session, window_id, name) do
    send_to_test({:fake_tmux_rename_window, session, window_id, name})

    update_fake_windows(session, fn windows ->
      Enum.map(windows, fn window ->
        if window.id == window_id, do: %{window | name: name}, else: window
      end)
    end)

    :ok
  end

  def kill_window(session, window_id) do
    send_to_test({:fake_tmux_kill_window, session, window_id})

    update_fake_windows(session, fn windows ->
      remaining = Enum.reject(windows, &(&1.id == window_id))

      if Enum.any?(remaining, & &1.active) do
        remaining
      else
        case remaining do
          [first | rest] -> [%{first | active: true} | rest]
          [] -> []
        end
      end
    end)

    :ok
  end

  def kill_pane(session, pane_id) do
    panes = Map.get(fake_panes(), session, [])

    with %{window_id: window_id} = pane <- Enum.find(panes, &(&1.id == pane_id)),
         window_panes = Enum.filter(panes, &(&1.window_id == window_id)),
         true <- length(window_panes) > 1 do
      send_to_test({:fake_tmux_kill_pane, session, pane_id})

      update_fake_panes(session, fn panes ->
        remaining = Enum.reject(panes, &(&1.id == pane_id))

        if pane.active do
          activate_first_pane_in_window(remaining, window_id)
        else
          remaining
        end
      end)

      update_fake_windows(session, fn windows ->
        Enum.map(windows, fn window ->
          if window.id == window_id do
            %{window | panes: max(window.panes - 1, 1)}
          else
            window
          end
        end)
      end)

      :ok
    else
      false -> {:error, :last_pane}
      nil -> {:error, :pane_not_found}
    end
  end

  def split_pane(session, pane_id, direction, opts \\ [])

  def split_pane(session, pane_id, direction, opts) when direction in ["h", "v"] do
    panes = Map.get(fake_panes(), session, [])

    case Enum.find(panes, &(&1.id == pane_id)) do
      nil ->
        {:error, :pane_not_found}

      pane ->
        new_id = next_pane_id(panes)
        send_to_test({:fake_tmux_split_pane, session, pane_id, direction, new_id})

        update_fake_panes(session, fn panes ->
          {target, new_pane} = split_fake_pane(pane, new_id, direction)

          new_pane =
            new_pane
            |> maybe_put_split_cwd(Keyword.get(opts, :cwd))
            |> maybe_put_split_command(Keyword.get(opts, :command))

          panes
          |> Enum.map(fn existing ->
            cond do
              existing.id == pane_id -> target
              existing.window_id == pane.window_id -> %{existing | active: false}
              true -> existing
            end
          end)
          |> Kernel.++([new_pane])
          |> Enum.sort_by(& &1.index)
        end)

        update_fake_windows(session, fn windows ->
          Enum.map(windows, fn window ->
            if window.id == pane.window_id do
              %{window | panes: window.panes + 1}
            else
              window
            end
          end)
        end)

        {:ok, new_id}
    end
  end

  def resize_pane(session, pane_id, direction, amount \\ nil)

  def resize_pane(session, pane_id, direction, amount)
      when direction in ["left", "right", "up", "down"] do
    with {:ok, amount} <- normalize_resize_amount(amount) do
      panes = Map.get(fake_panes(), session, [])

      case Enum.find(panes, &(&1.id == pane_id)) do
        nil ->
          {:error, :pane_not_found}

        pane ->
          send_to_test({:fake_tmux_resize_pane, session, pane_id, direction, amount})

          update_fake_panes(session, fn panes ->
            resize_fake_panes(panes, pane, direction, amount)
          end)

          :ok
      end
    end
  end

  def resize_pane(_session, _pane_id, _direction, _amount), do: {:error, :invalid_resize}

  defp maybe_put_split_cwd(pane, cwd) when is_binary(cwd) and cwd != "",
    do: %{pane | current_path: cwd}

  defp maybe_put_split_cwd(pane, _cwd), do: pane

  defp maybe_put_split_command(pane, command) when is_binary(command),
    do: %{pane | current_command: command}

  defp maybe_put_split_command(pane, _), do: pane

  defp normalize_resize_amount(nil), do: {:ok, TmuxCtl.Client.resize_amount_default()}

  defp normalize_resize_amount(amount) when is_integer(amount) and amount > 0 do
    if amount <= TmuxCtl.Client.resize_amount_max() do
      {:ok, amount}
    else
      {:error, :invalid_amount}
    end
  end

  defp normalize_resize_amount(_), do: {:error, :invalid_amount}

  defp send_to_test(message) do
    if pid = FakeState.get(:fake_tmux_test_pid) do
      send(pid, message)
    end

    :ok
  end

  defp fake_windows do
    FakeState.get(:fake_tmux_windows, %{})
  end

  defp fake_alive_sessions do
    FakeState.get(:fake_tmux_alive_sessions, MapSet.new()) |> MapSet.new()
  end

  defp fake_panes do
    FakeState.get(:fake_tmux_panes, %{})
  end

  defp fake_next_window do
    FakeState.get(:fake_tmux_next_window, %{})
  end

  defp fake_scrollback do
    FakeState.get(:fake_tmux_scrollback, %{})
  end

  defp session_activity(windows) when is_list(windows) do
    windows
    |> Enum.map(&(Map.get(&1, :activity) || Map.get(&1, "activity") || 0))
    |> Enum.map(&activity_value/1)
    |> Enum.max(fn -> 0 end)
  end

  defp session_activity(_), do: 0

  defp activity_value(value) when is_integer(value), do: value

  defp activity_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> 0
    end
  end

  defp activity_value(_), do: 0

  defp pane_with_alert_defaults(pane) do
    Map.merge(
      %{
        activity: 0,
        activity_flag: false,
        bell: false,
        unseen_changes: false,
        zoomed?: false
      },
      pane
    )
  end

  defp update_fake_windows(session, fun) do
    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.update(windows, session, fun.([]), fun)
    end)
  end

  defp update_fake_panes(session, fun) do
    FakeState.update(:fake_tmux_panes, %{}, fn panes ->
      Map.update(panes, session, fun.([]), fun)
    end)
  end

  defp activate_first_pane_in_window(panes, window_id) do
    case Enum.find(panes, &(&1.window_id == window_id)) do
      nil ->
        panes

      first ->
        Enum.map(panes, fn pane ->
          if pane.window_id == window_id do
            %{pane | active: pane.id == first.id}
          else
            pane
          end
        end)
    end
  end

  defp next_pane_id(panes) do
    next =
      panes
      |> Enum.map(&pane_number/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    "%#{next}"
  end

  defp pane_number(%{id: "%" <> number}) do
    case Integer.parse(number) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp pane_number(_), do: 0

  defp split_fake_pane(pane, new_id, "h") do
    target_width = max(div(pane.width, 2), 1)
    new_width = max(pane.width - target_width, 1)

    target = %{pane | active: false, width: target_width}

    new_pane = %{
      pane
      | id: new_id,
        index: pane.index + 1,
        active: true,
        left: pane.left + target_width,
        width: new_width,
        current_command: "bash"
    }

    {target, new_pane}
  end

  defp split_fake_pane(pane, new_id, "v") do
    target_height = max(div(pane.height, 2), 1)
    new_height = max(pane.height - target_height, 1)

    target = %{pane | active: false, height: target_height}

    new_pane = %{
      pane
      | id: new_id,
        index: pane.index + 1,
        active: true,
        top: pane.top + target_height,
        height: new_height,
        current_command: "bash"
    }

    {target, new_pane}
  end

  defp resize_fake_panes(panes, target, direction, amount) do
    neighbor = resize_neighbor(panes, target, direction)
    delta = resize_delta(neighbor, amount, resize_axis(direction))

    Enum.map(panes, fn pane ->
      cond do
        pane.id == target.id -> resize_target(pane, direction, delta)
        neighbor && pane.id == neighbor.id -> resize_neighbor_pane(pane, direction, delta)
        true -> pane
      end
    end)
  end

  defp resize_neighbor(panes, target, "right") do
    Enum.find(panes, fn pane ->
      pane.window_id == target.window_id and pane.left == target.left + target.width and
        ranges_overlap?(pane.top, pane.height, target.top, target.height)
    end)
  end

  defp resize_neighbor(panes, target, "left") do
    Enum.find(panes, fn pane ->
      pane.window_id == target.window_id and pane.left + pane.width == target.left and
        ranges_overlap?(pane.top, pane.height, target.top, target.height)
    end)
  end

  defp resize_neighbor(panes, target, "down") do
    Enum.find(panes, fn pane ->
      pane.window_id == target.window_id and pane.top == target.top + target.height and
        ranges_overlap?(pane.left, pane.width, target.left, target.width)
    end)
  end

  defp resize_neighbor(panes, target, "up") do
    Enum.find(panes, fn pane ->
      pane.window_id == target.window_id and pane.top + pane.height == target.top and
        ranges_overlap?(pane.left, pane.width, target.left, target.width)
    end)
  end

  defp resize_axis("left"), do: :width
  defp resize_axis("right"), do: :width
  defp resize_axis("up"), do: :height
  defp resize_axis("down"), do: :height

  defp resize_delta(nil, _amount, _axis), do: 0

  defp resize_delta(neighbor, amount, axis) do
    neighbor
    |> Map.fetch!(axis)
    |> Kernel.-(1)
    |> min(amount)
    |> max(0)
  end

  defp resize_target(pane, _direction, 0), do: pane
  defp resize_target(pane, "right", delta), do: %{pane | width: pane.width + delta}
  defp resize_target(pane, "down", delta), do: %{pane | height: pane.height + delta}

  defp resize_target(pane, "left", delta),
    do: %{pane | left: pane.left - delta, width: pane.width + delta}

  defp resize_target(pane, "up", delta),
    do: %{pane | top: pane.top - delta, height: pane.height + delta}

  defp resize_neighbor_pane(pane, _direction, 0), do: pane

  defp resize_neighbor_pane(pane, "right", delta),
    do: %{pane | left: pane.left + delta, width: pane.width - delta}

  defp resize_neighbor_pane(pane, "down", delta),
    do: %{pane | top: pane.top + delta, height: pane.height - delta}

  defp resize_neighbor_pane(pane, "left", delta), do: %{pane | width: pane.width - delta}
  defp resize_neighbor_pane(pane, "up", delta), do: %{pane | height: pane.height - delta}

  defp ranges_overlap?(start_a, size_a, start_b, size_b) do
    start_a < start_b + size_b and start_b < start_a + size_a
  end
end

defmodule DevIDE.Test.FakeTmuxAdapter do
  @moduledoc false

  @behaviour TmuxCtl.Adapter

  defdelegate session_alive?(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate create_session(execution_id, opts), to: TmuxCtl.Test.FakeAdapter
  defdelegate capture(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate attach_command(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate list_sessions(), to: TmuxCtl.Test.FakeAdapter
  defdelegate send_keys(session, keys), to: TmuxCtl.Test.FakeAdapter
  defdelegate send_keys(session, keys, opts), to: TmuxCtl.Test.FakeAdapter
  defdelegate send_command(session, command), to: TmuxCtl.Test.FakeAdapter
  defdelegate send_command(session, command, opts), to: TmuxCtl.Test.FakeAdapter
  defdelegate ensure_session(session, cwd), to: TmuxCtl.Test.FakeAdapter
  defdelegate attach(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate list_session_windows(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate list_session_panes(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate session_topology(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate directory_inventory(), to: TmuxCtl.Test.FakeAdapter
  defdelegate capture_scrollback(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate capture_scrollback(session, opts), to: TmuxCtl.Test.FakeAdapter
  defdelegate session_exists?(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate new_window(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate new_window(session, opts), to: TmuxCtl.Test.FakeAdapter
  defdelegate select_window(session, window_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate select_pane(session, pane_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate navigate_pane(session, dir), to: TmuxCtl.Test.FakeAdapter
  defdelegate zoom_pane(session, pane_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate ensure_zoomed(session, pane_id, desired?), to: TmuxCtl.Test.FakeAdapter
  defdelegate pane_zoomed?(session, pane_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate kill_other_panes(session, pane_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate select_layout(session, layout), to: TmuxCtl.Test.FakeAdapter
  defdelegate next_layout(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate cycle_window(session, dir), to: TmuxCtl.Test.FakeAdapter
  defdelegate rename_window(session, window_id, name), to: TmuxCtl.Test.FakeAdapter
  defdelegate kill_window(session, window_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate kill_pane(session, pane_id), to: TmuxCtl.Test.FakeAdapter
  defdelegate split_pane(session, pane_id, direction), to: TmuxCtl.Test.FakeAdapter
  defdelegate split_pane(session, pane_id, direction, opts), to: TmuxCtl.Test.FakeAdapter
  defdelegate resize_pane(session, pane_id, direction), to: TmuxCtl.Test.FakeAdapter
  defdelegate resize_pane(session, pane_id, direction, amount), to: TmuxCtl.Test.FakeAdapter
  defdelegate resize_amount_default(), to: TmuxCtl.Test.FakeAdapter
  defdelegate resize_amount_max(), to: TmuxCtl.Test.FakeAdapter
  defdelegate list_windows(), to: TmuxCtl.Test.FakeAdapter
  defdelegate list_panes(), to: TmuxCtl.Test.FakeAdapter
  defdelegate kill(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate apply_defaults(session), to: TmuxCtl.Test.FakeAdapter
  defdelegate set_environment(session, key, value), to: TmuxCtl.Test.FakeAdapter
  defdelegate set_environments(session, env), to: TmuxCtl.Test.FakeAdapter
  defdelegate resize_window(session, cols, rows), to: TmuxCtl.Test.FakeAdapter
  defdelegate tail_lines(output, n), to: TmuxCtl.Test.FakeAdapter
end
