defmodule Scripts.TmuxLabelDisciplineTest do
  @moduledoc """
  Labeled-tmux discipline for the #248 product-script slice.

  Live servers often run as `-L devide` with the socket renamed to `casein`.
  Bare `tmux list-|kill-|send-|…` hits the wrong server. Converted product
  scripts must source `scripts/lib/tmux-label.sh` and route ops through
  `casein_tmux` (or an explicit `tmux -L`).
  """
  use ExUnit.Case, async: true

  @helper Path.expand("../../scripts/lib/tmux-label.sh", __DIR__)

  @converted [
    "scripts/spawn-agent-worker.sh",
    "scripts/smoke-spawn-agent-worker.sh",
    "scripts/workspace-doctor.sh",
    "scripts/refresh-tmux-pane-env.sh",
    "scripts/lib/repair-tmux-env.sh"
  ]

  # Operational subcommands that must not be bare on the converted set.
  @ops ~w(
    list-sessions list-panes list-windows
    kill-window kill-pane kill-session
    send-keys capture-pane display-message
    has-session new-window new-session
    rename-window set-environment show-environment
    select-pane set-option
  )

  test "tmux-label helper has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @helper])
  end

  test "casein_tmux_label resolves env and defaults to casein" do
    script = """
    set -euo pipefail
    source "#{@helper}"
    unset CASEIN_TMUX_LABEL CASEIN_TMUX_SOCKET_LABEL
    printf 'default=%s\\n' "$(casein_tmux_label)"
    CASEIN_TMUX_LABEL=devide
    printf 'label=%s\\n' "$(casein_tmux_label)"
    unset CASEIN_TMUX_LABEL
    CASEIN_TMUX_SOCKET_LABEL=casein_dev
    printf 'sock=%s\\n' "$(casein_tmux_label)"
    """

    {out, 0} = System.cmd("bash", ["-lc", script])
    assert out =~ "default=casein"
    assert out =~ "label=devide"
    assert out =~ "sock=casein_dev"
  end

  test "casein_tmux always passes -L <label> before the subcommand" do
    tmp = Path.join(System.tmp_dir!(), "tmux-label-#{System.unique_integer([:positive])}")
    fakebin = Path.join(tmp, "bin")
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(fakebin, "tmux"), """
    #!/usr/bin/env bash
    printf '%s\\n' "$*"
    """)

    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    script = """
    set -euo pipefail
    export PATH=#{fakebin}:$PATH
    source "#{@helper}"
    CASEIN_TMUX_LABEL=devide casein_tmux list-sessions -F '%s'
    """

    {out, 0} = System.cmd("bash", ["-lc", script])
    assert String.trim(out) == "-L devide list-sessions -F %s"
  end

  test "converted product scripts source tmux-label.sh" do
    for rel <- @converted do
      path = Path.expand("../../#{rel}", __DIR__)
      body = File.read!(path)
      assert body =~ "scripts/lib/tmux-label.sh", "#{rel} must source tmux-label.sh"
      assert body =~ ~r/\bcasein_tmux\b/, "#{rel} must call casein_tmux"
    end
  end

  test "converted product scripts have no bare operational tmux" do
    ops_alt = Enum.join(@ops, "|")
    bare = ~r/(^|[^\w.-])tmux\s+(#{ops_alt})\b/

    for rel <- @converted do
      path = Path.expand("../../#{rel}", __DIR__)
      body = File.read!(path)

      bare_hits =
        body
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          stripped = String.trim_leading(line)

          cond do
            String.starts_with?(stripped, "#") -> false
            # Quoted / message text mentioning "tmux new-window", not a call.
            String.contains?(line, "echo ") or String.contains?(line, "printf ") -> false
            String.contains?(line, "command -v tmux") -> false
            String.contains?(line, "tmux -L") -> false
            String.contains?(line, "tmux -S") -> false
            String.contains?(line, "casein_tmux") -> false
            true -> Regex.match?(bare, line)
          end
        end)

      assert bare_hits == [], """
      bare operational tmux in #{rel}:
      #{Enum.map_join(bare_hits, "\n", fn {line, n} -> "  #{n}: #{line}" end)}
      """
    end
  end

  test "converted product scripts have valid shell syntax" do
    for rel <- @converted do
      path = Path.expand("../../#{rel}", __DIR__)
      assert {_, 0} = System.cmd("bash", ["-n", path]), rel
    end
  end
end
