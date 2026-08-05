# Code Release Slack Messenger Orb

[![CircleCI Build Status](https://circleci.com/gh/Cropster/code-release-slack-messenger-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/Cropster/code-release-slack-messenger-orb)
[![CircleCI Orb Version](https://badges.circleci.com/orbs/cropster/git-release-information.svg)](https://circleci.com/developer/orbs/orb/cropster/git-release-information)
[![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/Cropster/code-release-slack-messenger-orb/main/LICENSE)

Posts the list of commits included in the latest tagged release to a Slack
channel, and stores the same list as a build artifact.

The release is the **exact git commit range between the two most recent release
tags**, resolved with git's own version sort. Messages are split automatically
to stay inside Slack's 50-block limit, and a message Slack rejects fails the
job instead of passing silently.

By default it follows Cropster's release cadence:

- **Weekly (feature) release** — a tag whose patch number is `0`. Lists every
  commit pushed since the previous week's release, including any hotfixes cut
  in between.
- **Hotfix release** — a tag whose patch number is above `0`. Lists only the
  release's own commit.

Published as [`cropster/git-release-information`](https://circleci.com/developer/orbs/orb/cropster/git-release-information).

---

## Usage

```yaml
version: 2.1

orbs:
  git-release-information: cropster/git-release-information@2.0.0

workflows:
  release-notification:
    jobs:
      - git-release-information/commit_list_notification:
          repo_name: Infrastructure
          product_label: C-SAR
          slack_webhook_env_var: SLACK_WEBHOOK_URL
          jira_base_url: "https://your-org.atlassian.net/browse"
          jira_project_keys: "CSAR, INF, DEVTASKS, CCF"
          context: slack-notifications
          # A release notification only makes sense on a release tag.
          filters:
            branches:
              ignore: /.*/
            tags:
              only: /^v[0-9]+\.[0-9]+\.[0-9]+$/
```

Set the webhook URL as a **project or context environment variable**, not in
your config. Only the variable *name* is passed to the orb, so the URL stays
out of the rendered configuration and is masked in job output.

To use the command inside a job you already have, note that it needs the tags
to be present:

```yaml
steps:
  - checkout
  - git-release-information/send_release_commit_list:
      repo_name: Infrastructure
      dry_run: true   # build and print the payloads without posting
```

## How the release range is determined

1. List tags matching `tag_pattern` (default `v*`), sorted with
   `git tag --sort=-v:refname`, so `v0.1.10` correctly outranks `v0.1.5` and
   `v10.0.0` outranks `v2.0.0`.
2. With `strict_semver_tags` (default `true`), keep only `vX.Y.Z` / `X.Y.Z`, so
   release candidates and moving tags such as `nightly` are ignored.
3. The release tag is `$CIRCLE_TAG` when the pipeline was triggered by a tag
   (override with `trigger_tag`), otherwise the highest matching tag. This
   matters for hotfixes: tagging `v1.1.1` on an older branch while `v1.2.0`
   exists still announces `v1.1.1`.
4. `release_scheme` decides where the range starts. Merge commits are always
   excluded.

With the default `release_scheme: previous_minor`, given tags
`v1.2.0`, `v1.2.1`, `v1.3.0`:

| Releasing | Kind | Range | Reported |
|---|---|---|---|
| `v1.3.0` | feature (patch `0`) | `v1.2.0..v1.3.0` | everything since the previous weekly, **including** the `v1.2.1` hotfix commit |
| `v1.2.1` | hotfix (patch > `0`) | `v1.2.0..v1.2.1`, newest only | just the hotfix commit |

With `release_scheme: previous_tag`, releasing `v1.3.0` uses `v1.2.1..v1.3.0`
and so omits the hotfix commit, and a hotfix tag gets no special handling.

`previous_minor` falls back to the preceding tag, with a warning in the job log,
when the version is not a plain `X.Y.Z`, when the minor is `0` (there is no
`<major>.<minor-1>.0`), or when the expected previous release was never tagged.
If only one tag exists, the full history up to it is used.

Because this is a commit range rather than a timestamp comparison, the commit
set does not depend on committer timezones, and commits made after the tag are
never included.

## Parameters

Both the job and the command accept the same parameters.

| Parameter | Type | Default | Purpose |
|---|---|---|---|
| `repo_name` | string | `""` | Repository label in the message header |
| `product_label` | string | `""` | Optional prefix before the repo name, e.g. `C-SAR` |
| `slack_webhook_env_var` | env_var_name | `SLACK_WEBHOOK_URL` | **Name** of the variable holding the webhook URL |
| `tag_pattern` | string | `v*` | Glob for candidate release tags |
| `strict_semver_tags` | boolean | `true` | Keep only `vX.Y.Z` / `X.Y.Z` tags |
| `release_scheme` | enum | `previous_minor` | `previous_minor` (weekly/hotfix aware) or `previous_tag` |
| `jira_base_url` | string | `""` | Issue browse URL, no trailing slash. Empty disables linking |
| `jira_project_keys` | string | `""` | Comma/space separated keys to link, e.g. `CSAR, INF` |
| `trigger_tag` | string | `""` | Tag this release is for; defaults to `$CIRCLE_TAG` |
| `artifact_dir` | string | `./artifacts` | Where the plain-text list is written |
| `blocks_per_message` | integer | `45` | Blocks per Slack message, 1–50 |
| `fetch_tags` | boolean | `true` | Run `git fetch --tags --force` first |
| `send_delay` | integer | `1` | Seconds between messages (webhook rate limit) |
| `dry_run` | boolean | `false` | Build and print payloads without posting |

The job additionally accepts `executor_tag` (default `2026.07`) to pin the
`cimg/base` image.

Jira linking is off unless **both** `jira_base_url` and `jira_project_keys` are
set. The first configured key found *anywhere* in a commit subject is linked,
so `Fix a bug related to CSAR-99` links `CSAR-99`.

## Requirements

`git`, `jq` and `curl`. All three are present in `cimg/base`, which the bundled
`base` executor uses. The script checks for them and fails with a clear message
if one is missing.

## Migrating from 1.x

Version 2.0.0 is a breaking change.

- **`install_mergestat` was removed.** The orb now uses `git` directly. Delete
  any `install_mergestat` step from your config.
- **`slack_channel` is now `slack_webhook_env_var`** and takes the *name* of an
  environment variable rather than a value. Replace
  `slack_channel: $SLACK_WEBHOOK_URL` with
  `slack_webhook_env_var: SLACK_WEBHOOK_URL`.
- **The Jira base URL and project keys are no longer hardcoded.** To keep issue
  links, set `jira_base_url` and `jira_project_keys`.
- **`C-SAR` is no longer hardcoded** in the header. Pass
  `product_label: C-SAR` to keep the previous wording.
- Recommended: add tag filters to the workflow. Previously the job would run on
  branch pushes and report commits that were not part of any release.

The weekly/hotfix behaviour added in `Develop (#10)` is preserved as the default
`release_scheme: previous_minor`. Two defects in that version are fixed: the
mergestat query pointed at a hardcoded local path
(`/Users/luisrojo/git/cropster-csar-frontend`) that cannot exist in CI, and the
hotfix query spliced `LIMIT 1` into the middle of its `WHERE` clause, which
stopped excluding merge commits and left the "last commit" unordered.

## Development

The orb's logic lives in `src/scripts/send_release_commit_list.sh` rather than
inline in YAML, so it is linted by `shellcheck` and covered by a real test
suite.

```bash
./tests/run_tests.sh
```

The suite builds throwaway git repositories, points the script at a local mock
Slack webhook, and asserts on the captured payloads. It needs `bash`, `git`,
`jq` and `python3`; no network access and no Slack credentials. Run a subset by
passing a name fragment:

```bash
./tests/run_tests.sh chunking jira
```

Validate and pack the orb:

```bash
circleci orb pack src | circleci orb validate -
```

### How to contribute

We welcome [issues](https://github.com/Cropster/code-release-slack-messenger-orb/issues)
and [pull requests](https://github.com/Cropster/code-release-slack-messenger-orb/pulls).

### How to publish an update

1. Merge pull requests with the desired changes into `main`.
2. Check the current version with
   `circleci orb info cropster/git-release-information | grep Latest`.
3. Create a new [semantically versioned](https://semver.org/) tag and GitHub
   release (for example `v2.0.1`). Publishing the release triggers the
   publishing pipeline.

## Resources

- [Orb registry page](https://circleci.com/developer/orbs/orb/cropster/git-release-information)
- [Orb authoring docs](https://circleci.com/docs/orb-intro/)
- [Slack Block Kit reference](https://api.slack.com/reference/block-kit/blocks)

For anything else, contact the Infrastructure team.
