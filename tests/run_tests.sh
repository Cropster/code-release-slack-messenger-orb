#!/usr/bin/env bash
#
# Test suite for src/scripts/send_release_commit_list.sh
#
# Builds throwaway git repositories, points the script at a local mock Slack
# webhook, and asserts on the captured payloads. No network access and no
# mergestat required.
#
#   ./tests/run_tests.sh            run everything
#   ./tests/run_tests.sh basic jira run only tests whose name matches

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/src/scripts/send_release_commit_list.sh"
WORK="$(mktemp -d)"
trap 'stop_mock; rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
declare -a FAILURES=()
FILTERS=("$@")

# ---------------------------------------------------------------- assertions --
ok() {
    printf '    ok    %s\n' "$1"
    PASSED=$((PASSED + 1))
}
bad() {
    printf '    FAIL  %s\n          %s\n' "$1" "$2"
    FAILED=$((FAILED + 1))
    FAILURES+=("$CURRENT_TEST :: $1")
}
check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}
check_ne() {
    if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected anything but [$3]"; fi
}
check_true() {
    if [ "$2" = "true" ]; then ok "$1"; else bad "$1" "expected true, got [$2]"; fi
}
check_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else
        bad "$1" "expected to contain [$3] in: $(printf '%s' "$2" | head -c 400)"
    fi
}
check_not_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        bad "$1" "expected NOT to contain [$3]"
    else ok "$1"; fi
}

# -------------------------------------------------------------------- fixtures --
# make_repo <dir> ; then use commit()/tag() against it
die_setup() {
    printf '\n  SETUP FAILURE: %s\n' "$1" >&2
    exit 1
}

make_repo() {
    local dir="$1"
    mkdir -p "$dir" || die_setup "mkdir $dir"
    git -C "$dir" init -q -b main || die_setup "git init in $dir"
    git -C "$dir" config user.email test@example.com || die_setup "git config email"
    git -C "$dir" config user.name 'Test User' || die_setup "git config name"
    git -C "$dir" config commit.gpgsign false || die_setup "git config gpgsign"
}

# commit <dir> <subject> [date] [author]
commit() {
    local dir="$1" subject="$2" date="${3:-2024-01-01T10:00:00+0000}" author="${4:-Test User}"
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        GIT_AUTHOR_NAME="$author" GIT_COMMITTER_NAME="$author" \
        git -C "$dir" commit -q --allow-empty -m "$subject" \
        || die_setup "commit '$subject' in $dir"
}

tag() { git -C "$1" tag "$2" || die_setup "tag $2 in $1"; }

# ------------------------------------------------------------------ mock slack --
MOCK_PID=""
MOCK_FIFO=""
MOCK_DIR=""
MOCK_PORT=""
WEBHOOK=""

start_mock() {
    local outdir="$1"
    shift
    MOCK_DIR="$outdir"
    mkdir -p "$MOCK_DIR"
    MOCK_FIFO="$WORK/fifo.$RANDOM"
    mkfifo "$MOCK_FIFO"
    python3 "$TESTS_DIR/mock_slack.py" --outdir "$MOCK_DIR" "$@" \
        >"$MOCK_FIFO" 2>"$WORK/mock.err" &
    MOCK_PID=$!
    # Blocks until the server reports its port; no polling, no sleeping.
    local word
    read -r word MOCK_PORT <"$MOCK_FIFO"
    if [ "$word" != "PORT" ] || [ -z "${MOCK_PORT:-}" ]; then
        printf 'mock server failed to start: %s\n' "$(cat "$WORK/mock.err")" >&2
        exit 1
    fi
    WEBHOOK="http://127.0.0.1:${MOCK_PORT}/services/T000/B000/XXX"
}

stop_mock() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" 2>/dev/null
        wait "$MOCK_PID" 2>/dev/null
        MOCK_PID=""
    fi
    [ -n "${MOCK_FIFO:-}" ] && rm -f "$MOCK_FIFO"
    # Clear the capture location too, so a test that forgets start_mock cannot
    # silently assert against the previous test's captured payloads.
    MOCK_DIR=""
    MOCK_PORT=""
    WEBHOOK=""
    return 0
}

req_count() {
    [ -n "${MOCK_DIR:-}" ] || { echo 'NO-MOCK'; return 0; }
    find "$MOCK_DIR" -name 'req_*.json' 2>/dev/null | wc -l | tr -d ' '
}
summary() {
    [ -n "${MOCK_DIR:-}" ] || { echo '{"error":"no mock started"}'; return 0; }
    python3 "$TESTS_DIR/verify.py" "$MOCK_DIR"
}

# run_script <repo_dir> [extra env assignments...]
# Always sets a sane default env; extra args override via `env`.
LAST_OUT=""
LAST_RC=0
run_script() {
    local repo="$1"
    shift
    # Every RELEASE_* the script reads is pinned here, and CIRCLE_TAG is
    # cleared, so a variable set in the developer's shell cannot change a
    # result. Per-test overrides are appended after these defaults.
    LAST_OUT="$(
        cd "$repo" && env \
            -u CIRCLE_TAG \
            RELEASE_REPO_NAME="${RELEASE_REPO_NAME:-Infrastructure}" \
            RELEASE_PRODUCT_LABEL="${RELEASE_PRODUCT_LABEL:-}" \
            RELEASE_WEBHOOK_ENV_VAR=TEST_HOOK \
            TEST_HOOK="$WEBHOOK" \
            RELEASE_ARTIFACT_DIR="$repo/artifacts" \
            RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-v*}" \
            RELEASE_STRICT_SEMVER="${RELEASE_STRICT_SEMVER:-true}" \
            RELEASE_FETCH_TAGS=false \
            RELEASE_SEND_DELAY=0 \
            RELEASE_BLOCKS_PER_MSG=45 \
            RELEASE_DRY_RUN=false \
            RELEASE_TRIGGER_TAG='' \
            RELEASE_JIRA_BASE_URL="${RELEASE_JIRA_BASE_URL:-}" \
            RELEASE_JIRA_KEYS="${RELEASE_JIRA_KEYS:-}" \
            "$@" \
            bash "$SCRIPT" 2>&1
    )"
    LAST_RC=$?
    return 0
}

# ---------------------------------------------------------------------- driver --
CURRENT_TEST=""
run_test() {
    local name="$1"
    if [ ${#FILTERS[@]} -gt 0 ]; then
        local matched=0 f
        for f in "${FILTERS[@]}"; do
            case "$name" in *"$f"*) matched=1 ;; esac
        done
        [ "$matched" = 1 ] || return 0
    fi
    CURRENT_TEST="$name"
    printf '\n  %s\n' "$name"
    "$name"
    stop_mock
}

# ============================================================== the test cases ==

test_basic_single_message() {
    local r="$WORK/basic"
    make_repo "$r"
    commit "$r" 'initial'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: first change'
    commit "$r" 'CSAR-2: second change'
    commit "$r" 'third change'
    tag "$r" v1.1.0
    start_mock "$WORK/basic-reqs"
    run_script "$r"

    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'sends exactly one message' "$(req_count)" 1
    local s
    s="$(summary)"
    check_eq 'no structural errors' "$(printf '%s' "$s" | jq -c '.errors')" '[]'
    check_eq 'three commit sections' "$(printf '%s' "$s" | jq '.sections | length')" 3
    check_eq 'exactly one header' "$(printf '%s' "$s" | jq '.headers | length')" 1
    check_contains 'header names repo and version' \
        "$(printf '%s' "$s" | jq -r '.headers[0]')" 'Infrastructure 1.1.0'
    check_contains 'first subject present' "$s" 'CSAR-1: first change'
    check_contains 'third subject present' "$s" 'third change'
    check_not_contains 'previous release commit excluded' "$s" 'initial'
    # artifact
    check_true 'artifact written' "$([ -f "$r/artifacts/commit_info_file.txt" ] && echo true)"
    check_contains 'artifact lists a commit' "$(cat "$r/artifacts/commit_info_file.txt")" 'second change'
    check_contains 'artifact records the range' \
        "$(cat "$r/artifacts/commit_info_file.txt")" 'Range: v1.0.0..v1.1.0'
}

test_chunking_boundaries() {
    local n
    for n in 0 1 24 25 49 50 100; do
        local r="$WORK/chunk-$n"
        make_repo "$r"
        commit "$r" 'base'
        tag "$r" v1.0.0
        local i
        for ((i = 1; i <= n; i++)); do commit "$r" "CSAR-$i: change number $i"; done
        tag "$r" v2.0.0
        start_mock "$WORK/chunk-$n-reqs"
        run_script "$r"

        # blocks = header + divider + (section + divider) per commit;
        # with zero commits it is header + divider + one "no commits" section.
        local expect_blocks expect_msgs
        if [ "$n" -eq 0 ]; then expect_blocks=3; else expect_blocks=$((2 + 2 * n)); fi
        expect_msgs=$(((expect_blocks + 44) / 45))

        local s
        s="$(summary)"
        check_eq "n=$n exits 0" "$LAST_RC" 0
        check_eq "n=$n no structural errors" "$(printf '%s' "$s" | jq -c '.errors')" '[]'
        check_eq "n=$n block total" "$(printf '%s' "$s" | jq '.blocks_total')" "$expect_blocks"
        check_eq "n=$n message count" "$(req_count)" "$expect_msgs"
        check_eq "n=$n messages match payloads" \
            "$(printf '%s' "$s" | jq '.messages')" "$expect_msgs"
        if [ "$n" -gt 0 ]; then
            check_eq "n=$n every commit rendered once" \
                "$(printf '%s' "$s" | jq '.sections | length')" "$n"
            # each commit subject appears exactly once across all messages
            check_eq "n=$n no duplicated commits" \
                "$(printf '%s' "$s" | jq '[.sections[] | capture("change number (?<i>[0-9]+)").i] | (length - (unique | length))')" 0
        fi
        stop_mock
    done
}

# SC2016: the unexpanded '$(...)' and backticks are the point of this test.
# shellcheck disable=SC2016
test_hostile_commit_subjects() {
    local r="$WORK/hostile"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-10: rename "foo" to "bar"'
    commit "$r" 'CSAR-11: rename "foo"bar unbalanced'
    commit "$r" 'CSAR-12: escape \d+ and C:\Users\x'
    commit "$r" 'CSAR-13: compare a < b && c > d'
    commit "$r" 'CSAR-14: literal backslash-n \n here'
    commit "$r" "CSAR-15: it's got single 'quotes'"
    commit "$r" 'CSAR-16: unicode ✅ émoji 🚀 ok'
    commit "$r" 'CSAR-17: $(touch /tmp/should_not_exist) `id` ${HOME}'
    commit "$r" "CSAR-18: tab	and    spaces"
    commit "$r" "CSAR-19: $(printf 'x%.0s' $(seq 1 5000))"
    tag "$r" v2.0.0
    start_mock "$WORK/hostile-reqs"
    run_script "$r"

    local s
    s="$(summary)"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'no structural errors' "$(printf '%s' "$s" | jq -c '.errors')" '[]'
    check_eq 'all ten commits rendered' "$(printf '%s' "$s" | jq '.sections | length')" 10
    check_true 'no command substitution executed' \
        "$([ ! -e /tmp/should_not_exist ] && echo true)"

    local secs
    secs="$(printf '%s' "$s" | jq -r '.sections | join("\n")')"
    check_contains 'double quotes survive' "$secs" 'rename "foo" to "bar"'
    check_contains 'unbalanced quote survives' "$secs" 'rename "foo"bar unbalanced'
    check_contains 'backslashes survive' "$secs" 'escape \d+ and C:\Users\x'
    check_contains 'less-than escaped for mrkdwn' "$secs" 'a &lt; b'
    check_contains 'greater-than escaped for mrkdwn' "$secs" 'c &gt; d'
    check_contains 'ampersand escaped for mrkdwn' "$secs" '&amp;&amp;'
    check_contains 'literal backslash-n preserved' "$secs" 'backslash-n \n here'
    check_contains 'single quotes survive' "$secs" "single 'quotes'"
    check_contains 'unicode survives' "$secs" 'unicode ✅ émoji 🚀 ok'
    check_contains 'shell metachars kept literal' "$secs" '$(touch /tmp/should_not_exist)'
    check_contains 'long subject truncated with ellipsis' "$secs" '...'
}

test_jira_linking() {
    local r="$WORK/jira"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-123: key at the start'
    commit "$r" 'Fix a bug related to CSAR-99'
    commit "$r" 'Revert "CCF-7: nope"'
    commit "$r" 'No ticket here at all'
    commit "$r" 'csar-5: lowercase should not link'
    commit "$r" 'NOPE-1: unlisted project key'
    commit "$r" 'DEVTASKS-42 and INF-7 both present'
    tag "$r" v2.0.0
    start_mock "$WORK/jira-reqs"
    RELEASE_JIRA_BASE_URL='https://example.atlassian.net/browse' \
        RELEASE_JIRA_KEYS='CSAR, INF, DEVTASKS, CCF' \
        run_script "$r"

    local secs
    secs="$(summary | jq -r '.sections | join("\n")')"
    check_eq 'exits 0' "$LAST_RC" 0
    check_contains 'links key at start' "$secs" '<https://example.atlassian.net/browse/CSAR-123|'
    check_contains 'links key found mid-subject' "$secs" '<https://example.atlassian.net/browse/CSAR-99|'
    check_contains 'links key inside a revert' "$secs" '<https://example.atlassian.net/browse/CCF-7|'
    check_contains 'links first of several keys' "$secs" '<https://example.atlassian.net/browse/DEVTASKS-42|'
    check_not_contains 'does not link the first word blindly' "$secs" '/browse/Fix'
    check_not_contains 'does not link Revert' "$secs" '/browse/Revert'
    check_not_contains 'does not link lowercase keys' "$secs" '/browse/csar-5'
    check_not_contains 'does not link unlisted keys' "$secs" '/browse/NOPE-1'
    check_contains 'unlinked subject still rendered' "$secs" 'No ticket here at all'
}

test_jira_disabled_by_default() {
    local r="$WORK/jira-off"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: should not be linked'
    tag "$r" v2.0.0
    start_mock "$WORK/jira-off-reqs"
    run_script "$r"
    local secs
    secs="$(summary | jq -r '.sections | join("\n")')"
    check_eq 'exits 0' "$LAST_RC" 0
    check_not_contains 'no link markup when unconfigured' "$secs" 'atlassian'
    check_not_contains 'no bare link syntax' "$secs" '|CSAR-1'
    check_contains 'subject still present' "$secs" 'CSAR-1: should not be linked'
}

test_tag_ordering_double_digit() {
    local r="$WORK/order10"
    make_repo "$r"
    commit "$r" 'base'
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        commit "$r" "commit for patch $i"
        tag "$r" "v0.1.$i"
    done
    start_mock "$WORK/order10-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_contains 'picks v0.1.10 as latest, v0.1.9 as previous' "$LAST_OUT" 'v0.1.9 -> v0.1.10'
    check_contains 'header shows 0.1.10' "$(summary | jq -r '.headers[0]')" '0.1.10'
    check_eq 'only the one commit in range' "$(summary | jq '.sections | length')" 1
    check_contains 'correct commit selected' "$(summary | jq -r '.sections[0]')" 'commit for patch 10'
}

test_tag_ordering_major() {
    local r="$WORK/ordermajor"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v2.0.0
    commit "$r" 'change after v2'
    tag "$r" v10.0.0
    start_mock "$WORK/ordermajor-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_contains 'v10.0.0 outranks v2.0.0' "$LAST_OUT" 'v2.0.0 -> v10.0.0'
    check_contains 'header shows 10.0.0' "$(summary | jq -r '.headers[0]')" '10.0.0'
}

test_strict_semver_filtering() {
    local r="$WORK/semver"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'real change'
    tag "$r" v1.1.0
    commit "$r" 'prerelease change'
    tag "$r" v2.0.0-rc1
    tag "$r" nightly
    start_mock "$WORK/semver-reqs"
    run_script "$r"
    check_eq 'strict: exits 0' "$LAST_RC" 0
    check_contains 'strict: ignores rc and nightly tags' "$LAST_OUT" 'v1.0.0 -> v1.1.0'
    stop_mock

    start_mock "$WORK/semver-loose-reqs"
    run_script "$r" RELEASE_STRICT_SEMVER=false RELEASE_TAG_PATTERN='v*'
    check_eq 'loose: exits 0' "$LAST_RC" 0
    check_contains 'loose: rc tag now considered latest' "$LAST_OUT" 'v2.0.0-rc1'
}

test_single_tag_uses_full_history() {
    local r="$WORK/onetag"
    make_repo "$r"
    commit "$r" 'first ever commit'
    commit "$r" 'second ever commit'
    tag "$r" v1.0.0
    start_mock "$WORK/onetag-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_contains 'reports missing previous tag' "$LAST_OUT" 'No previous tag found'
    check_eq 'lists the whole history' "$(summary | jq '.sections | length')" 2
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'
}

test_no_tags_fails_loudly() {
    local r="$WORK/notags"
    make_repo "$r"
    commit "$r" 'only commit'
    start_mock "$WORK/notags-reqs"
    run_script "$r"
    check_ne 'exits non-zero' "$LAST_RC" 0
    check_contains 'explains the problem' "$LAST_OUT" 'no tags matching'
    check_contains 'suggests fetching tags' "$LAST_OUT" 'fetch'
    check_eq 'posts nothing' "$(req_count)" 0
}

test_mixed_timezones_all_included() {
    local r="$WORK/tz"
    make_repo "$r"
    commit "$r" 'base' '2024-07-15T10:00:00+0000'
    tag "$r" v1.0.0
    commit "$r" 'commit in CEST'      '2024-07-15T14:22:33+0200'
    commit "$r" 'commit in Gulf time' '2024-07-15T15:00:00+0400'
    commit "$r" 'commit in Pacific'   '2024-07-15T05:30:00-0800'
    commit "$r" 'commit right at UTC' '2024-07-15T12:00:00+0000'
    tag "$r" v1.1.0
    start_mock "$WORK/tz-reqs"
    run_script "$r"
    local secs
    secs="$(summary | jq -r '.sections | join("\n")')"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'all four commits included regardless of offset' \
        "$(summary | jq '.sections | length')" 4
    check_contains 'CEST commit present' "$secs" 'commit in CEST'
    check_contains 'Gulf commit present' "$secs" 'commit in Gulf time'
    check_contains 'Pacific commit present' "$secs" 'commit in Pacific'
    check_contains 'UTC commit present' "$secs" 'commit right at UTC'
    check_contains 'uses Slack date token so viewers see local time' "$secs" '<!date^'
    # Each fallback must carry that commit's own offset, not a fixed one.
    check_contains 'CEST offset preserved in the fallback' "$secs" '+02:00'
    check_contains 'Gulf offset preserved in the fallback' "$secs" '+04:00'
    check_contains 'Pacific offset preserved in the fallback' "$secs" '-08:00'
    check_not_contains 'no hardcoded +01:00 offset' "$secs" '+01:00'
    # Epochs must be distinct and correct, which a fixed offset would break.
    check_eq 'four distinct epochs rendered' \
        "$(printf '%s' "$secs" | grep -oE '<!date\^[0-9]+' | sort -u | wc -l | tr -d ' ')" 4
}

test_merge_commits_excluded() {
    local r="$WORK/merges"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    git -C "$r" checkout -q -b feature
    commit "$r" 'CSAR-1: work on the feature'
    git -C "$r" checkout -q main
    commit "$r" 'CSAR-2: work on main'
    git -C "$r" merge -q --no-ff feature -m 'Merge branch feature into main'
    tag "$r" v1.1.0
    start_mock "$WORK/merges-reqs"
    run_script "$r"
    local secs
    secs="$(summary | jq -r '.sections | join("\n")')"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'only the two real commits' "$(summary | jq '.sections | length')" 2
    check_not_contains 'merge commit excluded' "$secs" 'Merge branch feature'
}

test_slack_400_fails_the_build() {
    local r="$WORK/reject400"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/reject400-reqs" --status 400
    run_script "$r"
    check_ne 'exits non-zero on HTTP 400' "$LAST_RC" 0
    check_contains 'reports the status code' "$LAST_OUT" 'HTTP 400'
    check_contains 'includes the Slack response body' "$LAST_OUT" 'invalid_blocks'
    check_eq 'the request was actually attempted' "$(req_count)" 1
}

test_slack_500_retries_then_fails() {
    local r="$WORK/reject500"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/reject500-reqs" --status 500
    run_script "$r"
    check_ne 'exits non-zero on HTTP 500' "$LAST_RC" 0
    local n
    n="$(req_count)"
    if [ "$n" -ge 2 ]; then ok "curl retried (saw $n attempts)"; else
        bad 'curl retried' "expected >= 2 attempts, got $n"
    fi
}

test_stops_on_midway_failure() {
    local r="$WORK/midway"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    local i
    for ((i = 1; i <= 60; i++)); do commit "$r" "CSAR-$i: change $i"; done
    tag "$r" v2.0.0
    # 122 blocks / 45 = 3 messages; fail from the 2nd onwards.
    start_mock "$WORK/midway-reqs" --fail-after 1 --fail-status 400
    run_script "$r"
    check_ne 'exits non-zero' "$LAST_RC" 0
    check_contains 'names the failing message' "$LAST_OUT" 'message 2/3'
    check_eq 'stops instead of sending message 3' "$(req_count)" 2
}

test_missing_webhook_fails_before_sending() {
    local r="$WORK/nohook"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/nohook-reqs"
    run_script "$r" TEST_HOOK=''
    check_ne 'exits non-zero' "$LAST_RC" 0
    check_contains 'names the missing variable' "$LAST_OUT" 'TEST_HOOK'
    check_eq 'posts nothing' "$(req_count)" 0
}

test_invalid_webhook_var_name_rejected() {
    local r="$WORK/badvar"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/badvar-reqs"
    run_script "$r" RELEASE_WEBHOOK_ENV_VAR='not-a-valid-name'
    check_ne 'exits non-zero' "$LAST_RC" 0
    check_contains 'explains the rule' "$LAST_OUT" 'valid variable name'
    check_eq 'posts nothing' "$(req_count)" 0
}

test_dry_run_sends_nothing() {
    local r="$WORK/dry"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: a change'
    tag "$r" v1.1.0
    start_mock "$WORK/dry-reqs"
    run_script "$r" RELEASE_DRY_RUN=true TEST_HOOK=''
    check_eq 'exits 0 even with no webhook configured' "$LAST_RC" 0
    check_eq 'posts nothing' "$(req_count)" 0
    check_contains 'announces dry run' "$LAST_OUT" 'Dry run complete'
    check_contains 'prints the payload' "$LAST_OUT" '"blocks"'
    # the printed payload must itself be valid JSON
    local extracted
    extracted="$(printf '%s' "$LAST_OUT" | python3 -c '
import json,sys,re
t=sys.stdin.read()
# the dry-run payload is pretty-printed; find the outermost object
i=t.find("{")
d=json.JSONDecoder()
while i!=-1:
    try:
        o,_=d.raw_decode(t[i:])
        if isinstance(o,dict) and "blocks" in o:
            print("VALID"); break
    except Exception: pass
    i=t.find("{",i+1)
else:
    print("INVALID")
')"
    check_eq 'dry-run payload is valid JSON' "$extracted" 'VALID'
}

test_parameters_are_not_executed() {
    local r="$WORK/inject"
    local canary="$WORK/canary_should_not_exist"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/inject-reqs"
    RELEASE_REPO_NAME="\$(touch $canary)" \
        RELEASE_PRODUCT_LABEL='`touch '"$canary"'2`' \
        run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_true 'command substitution did not run' "$([ ! -e "$canary" ] && echo true)"
    check_true 'backticks did not run' "$([ ! -e "${canary}2" ] && echo true)"
    check_contains 'value kept as literal text' \
        "$(summary | jq -r '.headers[0]')" 'touch'
}

test_rerun_is_idempotent() {
    local r="$WORK/rerun"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/rerun-reqs"
    run_script "$r"
    local rc1="$LAST_RC"
    run_script "$r"
    check_eq 'first run exits 0' "$rc1" 0
    check_eq 'second run exits 0' "$LAST_RC" 0
    check_eq 'artifact has a single header line' \
        "$(grep -c 'Releasing' "$r/artifacts/commit_info_file.txt")" 1
    check_eq 'artifact lists the commit once' \
        "$(grep -c 'a change' "$r/artifacts/commit_info_file.txt")" 1
}

test_blocks_per_message_validation() {
    local r="$WORK/blockval"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    local v
    for v in 0 51 abc 100 -1 3.5; do
        start_mock "$WORK/blockval-reqs-$v"
        run_script "$r" RELEASE_BLOCKS_PER_MSG="$v"
        check_ne "rejects blocks_per_message=[$v]" "$LAST_RC" 0
        check_eq "posts nothing for [$v]" "$(req_count)" 0
        stop_mock
    done

    # An empty value means "not set", so the documented default applies.
    start_mock "$WORK/blockval-empty"
    run_script "$r" RELEASE_BLOCKS_PER_MSG=''
    check_eq 'empty blocks_per_message falls back to the default' "$LAST_RC" 0
    check_eq 'default keeps it to one message' "$(req_count)" 1
    stop_mock
    # a valid low value must still work and force more messages
    start_mock "$WORK/blockval-ok"
    run_script "$r" RELEASE_BLOCKS_PER_MSG=1
    check_eq 'accepts blocks_per_message=1' "$LAST_RC" 0
    check_eq 'one block per message' "$(summary | jq '.max_blocks_in_msg')" 1
    check_eq 'four messages for four blocks' "$(req_count)" 4
}

test_fetch_tags_failure_is_a_warning() {
    local r="$WORK/fetchwarn"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/fetchwarn-reqs"
    # A repo with *no* remote makes `git fetch` a successful no-op, so point
    # origin at a path that does not exist to force a real fetch failure.
    git -C "$r" remote add origin "$WORK/definitely-not-a-repo.git"
    run_script "$r" RELEASE_FETCH_TAGS=true
    check_eq 'still succeeds using local tags' "$LAST_RC" 0
    check_contains 'warns about the failed fetch' "$LAST_OUT" 'git fetch --tags'
    check_eq 'still sends the message' "$(req_count)" 1
}

test_long_header_truncated() {
    local r="$WORK/longhdr"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/longhdr-reqs"
    RELEASE_REPO_NAME="$(printf 'R%.0s' $(seq 1 400))" run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'
    local len
    len="$(summary | jq '.headers[0] | length')"
    if [ "$len" -le 150 ]; then ok "header clipped to Slack limit ($len chars)"; else
        bad 'header clipped to Slack limit' "got $len chars"
    fi
}

test_empty_range_reports_no_commits() {
    local r="$WORK/emptyrange"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    tag "$r" v1.1.0 # same commit, so the range is empty
    start_mock "$WORK/emptyrange-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'sends one message' "$(req_count)" 1
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'
    check_contains 'says there are no commits' \
        "$(summary | jq -r '.sections | join("\n")')" 'No non-merge commits'
    check_contains 'artifact says the same' \
        "$(cat "$r/artifacts/commit_info_file.txt")" 'No non-merge commits'
}

test_authors_with_special_characters() {
    local r="$WORK/authors"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: change one' '2024-01-01T10:00:00+0000' 'Ann "The Hammer" Bee'
    commit "$r" 'CSAR-2: change two' '2024-01-01T11:00:00+0000' 'José Ñuñez'
    commit "$r" 'CSAR-3: change three' '2024-01-01T12:00:00+0000' 'A & B'
    commit "$r" 'CSAR-4: change four' '2024-01-01T13:00:00+0000' 'Backslash \ Person'
    tag "$r" v1.1.0
    start_mock "$WORK/authors-reqs"
    run_script "$r"
    local secs
    secs="$(summary | jq -r '.sections | join("\n")')"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'
    check_contains 'quoted author survives' "$secs" 'Ann "The Hammer" Bee'
    check_contains 'unicode author survives' "$secs" 'José Ñuñez'
    check_contains 'author ampersand escaped' "$secs" 'A &amp; B'
    check_contains 'author backslash survives' "$secs" 'Backslash \ Person'
    # git itself strips < and > from author names (they delimit the ident), so
    # mrkdwn angle-bracket escaping is asserted on commit subjects instead --
    # see test_hostile_commit_subjects.
}

test_content_type_header_sent() {
    local r="$WORK/ctype"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/ctype-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'sends application/json' \
        "$(jq -r '.content_type' "$MOCK_DIR"/meta_0001.json)" 'application/json'
}

# Truncation must always land in the commit subject, never inside the
# "<url|text>" link wrapper or the "<!date^...>" token, or Slack renders the
# block as raw text.
test_truncation_never_breaks_markup() {
    local r="$WORK/trunc"
    local long_subject long_author
    long_subject="CSAR-1: $(printf 'S%.0s' $(seq 1 2600))"
    long_author="$(printf 'A%.0s' $(seq 1 900))"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" "$long_subject" '2024-01-01T10:00:00+0000' "$long_author"
    commit "$r" "CSAR-2: short subject, long author" '2024-01-01T11:00:00+0000' "$long_author"
    tag "$r" v1.1.0
    start_mock "$WORK/trunc-reqs"
    RELEASE_JIRA_BASE_URL='https://example.atlassian.net/browse' \
        RELEASE_JIRA_KEYS='CSAR' run_script "$r"

    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'

    local wellformed
    wellformed="$(summary | python3 -c '
import json,sys,re
s=json.load(sys.stdin)
bad=[]
for t in s["sections"]:
    if len(t) > 3000:
        bad.append("over 3000 chars")
    # every link that opens must close
    if t.count("<https://") != t.count(">", t.find("|") if "|" in t else 0) and t.startswith("<https://"):
        pass
    if t.startswith("<https://") and not re.match(r"^<https://[^|]+\|.*?>\n", t, re.S):
        bad.append("link wrapper not closed before newline")
    # the trailing date token must be complete
    if "<!date^" in t and not re.search(r"<!date\^\d+\^\{date_num\} \{time_secs\}\|[^>]*>$", t):
        bad.append("date token truncated")
    if "<!date^" not in t:
        bad.append("date token missing entirely")
print("OK" if not bad else "BAD: " + "; ".join(sorted(set(bad))))
')"
    check_eq 'link wrapper and date token always well-formed' "$wellformed" 'OK'

    local maxlen
    maxlen="$(summary | jq '[.sections[] | length] | max')"
    if [ "$maxlen" -le 3000 ]; then ok "sections within Slack limit (max $maxlen)"; else
        bad 'sections within Slack limit' "max was $maxlen"
    fi

    # An absurd base URL must degrade to an unlinked block, not broken markup.
    stop_mock
    start_mock "$WORK/trunc-absurd-reqs"
    RELEASE_JIRA_BASE_URL="https://example.com/$(printf 'u%.0s' $(seq 1 4000))" \
        RELEASE_JIRA_KEYS='CSAR' run_script "$r"
    check_eq 'absurd base url still exits 0' "$LAST_RC" 0
    check_eq 'absurd base url yields no structural errors' "$(summary | jq -c '.errors')" '[]'
    check_eq 'absurd base url drops the link instead of breaking it' \
        "$(summary | jq '[.sections[] | select(startswith("<https://"))] | length')" 0
    check_eq 'absurd base url still respects the limit' \
        "$(summary | jq '[.sections[] | select(length > 3000)] | length')" 0
}

# The link wrapper is "<" + base + "/" + key + "|" + subject + ">" = 4
# punctuation chars. Budgeting 3 lets a section render at 3001 chars, which
# Slack rejects with invalid_blocks. Sweep subject lengths across the boundary.
test_section_never_exceeds_3000_at_boundary() {
    local r="$WORK/boundary"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    local n
    # Sweep across the point where the clip budget binds, so an off-by-one in
    # the link overhead shows up as a 3001-char section.
    for n in 2740 2800 2880 2890 2895 2900 2905 2910 2950 3000 3200; do
        commit "$r" "CSAR-$n: $(printf 'S%.0s' $(seq 1 $n))"
    done
    tag "$r" v1.1.0
    start_mock "$WORK/boundary-reqs"
    RELEASE_JIRA_BASE_URL='https://example.atlassian.net/browse' \
        RELEASE_JIRA_KEYS='CSAR' run_script "$r"

    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'
    local over maxlen
    over="$(summary | jq '[.sections[] | select(length > 3000)] | length')"
    maxlen="$(summary | jq '[.sections[] | length] | max')"
    check_eq 'no section exceeds 3000 chars at any subject length' "$over" 0
    # Must land exactly on the limit, otherwise this test would not notice an
    # off-by-one in the link overhead.
    check_eq 'a section lands exactly on the 3000-char limit' "$maxlen" 3000
    check_eq 'links still well formed at the boundary' \
        "$(summary | jq -r '[.sections[] | select(startswith("<https://")) | select(test("\\|[^>]*>\n") | not)] | length')" 0
}

# A 0x1f byte in an author name must not shift the parsed fields.
test_control_bytes_in_author_do_not_shift_fields() {
    local r="$WORK/ctrlbyte"
    local us
    us="$(printf '\037')"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: the real subject' '2024-01-01T10:00:00+0000' "Evil${us}INJECTED"
    commit "$r" 'CSAR-2: another subject' '2024-01-01T11:00:00+0000' 'Normal Person'
    tag "$r" v1.1.0
    start_mock "$WORK/ctrlbyte-reqs"
    run_script "$r"

    local secs
    secs="$(summary | jq -r '.sections | join("\n")')"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'no structural errors' "$(summary | jq -c '.errors')" '[]'
    check_eq 'both commits rendered' "$(summary | jq '.sections | length')" 2
    check_contains 'real subject still rendered' "$secs" 'CSAR-1: the real subject'
    check_contains 'second subject still rendered' "$secs" 'CSAR-2: another subject'
    # Both date tokens must be intact; a field shift would put the ISO date in
    # the epoch slot and author text inside the date token.
    check_eq 'every date token well formed' \
        "$(summary | jq -r '[.sections[] | select(test("<!date\\^[0-9]+\\^\\{date_num\\} \\{time_secs\\}\\|[^>]+>$"))] | length')" 2
    check_not_contains 'no zero epoch from a shifted field' "$secs" '<!date^0^'
}

test_send_delay_validation() {
    local r="$WORK/delayval"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    local v
    for v in -1 abc 99999999999999999999 4000; do
        start_mock "$WORK/delayval-$v"
        run_script "$r" RELEASE_SEND_DELAY="$v"
        check_ne "rejects send_delay=[$v]" "$LAST_RC" 0
        check_eq "posts nothing for send_delay=[$v]" "$(req_count)" 0
        stop_mock
    done
}

test_huge_blocks_per_message_rejected() {
    local r="$WORK/hugeblocks"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    local v
    for v in 99999999999999999999 9223372036854775808; do
        start_mock "$WORK/hugeblocks-$v"
        run_script "$r" RELEASE_BLOCKS_PER_MSG="$v"
        check_ne "rejects out-of-range blocks_per_message=[$v]" "$LAST_RC" 0
        check_eq "posts nothing for [$v]" "$(req_count)" 0
        stop_mock
    done
}

# The tag that triggered the build wins over whichever tag sorts highest.
test_trigger_tag_wins_over_highest() {
    local r="$WORK/trigger"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'goes into 1.1.0'
    tag "$r" v1.1.0
    commit "$r" 'goes into 2.0.0'
    tag "$r" v2.0.0
    start_mock "$WORK/trigger-reqs"
    run_script "$r" RELEASE_TRIGGER_TAG=v1.1.0
    check_eq 'exits 0' "$LAST_RC" 0
    check_contains 'uses the triggering tag' "$LAST_OUT" 'Using the triggering tag v1.1.0'
    check_contains 'range ends at the triggering tag' "$LAST_OUT" 'v1.0.0 -> v1.1.0'
    check_contains 'header shows the triggering version' "$(summary | jq -r '.headers[0]')" '1.1.0'
    check_eq 'only that release its commits' "$(summary | jq '.sections | length')" 1
    check_contains 'correct commit' "$(summary | jq -r '.sections[0]')" 'goes into 1.1.0'
    stop_mock

    # An unknown trigger tag warns and falls back rather than failing.
    start_mock "$WORK/trigger-bad-reqs"
    run_script "$r" RELEASE_TRIGGER_TAG=not-a-real-tag
    check_eq 'unknown trigger tag still succeeds' "$LAST_RC" 0
    check_contains 'warns about the unknown trigger tag' "$LAST_OUT" 'does not match the configured'
    check_contains 'falls back to the highest tag' "$LAST_OUT" 'v1.1.0 -> v2.0.0'
}

test_notification_fallback_text_present() {
    local r="$WORK/fallback"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    local i
    for ((i = 1; i <= 30; i++)); do commit "$r" "CSAR-$i: change $i"; done
    tag "$r" v1.1.0
    start_mock "$WORK/fallback-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'two messages' "$(req_count)" 2
    local n
    n="$(jq -s '[.[] | select(.text != null and .text != "")] | length' "$MOCK_DIR"/req_*.json)"
    check_eq 'every message carries top-level notification text' "$n" 2
    check_contains 'continuation text is numbered' \
        "$(jq -r '.text' "$MOCK_DIR"/req_0002.json)" '(2/2)'
}

test_header_requests_emoji_rendering() {
    local r="$WORK/emoji"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/emoji-reqs"
    run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'header enables emoji shortcodes' \
        "$(jq -r '.blocks[0].text.emoji' "$MOCK_DIR"/req_0001.json)" 'true'
}

# A chunk boundary must not separate a commit from its divider.
test_chunks_never_start_with_a_divider() {
    local r="$WORK/pairing"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    local i
    for ((i = 1; i <= 60; i++)); do commit "$r" "CSAR-$i: change $i"; done
    tag "$r" v1.1.0
    local bpm
    for bpm in 4 10 45; do
        start_mock "$WORK/pairing-$bpm"
        run_script "$r" RELEASE_BLOCKS_PER_MSG="$bpm"
        check_eq "bpm=$bpm exits 0" "$LAST_RC" 0
        check_eq "bpm=$bpm no structural errors" "$(summary | jq -c '.errors')" '[]'
        local orphan
        orphan="$(jq -s '[.[] | select(.blocks[0].type == "divider")] | length' "$MOCK_DIR"/req_*.json)"
        check_eq "bpm=$bpm no message opens with an orphan divider" "$orphan" 0
        local divideronly
        divideronly="$(jq -s '[.[] | select([.blocks[] | select(.type != "divider")] | length == 0)] | length' "$MOCK_DIR"/req_*.json)"
        check_eq "bpm=$bpm no divider-only message" "$divideronly" 0
        check_eq "bpm=$bpm all 60 commits still rendered" \
            "$(summary | jq '.sections | length')" 60
        check_eq "bpm=$bpm limit respected" \
            "$(summary | jq --argjson m "$bpm" '[.messages] | length')" 1
        local overmax
        overmax="$(jq -s --argjson m "$bpm" '[.[] | select((.blocks | length) > $m)] | length' "$MOCK_DIR"/req_*.json)"
        check_eq "bpm=$bpm no message exceeds the configured maximum" "$overmax" 0
        stop_mock
    done
}

test_custom_tag_pattern() {
    local r="$WORK/tagpattern"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" release-1.0.0
    commit "$r" 'change for release 1.1.0'
    tag "$r" release-1.1.0
    start_mock "$WORK/tagpattern-reqs"
    # strict semver would reject release-* names, so it must be turned off
    run_script "$r" RELEASE_TAG_PATTERN='release-*' RELEASE_STRICT_SEMVER=false
    check_eq 'exits 0 with a custom tag pattern' "$LAST_RC" 0
    check_contains 'uses the custom-pattern tags' "$LAST_OUT" 'release-1.0.0 -> release-1.1.0'
    check_eq 'one commit in range' "$(summary | jq '.sections | length')" 1
    stop_mock

    # The default strict filter cannot match such tags: fail loudly, not silently.
    start_mock "$WORK/tagpattern-strict"
    run_script "$r" RELEASE_TAG_PATTERN='release-*' RELEASE_STRICT_SEMVER=true
    check_ne 'strict semver + non-semver pattern fails loudly' "$LAST_RC" 0
    check_contains 'explains the strict filter' "$LAST_OUT" 'strict semver'
    check_eq 'posts nothing' "$(req_count)" 0
}

test_bad_jira_keys_warn() {
    local r="$WORK/badkeys"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: a change'
    tag "$r" v1.1.0
    start_mock "$WORK/badkeys-reqs"
    RELEASE_JIRA_BASE_URL='https://example.atlassian.net/browse' \
        RELEASE_JIRA_KEYS='---,@@@' run_script "$r"
    check_eq 'exits 0' "$LAST_RC" 0
    check_contains 'warns that no key survived validation' "$LAST_OUT" 'look like'
    check_not_contains 'linking disabled' "$(summary | jq -r '.sections[0]')" 'atlassian'
}

test_artifact_lists_every_commit() {
    local r="$WORK/artifact"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    local i
    for ((i = 1; i <= 40; i++)); do commit "$r" "CSAR-$i: artifact change $i"; done
    commit "$r" 'CSAR-99: unicode ✅ and a "quote"' '2024-01-01T10:00:00+0000' 'José Ñuñez'
    tag "$r" v1.1.0
    start_mock "$WORK/artifact-reqs"
    run_script "$r"
    local af="$r/artifacts/commit_info_file.txt"
    check_eq 'exits 0' "$LAST_RC" 0
    check_eq 'artifact has one row per commit plus header lines' \
        "$(grep -c 'artifact change' "$af")" 40
    check_contains 'artifact records the commit count' "$af" ''
    check_eq 'artifact commit count matches' \
        "$(grep -oE 'Commits: [0-9]+' "$af" | awk '{print $2}')" 41
    check_contains 'unicode preserved intact in the artifact' \
        "$(cat "$af")" 'José Ñuñez'
    check_contains 'unicode subject preserved' "$(cat "$af")" 'unicode ✅ and a "quote"'
    # Byte-truncating columns would corrupt the multi-byte name.
    local valid
    valid="$(python3 -c 'import sys;
try:
    open(sys.argv[1], encoding="utf-8").read(); print("VALID")
except UnicodeDecodeError: print("INVALID")' "$af")"
    check_eq 'artifact is valid UTF-8' "$valid" 'VALID'
}

test_webhook_never_appears_in_process_args() {
    local r="$WORK/argv"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'a change'
    tag "$r" v1.1.0
    start_mock "$WORK/argv-reqs"

    # Run under xtrace: the trace must not contain the webhook URL, and the
    # curl invocation must not carry it as an argument.
    local trace="$WORK/argv-trace.txt"
    (
        cd "$r" && env -u CIRCLE_TAG \
            RELEASE_REPO_NAME=Infra RELEASE_WEBHOOK_ENV_VAR=TEST_HOOK \
            TEST_HOOK="$WEBHOOK" RELEASE_ARTIFACT_DIR="$r/artifacts" \
            RELEASE_FETCH_TAGS=false RELEASE_SEND_DELAY=0 \
            bash -x "$SCRIPT"
    ) >"$trace" 2>&1
    local rc=$?
    check_eq 'exits 0 under xtrace' "$rc" 0
    check_eq 'message delivered' "$(req_count)" 1

    local secret="${WEBHOOK#http://}"
    check_not_contains 'xtrace does not leak the webhook path' \
        "$(cat "$trace")" "${secret#*/}"
    check_not_contains 'curl line does not carry the url as an argument' \
        "$(grep -F 'curl' "$trace" || true)" '127.0.0.1'
    check_contains 'curl reads the url from a config file instead' \
        "$(grep -F 'curl' "$trace" || true)" '--config'
}

test_bad_jira_base_url_disables_linking() {
    local r="$WORK/badurl"
    make_repo "$r"
    commit "$r" 'base'
    tag "$r" v1.0.0
    commit "$r" 'CSAR-1: a change'
    tag "$r" v1.1.0
    local u
    for u in 'https://ex.com/a|b' 'https://ex.com/a>b' 'not-a-url/browse' 'https://ex.com/a b'; do
        start_mock "$WORK/badurl-reqs"
        RELEASE_JIRA_BASE_URL="$u" RELEASE_JIRA_KEYS='CSAR' run_script "$r"
        check_eq "exits 0 for base url [$u]" "$LAST_RC" 0
        check_contains "warns for base url [$u]" "$LAST_OUT" 'issue linking is disabled'
        check_eq "no structural errors for [$u]" "$(summary | jq -c '.errors')" '[]'
        check_eq "no link emitted for [$u]" \
            "$(summary | jq '[.sections[] | select(startswith("<"))] | length')" 0
        stop_mock
    done
}

test_yaml_plumbing_matches_script() {
    local cmd_yml="$REPO_ROOT/src/commands/send_release_commit_list.yml"
    local job_yml="$REPO_ROOT/src/jobs/commit_list_notification.yml"
    local in_script in_yaml
    in_script="$(grep -oE 'RELEASE_[A-Z_]+' "$SCRIPT" | sort -u)"
    in_yaml="$(grep -oE 'RELEASE_[A-Z_]+' "$cmd_yml" | sort -u)"

    check_eq 'command sets every RELEASE_* the script reads' \
        "$(comm -23 <(printf '%s\n' "$in_script") <(printf '%s\n' "$in_yaml") | tr -d '\n')" ''
    check_eq 'command sets no RELEASE_* the script ignores' \
        "$(comm -13 <(printf '%s\n' "$in_script") <(printf '%s\n' "$in_yaml") | tr -d '\n')" ''

    local p missing=''
    while read -r p; do
        [ -n "$p" ] || continue
        grep -q "^      ${p}: << parameters.${p} >>\$" "$job_yml" \
            || missing="$missing $p"
    done < <(awk '/^parameters:/{f=1;next} /^[a-z@]/{f=0} f && /^  [a-z_]+:/{gsub(/[ :]/,"");print}' "$cmd_yml")
    check_eq 'job forwards every command parameter' "$missing" ''

    # The include directive must exist and point at a file that exists.
    local inc
    inc="$(grep -oE '<<include\([^)]+\)>>' "$cmd_yml" | sed -E 's/<<include\((.*)\)>>/\1/')"
    check_eq 'command uses exactly one include directive' \
        "$(grep -cE '<<include\([^)]+\)>>' "$cmd_yml" | tr -d ' ')" 1
    check_ne 'include target is non-empty' "$inc" ''
    check_true 'included script path exists' \
        "$([ -n "$inc" ] && [ -f "$REPO_ROOT/src/$inc" ] && echo true)"
    check_eq 'included path is the script under test' \
        "$REPO_ROOT/src/$inc" "$SCRIPT"
}

test_no_stale_mergestat_references() {
    local hits
    hits="$(grep -rlni 'mergestat' "$REPO_ROOT/src" "$REPO_ROOT/.circleci" 2>/dev/null || true)"
    check_eq 'no mergestat references remain in src or .circleci' "$hits" ''
    check_true 'install_mergestat command is gone' \
        "$([ ! -f "$REPO_ROOT/src/commands/install_mergestat.yml" ] && echo true)"
}

# ===================================================================== main ====
printf 'Testing %s\n' "$SCRIPT"
printf 'bash %s | git %s | jq %s\n' \
    "${BASH_VERSION}" "$(git --version | awk '{print $3}')" "$(jq --version)"

run_test test_basic_single_message
run_test test_chunking_boundaries
run_test test_hostile_commit_subjects
run_test test_jira_linking
run_test test_jira_disabled_by_default
run_test test_tag_ordering_double_digit
run_test test_tag_ordering_major
run_test test_strict_semver_filtering
run_test test_single_tag_uses_full_history
run_test test_no_tags_fails_loudly
run_test test_mixed_timezones_all_included
run_test test_merge_commits_excluded
run_test test_slack_400_fails_the_build
run_test test_slack_500_retries_then_fails
run_test test_stops_on_midway_failure
run_test test_missing_webhook_fails_before_sending
run_test test_invalid_webhook_var_name_rejected
run_test test_dry_run_sends_nothing
run_test test_parameters_are_not_executed
run_test test_rerun_is_idempotent
run_test test_blocks_per_message_validation
run_test test_fetch_tags_failure_is_a_warning
run_test test_long_header_truncated
run_test test_empty_range_reports_no_commits
run_test test_authors_with_special_characters
run_test test_content_type_header_sent
run_test test_truncation_never_breaks_markup
run_test test_section_never_exceeds_3000_at_boundary
run_test test_control_bytes_in_author_do_not_shift_fields
run_test test_send_delay_validation
run_test test_huge_blocks_per_message_rejected
run_test test_trigger_tag_wins_over_highest
run_test test_notification_fallback_text_present
run_test test_header_requests_emoji_rendering
run_test test_chunks_never_start_with_a_divider
run_test test_custom_tag_pattern
run_test test_bad_jira_keys_warn
run_test test_webhook_never_appears_in_process_args
run_test test_bad_jira_base_url_disables_linking
run_test test_artifact_lists_every_commit
run_test test_yaml_plumbing_matches_script
run_test test_no_stale_mergestat_references

printf '\n=====================================\n'
printf 'passed: %d   failed: %d\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf '\nfailures:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
printf 'ALL TESTS PASSED\n'
