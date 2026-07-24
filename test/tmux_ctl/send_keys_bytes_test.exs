defmodule TmuxCtl.SendKeysBytesTest do
  use Casein.TestCase, async: false

  alias TmuxCtl.Client
  alias Casein.Test.Eventually

  @moduletag :tmux

  @expected_hex ~r/03 1b 78 1b 5b 41 1b 7a\s+0d 09/

  setup do
    if tmux_available?() do
      cwd = System.tmp_dir!()
      session = "devide_send_keys_bytes_#{System.unique_integer([:positive])}"

      on_exit(fn -> _ = Client.kill(session) end)

      assert :ok = Client.ensure_session(session, cwd)
      assert {:ok, pane_id} = first_pane_id(session)

      assert {"", 0} =
               Client.send_keys(
                 pane_id,
                 "stty raw -echo; dd bs=1 count=10 2>/dev/null | hexdump -C",
                 target: pane_id
               )

      assert {"", 0} = Client.send_keys(pane_id, "Enter", target: pane_id)

      Eventually.await(
        fn ->
          match?({:ok, out} when byte_size(out) > 0, Client.capture_recent(pane_id, 50))
        end,
        timeout_ms: 2000
      )

      {:ok, session: session, pane_id: pane_id}
    else
      {:ok, skip: :no_tmux}
    end
  end

  test "send_keys emits expected control-byte representation", ctx do
    if ctx[:skip] == :no_tmux do
      assert true
    else
      %{pane_id: pane_id} = ctx

      for key <- ["C-c", "M-x", "Up", "Escape", "z", "Enter", "Tab"] do
        assert {"", 0} = Client.send_keys(pane_id, key, target: pane_id)
      end

      assert {:ok, output} = poll_capture(pane_id, @expected_hex, 5_000)
      assert Regex.match?(@expected_hex, output)
    end
  end

  defp tmux_available? do
    case System.find_executable("tmux") do
      nil -> false
      tmux -> match?({_version, 0}, System.cmd(tmux, ["-V"], stderr_to_stdout: true))
    end
  end

  defp first_pane_id(session) do
    case Client.list_session_panes(session) do
      [%{id: pane_id} | _] -> {:ok, pane_id}
      [] -> {:error, :no_panes}
    end
  end

  defp poll_capture(pane_id, pattern, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_capture(pane_id, pattern, deadline)
  end

  defp do_poll_capture(pane_id, pattern, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        {:error, :timeout}

      true ->
        case Client.capture_recent(pane_id, 50) do
          {:ok, output} when is_binary(output) ->
            if Regex.match?(pattern, output) do
              {:ok, output}
            else
              receive do
              after
                min(remaining, 50) -> :ok
              end

              do_poll_capture(pane_id, pattern, deadline)
            end

          _ ->
            receive do
            after
              min(remaining, 50) -> :ok
            end

            do_poll_capture(pane_id, pattern, deadline)
        end
    end
  end
end
