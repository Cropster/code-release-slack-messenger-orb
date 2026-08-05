#!/usr/bin/env bash
#
# Collect the commits belonging to the latest tagged release and post them to a
# Slack incoming webhook, one message per chunk of blocks.
#
# All inputs arrive through the environment. Orb parameters are never
# interpolated into executable shell text, so a parameter value can never be
# evaluated as a command.
#
#   RELEASE_REPO_NAME        Label shown in the message header.
#   RELEASE_PRODUCT_LABEL    Optional product prefix shown before the repo name.
#   RELEASE_WEBHOOK_ENV_VAR  *Name* of the variable holding the webhook URL.
#   RELEASE_TAG_PATTERN      Glob selecting candidate release tags.
#   RELEASE_STRICT_SEMVER    "true" keeps only vX.Y.Z / X.Y.Z tags.
#   RELEASE_SCHEME           previous_minor (default) or previous_tag.
#   RELEASE_JIRA_BASE_URL    Issue browse URL, no trailing slash. Empty disables links.
#   RELEASE_JIRA_KEYS        Space/comma separated Jira project keys.
#   RELEASE_ARTIFACT_DIR     Directory for the plain-text artifact.
#   RELEASE_BLOCKS_PER_MSG   Blocks per Slack message, 1..50.
#   RELEASE_FETCH_TAGS       "true" runs 'git fetch --tags' first.
#   RELEASE_SEND_DELAY       Seconds to wait between messages.
#   RELEASE_DRY_RUN          "true" prints payloads instead of posting them.
#   RELEASE_TRIGGER_TAG      Tag that triggered the build; defaults to $CIRCLE_TAG.

set -euo pipefail

# Slack Block Kit hard limits. See https://api.slack.com/reference/block-kit
readonly SLACK_MAX_BLOCKS=50
readonly SLACK_MAX_HEADER_CHARS=150
readonly SLACK_MAX_SECTION_CHARS=3000
# Bytes of a non-200 response echoed into the job log.
readonly MAX_RESPONSE_LOG_BYTES=500

# Suppress xtrace around anything that touches the webhook URL, so enabling
# `bash -x` on this script can never print the secret.
XTRACE_RESTORE=':'
xtrace_off() {
    case "$-" in
        *x*)
            XTRACE_RESTORE='set -x'
            set +x
            ;;
        *) XTRACE_RESTORE=':' ;;
    esac
}
xtrace_restore() { $XTRACE_RESTORE; }

log() { printf '%s\n' "$*" >&2; }
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Reject anything that is not a plain non-negative integer of sane magnitude.
# Digit-only is not enough: 'test -gt' errors out on values beyond int64 and
# that error would otherwise be read as "comparison false".
require_small_int() {
    local name="$1" value="$2" min="$3" max="$4"
    case "$value" in
        '' | *[!0-9]*) die "$name must be a non-negative integer, got '$value'" ;;
    esac
    if [ "${#value}" -gt 9 ]; then
        die "$name is implausibly large ('$value'); expected $min..$max"
    fi
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        die "$name must be between $min and $max, got '$value'"
    fi
}

repo_name="${RELEASE_REPO_NAME:-}"
product_label="${RELEASE_PRODUCT_LABEL:-}"
webhook_env_var="${RELEASE_WEBHOOK_ENV_VAR:-SLACK_WEBHOOK_URL}"
tag_pattern="${RELEASE_TAG_PATTERN:-v*}"
strict_semver="${RELEASE_STRICT_SEMVER:-true}"
release_scheme="${RELEASE_SCHEME:-previous_minor}"
jira_base_url="${RELEASE_JIRA_BASE_URL:-}"
jira_keys_raw="${RELEASE_JIRA_KEYS:-}"
artifact_dir="${RELEASE_ARTIFACT_DIR:-./artifacts}"
blocks_per_msg="${RELEASE_BLOCKS_PER_MSG:-45}"
fetch_tags="${RELEASE_FETCH_TAGS:-true}"
send_delay="${RELEASE_SEND_DELAY:-1}"
dry_run="${RELEASE_DRY_RUN:-false}"
trigger_tag="${RELEASE_TRIGGER_TAG:-${CIRCLE_TAG:-}}"

for tool in git jq curl; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' is not installed"
done

require_small_int 'RELEASE_BLOCKS_PER_MSG' "$blocks_per_msg" 1 "$SLACK_MAX_BLOCKS"
require_small_int 'RELEASE_SEND_DELAY' "$send_delay" 0 3600

case "$release_scheme" in
    previous_minor | previous_tag) ;;
    *) die "RELEASE_SCHEME must be 'previous_minor' or 'previous_tag', got '$release_scheme'" ;;
esac

# Resolve the webhook indirectly so the URL itself never appears in the config,
# in this script, or in any argument list.
webhook_url=''
if [ "$dry_run" != 'true' ]; then
    case "$webhook_env_var" in
        '' | *[!A-Za-z0-9_]* | [0-9]*)
            die "RELEASE_WEBHOOK_ENV_VAR must be a valid variable name, got '$webhook_env_var'"
            ;;
    esac
    xtrace_off
    webhook_url="${!webhook_env_var:-}"
    # The emptiness test has to stay inside the xtrace-off window: tracing it
    # would print the expanded URL.
    if [ -z "$webhook_url" ]; then
        xtrace_restore
        die "environment variable '$webhook_env_var' is empty or unset; \
set it as a project/context variable (or pass dry_run: true)"
    fi
    xtrace_restore
fi

# A base URL containing Slack link metacharacters would produce broken mrkdwn
# for every commit, so drop it rather than emit malformed links.
if [ -n "$jira_base_url" ]; then
    case "$jira_base_url" in
        *'<'* | *'>'* | *'|'* | *' '* | *"$(printf '\t')"*)
            log "WARNING: jira_base_url contains characters that break Slack link syntax \
('<', '>', '|' or whitespace); issue linking is disabled."
            jira_base_url=''
            ;;
        http://* | https://*) ;;
        *)
            log "WARNING: jira_base_url ('${jira_base_url}') does not start with http:// or \
https://; issue linking is disabled."
            jira_base_url=''
            ;;
    esac
fi

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

if [ "$fetch_tags" = 'true' ]; then
    # A failure here is not fatal on its own; the tag precondition below is what
    # actually has to hold, and it is checked explicitly.
    if ! git fetch --tags --force --quiet >/dev/null 2>&1; then
        log "WARNING: 'git fetch --tags' failed; continuing with locally available tags."
    fi
fi

# A shallow checkout silently stops the revision walk at the graft boundary,
# which would drop commits from the release notes without any error.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = 'true' ]; then
    log "WARNING: this is a shallow clone; the commit list may be incomplete. \
Run 'git fetch --unshallow' before this step for a complete release list."
fi

# --- Tag selection -----------------------------------------------------------
# --sort=-v:refname is git's own version sort, so v0.1.10 correctly outranks
# v0.1.5 and v10.0.0 outranks v2.0.0.
all_tags="$(git tag --list "$tag_pattern" --sort=-v:refname)"
if [ "$strict_semver" = 'true' ]; then
    all_tags="$(printf '%s\n' "$all_tags" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)"
fi
all_tags="$(printf '%s\n' "$all_tags" | grep -v '^$' || true)"

if [ -z "$all_tags" ]; then
    die "no tags matching '$tag_pattern'$( [ "$strict_semver" = 'true' ] && printf ' (strict semver)' ) \
were found. Tags are required to determine the release. If this repository does \
have tags, the checkout may not have fetched them: set fetch_tags: true or add a \
'git fetch --tags' step."
fi

# Prefer the tag that triggered this build. Without this, a hotfix tag cut from
# an older branch would announce whichever tag happens to sort highest.
if [ -n "$trigger_tag" ] && printf '%s\n' "$all_tags" | grep -qxF -- "$trigger_tag"; then
    latest_tag="$trigger_tag"
    previous_tag="$(printf '%s\n' "$all_tags" | awk -v t="$trigger_tag" 'found { print; exit } $0 == t { found = 1 }')"
    log "Using the triggering tag ${latest_tag}"
else
    if [ -n "$trigger_tag" ]; then
        log "WARNING: triggering tag '${trigger_tag}' does not match the configured \
tag selection; falling back to the highest matching tag."
    fi
    latest_tag="$(printf '%s\n' "$all_tags" | sed -n '1p')"
    previous_tag="$(printf '%s\n' "$all_tags" | sed -n '2p')"
fi

version="${latest_tag#v}"

# --- Release scheme ----------------------------------------------------------
# previous_minor models Cropster's cadence: a patch of 0 is the weekly feature
# release and spans back to the previous week's release (so hotfixes cut in
# between are included), while a patch above 0 is a hotfix and reports only its
# own commit. previous_tag is the plain "since the preceding tag" behaviour.
is_hotfix=false
if [ "$release_scheme" = 'previous_minor' ]; then
    semver="${latest_tag#v}"
    if printf '%s' "$semver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        major="${semver%%.*}"
        rest="${semver#*.}"
        minor="${rest%%.*}"
        patch="${rest#*.}"
        tag_prefix=''
        case "$latest_tag" in v*) tag_prefix='v' ;; esac

        if [ "$patch" -gt 0 ]; then
            is_hotfix=true
            log "Patch version ${patch} > 0: treating ${latest_tag} as a hotfix release"
        elif [ "$minor" -gt 0 ]; then
            candidate="${tag_prefix}${major}.$((minor - 1)).0"
            if printf '%s\n' "$all_tags" | grep -qxF -- "$candidate"; then
                previous_tag="$candidate"
                log "Feature release: spanning back to the previous weekly release ${candidate}"
            else
                log "WARNING: expected previous weekly release '${candidate}' does not exist; \
falling back to the preceding tag."
            fi
        else
            log "WARNING: ${latest_tag} has minor version 0, so there is no previous weekly \
release to span back to; falling back to the preceding tag."
        fi
    else
        log "WARNING: '${latest_tag}' is not a plain X.Y.Z version, so the weekly/hotfix \
scheme cannot be applied; falling back to the preceding tag."
    fi
fi

if [ "$is_hotfix" = 'true' ]; then
    # Scope to the commits the hotfix actually introduced. Walking from the tag
    # alone is wrong: when the tag points at a merge, git follows the first
    # parent and returns a commit that predates the hotfix entirely.
    if [ -n "$previous_tag" ]; then
        range="${previous_tag}..${latest_tag}"
    else
        range="$latest_tag"
    fi
    log "Hotfix release: listing only the newest commit introduced by ${latest_tag}"
elif [ -n "$previous_tag" ]; then
    range="${previous_tag}..${latest_tag}"
    log "Release range: ${previous_tag} -> ${latest_tag}"
else
    # First release: everything reachable from the tag.
    range="$latest_tag"
    log "No previous tag found; listing the full history up to ${latest_tag}"
fi

# --- Collect commits ---------------------------------------------------------
work_dir="$(mktemp -d)"
# shellcheck disable=SC2317  # invoked via trap, not sequentially
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

commits_raw="${work_dir}/commits.txt"
# One field per LINE, five lines per commit. git forbids newlines in author
# names and %s is always collapsed to a single line, so this framing cannot be
# broken by any byte an author can put in a name or subject -- unlike an
# in-line delimiter, which a 0x1f in a name would shift.
if [ "$is_hotfix" = 'true' ]; then
    git log --no-merges -n 1 --format='%H%n%an%n%cI%n%ct%n%s' "$range" -- >"$commits_raw"
else
    git log --no-merges --format='%H%n%an%n%cI%n%ct%n%s' "$range" -- >"$commits_raw"
fi

line_count="$(grep -c '' "$commits_raw" || true)"
: "${line_count:=0}"
if [ $((line_count % 5)) -ne 0 ]; then
    die "internal error: git log produced ${line_count} lines, which is not a multiple of 5"
fi
commit_count=$((line_count / 5))
log "Found ${commit_count} non-merge commit(s) in ${range}"

# Split on commas/whitespace, normalise, and drop anything that is not a
# plausible Jira project key. Done entirely in jq so there is exactly one
# writer to stdout regardless of whether the input is empty.
jira_keys_json="$(
    printf '%s' "$jira_keys_raw" | jq -R -s '
        [ splits("[,[:space:]]+")
          | select(length > 0)
          | ascii_upcase
          | select(test("^[A-Z][A-Z0-9_]*$"))
        ] | unique
    '
)"
if [ -n "$jira_keys_raw" ] && [ "$jira_keys_json" = '[]' ]; then
    log "WARNING: none of the values in jira_project_keys ('${jira_keys_raw}') look like \
Jira project keys; issue linking is disabled."
fi

header_text="$(
    printf ':rocket: Releasing %s%s %s with the following changes:' \
        "$( [ -n "$product_label" ] && printf '%s ' "$product_label" )" \
        "${repo_name:-this repository}" \
        "$version"
)"

# --- Artifact ----------------------------------------------------------------
mkdir -p "$artifact_dir"
artifact_file="${artifact_dir}/commit_info_file.txt"
{
    printf '# ----- Releasing %s%s %s with the following changes: ----- #\n' \
        "$( [ -n "$product_label" ] && printf '%s ' "$product_label" )" \
        "${repo_name:-this repository}" \
        "$version"
    printf '# Range: %s   Commits: %s\n\n' "$range" "$commit_count"
    if [ "$commit_count" -eq 0 ]; then
        printf 'No non-merge commits in this range.\n'
    else
        printf '%s\t%s\t%s\t%s\n' 'HASH' 'AUTHOR' 'COMMITTED' 'SUBJECT'
        # Five reads per record, matching the five-line format above.
        while IFS= read -r hash \
            && IFS= read -r author \
            && IFS= read -r iso \
            && IFS= read -r _epoch \
            && IFS= read -r subject; do
            # Tab separated rather than column padded: padding truncates by
            # bytes and would split multi-byte author names mid-character.
            printf '%.12s\t%s\t%s\t%s\n' "$hash" "$author" "$iso" "$subject"
        done <"$commits_raw"
    fi
} >"$artifact_file"
log "Wrote artifact ${artifact_file}"

# --- Build Slack payloads ----------------------------------------------------
payloads="${work_dir}/payloads.ndjson"
jq -c -R -n \
    --arg header "$header_text" \
    --arg jira_base "$jira_base_url" \
    --argjson jira_keys "$jira_keys_json" \
    --argjson chunk "$blocks_per_msg" \
    --argjson max_header "$SLACK_MAX_HEADER_CHARS" \
    --argjson max_section "$SLACK_MAX_SECTION_CHARS" '
    def clip($n): if (length > $n) then (.[0:$n - 3] + "...") else . end;

    # Slack mrkdwn requires these three to be entity-escaped. & must go first.
    def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");

    # The first configured Jira key found anywhere in the subject, or null.
    # Deliberately not anchored to the start: "Fix a bug related to CSAR-99"
    # should link CSAR-99 rather than the first word.
    def jira_match($keys):
      if ($keys | length) == 0 then null
      else ( [ match("\\b(" + ($keys | join("|")) + ")-[0-9]+"; "g") ] | .[0] )
      end;

    # Everything after the subject is fixed-size and must never be truncated,
    # or the <!date^...> token and the link wrapper would be cut mid-markup and
    # render as raw text in Slack. So the trailing metadata is built first and
    # the subject is clipped to whatever budget is left.
    def commit_block($base; $keys):
      . as $c
      | ( ($c.author | esc | clip(200))
          + ", <!date^" + ($c.epoch | tostring)
          + "^{date_num} {time_secs}|" + $c.iso + ">" ) as $meta
      | ( $max_section - ($meta | length) - 1 ) as $body_budget
      | ( if ($base | length) == 0 then null else ($c.subject | jira_match($keys)) end ) as $m
      # Wrapper is "<" + base + "/" + key + "|" + subject + ">" -> 4 punctuation chars.
      | ( if $m == null then 0
          else ($base | length) + ($m.string | length) + 4
          end ) as $overhead
      # Only link if doing so still leaves room for a useful amount of subject.
      | ( $overhead > 0 and ($overhead + 24) <= $body_budget ) as $use_link
      | ( if $use_link then $body_budget - $overhead else $body_budget end ) as $subj_budget
      | ( $c.subject | esc | clip($subj_budget) ) as $subj
      | { type: "section",
          text: {
            type: "mrkdwn",
            text: ( ( if $use_link
                      then "<" + $base + "/" + $m.string + "|" + $subj + ">"
                      else $subj
                      end )
                    + "\n" + $meta )
          }
        };

    def divider: { type: "divider" };

    # Five lines per commit, in the order emitted by git log above.
    [ inputs ] as $lines
    | [ range(0; ($lines | length); 5)
        | { hash:    $lines[.],
            author:  $lines[. + 1],
            iso:     $lines[. + 2],
            epoch:   (($lines[. + 3] // "0") | tonumber? // 0),
            subject: ($lines[. + 4] // "") }
      ] as $commits

    # Group blocks that belong together so a chunk boundary never separates a
    # commit from its divider.
    | ( [ [ { type: "header",
              text: { type: "plain_text", text: ($header | clip($max_header)), emoji: true } },
            divider ] ]
        + ( if ($commits | length) == 0
            then [ [ { type: "section",
                       text: { type: "mrkdwn",
                               text: "_No non-merge commits in this range._" } } ] ]
            else [ $commits[] | [ commit_block($jira_base; $jira_keys), divider ] ]
            end ) ) as $units

    # Greedy pack. A unit larger than the chunk size is emitted on its own and
    # then split flat below, so the per-message limit is always respected.
    | ( reduce $units[] as $u ([];
          if (length == 0) or (((.[-1] | length) + ($u | length)) > $chunk)
          then . + [ $u ]
          else .[0:-1] + [ .[-1] + $u ]
          end ) ) as $packed

    | [ $packed[] | . as $blocks | range(0; ($blocks | length); $chunk) | $blocks[. : . + $chunk] ]
    | to_entries
    | (length) as $total
    | .[]
    | { text: ($header | clip($max_header))
              + (if $total > 1 then " (" + ((.key + 1) | tostring) + "/" + ($total | tostring) + ")" else "" end),
        blocks: .value }
' <"$commits_raw" >"$payloads"

message_total="$(grep -c . "$payloads" || true)"
: "${message_total:=0}"
[ "$message_total" -gt 0 ] || die "failed to build any Slack payload (internal error)"

total_blocks="$(jq -s 'map(.blocks | length) | add' "$payloads")"
log "Built ${total_blocks} block(s) across ${message_total} Slack message(s)"

# Fail closed rather than posting something Slack will reject.
oversized="$(jq -s --argjson m "$SLACK_MAX_BLOCKS" '[.[] | select((.blocks | length) > $m)] | length' "$payloads")"
[ "$oversized" -eq 0 ] || die "internal error: ${oversized} payload(s) exceed ${SLACK_MAX_BLOCKS} blocks"

overlong="$(jq -s --argjson m "$SLACK_MAX_SECTION_CHARS" \
    '[.[] | .blocks[] | select(.text.text != null) | select((.text.text | length) > $m)] | length' "$payloads")"
[ "$overlong" -eq 0 ] || die "internal error: ${overlong} block(s) exceed ${SLACK_MAX_SECTION_CHARS} characters"

# --- Send --------------------------------------------------------------------
body_file="${work_dir}/body.json"
resp_file="${work_dir}/response.txt"
curl_cfg="${work_dir}/curl.cfg"
index=0

# Hand the URL to curl through a config file inside the 0700 temp dir instead
# of on the command line, so it never appears in the process argument list (or
# in an xtrace of this script, which would show only the file name).
if [ "$dry_run" != 'true' ]; then
    xtrace_off
    esc_url="${webhook_url//\\/\\\\}"
    esc_url="${esc_url//\"/\\\"}"
    printf 'url = "%s"\n' "$esc_url" >"$curl_cfg"
    unset esc_url
    xtrace_restore
fi

while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    index=$((index + 1))
    printf '%s' "$payload" >"$body_file"

    if [ "$dry_run" = 'true' ]; then
        log "[dry-run] message ${index}/${message_total} ($(jq '.blocks | length' "$body_file") blocks):"
        jq . "$body_file" >&2
        continue
    fi

    log "Sending message ${index}/${message_total} to Slack..."
    http_code="$(
        curl --config "$curl_cfg" \
            --silent --show-error \
            --request POST \
            --header 'Content-type: application/json' \
            --data-binary "@${body_file}" \
            --max-time 30 --retry 3 --retry-delay 2 \
            --output "$resp_file" \
            --write-out '%{http_code}'
    )" || die "curl failed for message ${index}/${message_total} (exit $?)"

    if [ "$http_code" != '200' ]; then
        die "Slack rejected message ${index}/${message_total}: HTTP ${http_code} - \
$(head -c "$MAX_RESPONSE_LOG_BYTES" "$resp_file" | tr -d '\n')"
    fi
    log "Message ${index}/${message_total} delivered (HTTP 200)"

    # Incoming webhooks are rate limited to roughly one message per second.
    if [ "$index" -lt "$message_total" ] && [ "$send_delay" != '0' ]; then
        sleep "$send_delay"
    fi
done <"$payloads"

if [ "$dry_run" = 'true' ]; then
    log "Dry run complete: ${message_total} message(s) built, nothing sent."
else
    log "All ${message_total} message(s) delivered."
fi
