defmodule TmuxCtl.Test.FakeRunner do
  @moduledoc false

  @behaviour TmuxCtl.Runner

  alias TmuxCtl.Test.FakeState

  @impl true
  def run(argv, _opts) when is_list(argv) do
    if pid = FakeState.get(:fake_tmux_runner_pid), do: send(pid, {:tmux_runner, argv})
    respond(argv)
  end

  def argv(argv, _opts), do: ["tmux" | argv]

  defp respond(argv) do
    cond do
      session_topology?(argv) ->
        {topology_output(Enum.at(argv, 2)), 0}

      match?(["list-windows", "-t", _, "-F", _], argv) ->
        {windows_output(Enum.at(argv, 2)), 0}

      match?(["list-panes", "-s", "-t", _, "-F", _], argv) ->
        {panes_output(Enum.at(argv, 3)), 0}

      match?(["resize-pane" | _], argv) ->
        {"", 0}

      match?(["resize-window" | _], argv) ->
        {"", 0}

      apply_defaults_batch?(argv) ->
        case FakeState.get(:fake_tmux_apply_defaults_code, 0) do
          0 -> {"", 0}
          code -> {"apply-defaults-failed", code}
        end

      match?(["set-option" | _], argv) ->
        apply_defaults_option_result(argv)

      match?(["set-window-option" | _], argv) ->
        {"", 0}

      match?(["bind-key" | _], argv) ->
        {"", 0}

      match?(["capture-pane" | _], argv) ->
        {FakeState.get(:fake_tmux_capture_output, "captured\n"), 0}

      true ->
        {"", 0}
    end
  end

  defp session_topology?(argv) do
    Enum.member?(argv, ";") and Enum.member?(argv, "list-windows") and
      Enum.member?(argv, "list-panes")
  end

  defp apply_defaults_batch?(argv) do
    Enum.member?(argv, ";") and Enum.member?(argv, "set-option")
  end

  defp apply_defaults_option_result(argv) do
    code = FakeState.get(:fake_tmux_apply_defaults_code, 0)

    if code != 0 and Enum.member?(argv, "mouse") do
      {"mouse-failed", code}
    else
      {"", 0}
    end
  end

  defp topology_output(session) do
    windows =
      session
      |> windows_for()
      |> Enum.map_join("\n", fn w -> "W|" <> window_line(w) end)

    windows <> "\n" <> panes_output(session, prefix: "P|")
  end

  defp windows_output(session) do
    session
    |> windows_for()
    |> Enum.map_join("\n", &window_line/1)
  end

  defp window_line(w) do
    "#{w.id}|#{w.index}|#{w.name}|#{active(w.active)}|#{w.panes}|#{w.activity}|#{w.current_command}"
  end

  defp panes_output(session, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")

    session
    |> panes_for()
    |> Enum.map_join("\n", fn p ->
      prefix <>
        "#{p.window_id}|#{p.id}|#{p.index}|#{active(p.active)}|#{p.left}|#{p.top}|#{p.width}|#{p.height}|#{p.current_command}|#{p.activity}|#{bell(p.bell)}|#{p.activity}|#{active(p.activity_flag)}|#{bell(p.bell)}|#{active(p.unseen_changes)}|#{p.current_path}|#{active(Map.get(p, :zoomed?, false))}"
    end)
  end

  defp windows_for(session) do
    FakeState.get(:fake_tmux_windows, %{}) |> Map.get(session, [])
  end

  defp panes_for(session) do
    FakeState.get(:fake_tmux_panes, %{}) |> Map.get(session, [])
  end

  defp active(true), do: "1"
  defp active(false), do: "0"
  defp active(nil), do: "0"

  defp bell(true), do: "1"
  defp bell(false), do: "0"
  defp bell(nil), do: "0"
end
