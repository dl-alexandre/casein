defmodule Casein.Files.JanitorTest do
  use Casein.TestCase, async: true
  alias Casein.Files.Janitor

  setup do
    root = Path.join(System.tmp_dir!(), "jan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sub"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp age(path, seconds_old) do
    t = System.os_time(:second) - seconds_old
    erl = :calendar.gregorian_seconds_to_datetime(t + 62_167_219_200)
    File.touch!(path, erl)
  end

  test "removes stale tmp files inside root", %{root: root} do
    stale = Path.join(root, ".devide.tmp.aaaa")
    fresh = Path.join(root, ".devide.tmp.bbbb")
    File.write!(stale, "")
    File.write!(fresh, "")
    age(stale, 7200)
    {:ok, removed} = Janitor.clean(root, 3600)
    assert stale in removed
    refute fresh in removed
    refute File.exists?(stale)
    assert File.exists?(fresh)
  end

  test "ignores non-prefix files even when old", %{root: root} do
    p = Path.join(root, "important.txt")
    File.write!(p, "do not touch")
    age(p, 7200)
    {:ok, removed} = Janitor.clean(root, 3600)
    assert removed == []
    assert File.exists?(p)
  end

  test "does not chase symlinked directories outside root", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "jan-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    target = Path.join(outside, ".devide.tmp.escape")
    File.write!(target, "")
    age(target, 7200)
    File.ln_s!(outside, Path.join(root, "linked"))
    on_exit(fn -> File.rm_rf!(outside) end)

    {:ok, removed} = Janitor.clean(root, 3600)
    refute target in removed
    assert File.exists?(target)
  end
end
