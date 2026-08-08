defmodule Scripts.ClaimNextIssueTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/claim-next-issue.sh", __DIR__)
  @renderer Path.expand("../../scripts/lib/issue-brief.py", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "claims the highest-priority issue and swaps its label" do
    ctx = fixture!("claims")

    {out, 0} = claim(ctx, [])

    # p0 beats the older p2 — priority first, FIFO only within a priority.
    assert out =~ "ISSUE #11 — urgent thing"
    assert out =~ "claim: held by runner:%1"
    assert calls(ctx) =~ "DELETE 11 queue/ready"
    assert calls(ctx) =~ "POST 11 queue/claimed"
    assert calls(ctx) =~ "comment 11"
  end

  # Two runners reaching the same issue is the whole reason claiming is a
  # compare-and-swap on `queue/ready`: GitHub 404s whoever is second. The loser
  # must move on to the next candidate, not fail the run — losing a race is
  # normal on a shared queue.
  test "moves to the next candidate when another runner wins the race" do
    ctx = fixture!("race")

    {out, 0} = claim(ctx, [{"FAKE_CAS_FAIL", "11"}])

    assert out =~ "ISSUE #12 — older thing"
    assert out =~ "was taken by another runner"
    # It must not have claimed the one it lost.
    refute calls(ctx) =~ "POST 11 queue/claimed"
    assert calls(ctx) =~ "POST 12 queue/claimed"
  end

  test "reports a lost queue rather than claiming nothing silently" do
    ctx = fixture!("all-lost")

    {out, code} = claim(ctx, [{"FAKE_CAS_FAIL", "11,12"}])

    assert code == 3
    assert out =~ "was claimed by another runner first"
    refute calls(ctx) =~ "POST"
  end

  test "distinguishes an empty queue from a failure" do
    ctx = fixture!("empty")

    {out, code} = claim(ctx, [{"FAKE_READY", "none"}])

    assert code == 4
    assert out =~ "no workspace/devide issues are queue/ready"
  end

  # A runner asking twice must continue its own work, not take a second issue
  # off the queue and half-do both.
  test "returns the issue this runner already holds instead of claiming another" do
    ctx = fixture!("held")

    {out, 0} = claim(ctx, [{"FAKE_HELD", "12"}])

    assert out =~ "ISSUE #12"
    assert out =~ "already held by runner:%1 — continue it"
    # Nothing was claimed, and no second claim comment was left.
    refute calls(ctx) =~ "DELETE"
    refute calls(ctx) =~ "comment"
  end

  test "another runner's claim is refused rather than stolen" do
    ctx = fixture!("stolen")

    {out, code} = claim(ctx, [{"FAKE_HELD", "12"}, {"CASEIN_CLAIM_OWNER", "someone-else:%9"}])

    {out2, code2} =
      claim(ctx, [
        {"FAKE_HELD", "12"},
        {"CASEIN_CLAIM_OWNER", "someone-else:%9"},
        {"EXTRA_ARGS", "--issue 12"}
      ])

    # Without --issue it simply does not see the claim as its own and claims fresh.
    assert code == 0
    assert out =~ "ISSUE #11"

    assert code2 == 5
    assert out2 =~ "claimed by another runner"
  end

  # Winning the CAS and then failing to record the claim would leave the issue
  # with no queue/* label at all — invisible to every runner, including the one
  # that just took it.
  test "puts the issue back when the claim cannot be recorded" do
    ctx = fixture!("rollback")

    {out, code} = claim(ctx, [{"FAKE_COMMENT_FAIL", "1"}])

    assert code == 1
    assert out =~ "could not leave the claim comment"
    assert out =~ "released it again"
    assert calls(ctx) =~ "POST 11 queue/ready"
  end

  test "--dry-run resolves a brief without touching any labels" do
    ctx = fixture!("dry")

    {out, 0} = claim(ctx, [{"EXTRA_ARGS", "--dry-run"}])

    assert out =~ "claim: NOT claimed (dry run)"
    assert calls(ctx) == ""
  end

  test "--list ranks candidates without claiming" do
    ctx = fixture!("list")

    {out, 0} = claim(ctx, [{"EXTRA_ARGS", "--list"}])

    assert out =~ ~r/^11\tp0\turgent thing$/m
    assert out =~ ~r/^12\tp2\tolder thing$/m
    assert calls(ctx) == ""
  end

  test "fails loudly on an unknown workspace instead of reporting an empty queue" do
    ctx = fixture!("bad-ws")

    {out, code} = claim(ctx, [{"EXTRA_ARGS", "--workspace nope"}])

    assert code == 1
    assert out =~ "no label 'workspace/nope'"
  end

  # Issue *forms* render their fields as `### Goal`; the hand-written issues that
  # predate the form use `## Goal`. Both are in the queue right now.
  test "the brief parses both issue-form and hand-written bodies" do
    form = """
    ### Goal

    Make the thing work.

    ### Workspace

    devide

    ### Acceptance

    - [ ] a test
    - [ ] PR URL

    ### Forbidden

    No drive-by refactors.
    """

    hand = "## Goal\nMake the thing work.\n\n## Acceptance\n- [ ] a test\n"

    for body <- [form, hand] do
      brief = render(body)
      assert brief["goal"] == "Make the thing work."
      assert brief["acceptance"] =~ "- [ ] a test"
    end

    assert render(form)["forbidden"] == "No drive-by refactors."
  end

  test "an unstructured body survives verbatim rather than being parsed away" do
    brief = render("just a paragraph, no headings at all")

    assert brief["goal"] == ""
    assert brief["brief"] =~ "BODY (unstructured)"
    assert brief["brief"] =~ "just a paragraph"
  end

  test "the spawn slug is branch-safe and cut on a word boundary" do
    brief =
      render("## Goal\nx\n", title: "Soft-block concurrent git mutation on shared worktree paths")

    assert brief["task_slug"] == "issue7-soft-block-concurrent-git"
    assert brief["brief"] =~ "spawn-agent-worker.sh <runtime> issue7-soft-block-concurrent-git"
  end

  # System.cmd/3 cannot write stdin, so hand the payload to the renderer through
  # a temp file and a shell redirect.
  defp render(body, opts \\ []) do
    payload =
      Jason.encode!(%{
        "number" => 7,
        "title" => Keyword.get(opts, :title, "a title"),
        "url" => "https://example.test/7",
        "body" => body,
        "labels" => [%{"name" => "workspace/devide"}, %{"name" => "priority/p1"}]
      })

    path = Path.join(System.tmp_dir!(), "issue-brief-#{System.unique_integer([:positive])}.json")
    File.write!(path, payload)
    on_exit(fn -> File.rm_rf!(path) end)

    {out, 0} =
      System.cmd(
        "bash",
        ["-c", "python3 #{@renderer} --format json --owner 'runner:%1' < #{path}"],
        stderr_to_stdout: true
      )

    Jason.decode!(out)
  end

  defp claim(ctx, extra_env) do
    extra_args =
      extra_env
      |> Enum.find_value("", fn
        {"EXTRA_ARGS", value} -> value
        _ -> false
      end)
      |> String.split(" ", trim: true)

    env = Enum.reject(extra_env, fn {key, _} -> key == "EXTRA_ARGS" end)

    System.cmd("bash", [@script | extra_args],
      env:
        [
          {"PATH", ctx.fakebin <> ":" <> System.get_env("PATH")},
          {"FAKE_LOG", ctx.log},
          {"CASEIN_CLAIM_OWNER", "runner:%1"},
          {"CASEIN_WORKSPACE_NAME", "someone-devide"}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp calls(ctx) do
    case File.read(ctx.log) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  # A `gh` that answers only what this script asks, journals every mutation, and
  # can be told to lose a claim race (FAKE_CAS_FAIL) or drop a write
  # (FAKE_COMMENT_FAIL).
  defp fixture!(label) do
    tmp =
      Path.join(System.tmp_dir!(), "claim-next-#{label}-#{System.unique_integer([:positive])}")

    fakebin = Path.join(tmp, "bin")
    File.mkdir_p!(fakebin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(fakebin, "gh"), gh_stub())
    File.chmod!(Path.join(fakebin, "gh"), 0o755)

    %{fakebin: fakebin, log: Path.join(tmp, "gh-calls.log")}
  end

  defp gh_stub do
    """
    #!/usr/bin/env bash
    args="$*"
    log() { [[ -n "${FAKE_LOG:-}" ]] && printf '%s\\n' "$*" >>"$FAKE_LOG"; return 0; }

    ready_json() {
      if [[ "${FAKE_READY:-list}" == "none" ]]; then printf '[]'; return; fi
      cat <<'JSON'
    [
      {"number":12,"title":"older thing","createdAt":"2026-01-01T00:00:00Z",
       "labels":[{"name":"queue/ready"},{"name":"workspace/devide"},{"name":"priority/p2"}]},
      {"number":11,"title":"urgent thing","createdAt":"2026-02-01T00:00:00Z",
       "labels":[{"name":"queue/ready"},{"name":"workspace/devide"},{"name":"priority/p0"}]}
    ]
    JSON
    }

    issue_json() {
      local number="$1" title="urgent thing" priority="p0"
      if [[ "$number" == "12" ]]; then title="older thing"; priority="p2"; fi
      cat <<JSON
    {"number":${number},"title":"${title}",
     "url":"https://example.test/${number}",
     "body":"## Goal\\nDo the thing.\\n\\n## Acceptance\\n- [ ] a test\\n",
     "createdAt":"2026-01-01T00:00:00Z",
     "labels":[{"name":"${LABEL_STATE:-queue/ready}"},{"name":"workspace/devide"},{"name":"priority/${priority}"}],
     "comments":[{"body":"CLAIMED\\n\\n<!-- casein-claim: owner=runner:%1 -->"}]}
    JSON
    }

    case "${1:-}" in
      repo) printf 'acme/repo\\n' ;;
      label) printf 'queue/ready\\nqueue/claimed\\nworkspace/devide\\n' ;;
      issue)
        case "${2:-}" in
          list)
            if [[ "$args" == *"queue/claimed"* ]]; then
              if [[ -n "${FAKE_HELD:-}" ]]; then
                printf '[{"number":%s,"comments":[{"body":"<!-- casein-claim: owner=runner:%%1 -->"}]}]' "$FAKE_HELD"
              else
                printf '[]'
              fi
            else
              ready_json
            fi
            ;;
          view)
            number="$3"
            if [[ -n "${FAKE_HELD:-}" && "$number" == "${FAKE_HELD}" ]]; then
              LABEL_STATE="queue/claimed" issue_json "$number"
            else
              issue_json "$number"
            fi
            ;;
          comment)
            if [[ "${FAKE_COMMENT_FAIL:-0}" == "1" ]]; then exit 1; fi
            log "comment $3"
            ;;
        esac
        ;;
      api)
        target="$(printf '%s' "$args" | grep -oE 'issues/[0-9]+' | head -1 | cut -d/ -f2)"
        if [[ "$args" == *"-X DELETE"* ]]; then
          label="$(printf '%s' "$args" | sed 's|.*labels/||; s| .*||; s|%2F|/|')"
          if [[ ",${FAKE_CAS_FAIL:-}," == *",${target},"* && "$label" == "queue/ready" ]]; then
            exit 1
          fi
          log "DELETE ${target} ${label}"
        else
          label="$(printf '%s' "$args" | sed 's|.*labels\\[\\]=||; s| .*||')"
          log "POST ${target} ${label}"
        fi
        ;;
    esac
    exit 0
    """
  end
end
