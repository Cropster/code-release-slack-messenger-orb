# Orb source layout

Orbs ship as a single packed `orb.yml`, but are authored here in _unpacked_
form and packed by the CircleCI CLI:

```bash
circleci orb pack src | circleci orb validate -
```

| Path | Contents |
|---|---|
| `@orb.yml` | Entry point: `version`, `description`, `display` |
| `commands/` | One file per command; the filename is the command name |
| `jobs/` | One file per job |
| `executors/` | One file per executor |
| `examples/` | Usage examples rendered on the orb registry page |
| `scripts/` | Shell scripts inlined into commands via `<<include()>>` |

## scripts/

Command logic lives in `scripts/` rather than inline in YAML for two reasons:
`shellcheck` can lint a real `.sh` file, and the script can be executed
directly by `tests/run_tests.sh` without packing or publishing the orb.

A command pulls one in with an include directive, whose path is relative to
this `src/` directory:

```yaml
steps:
  - run:
      name: Send release commit list to Slack
      environment:
        RELEASE_REPO_NAME: "<< parameters.repo_name >>"
      command: <<include(scripts/send_release_commit_list.sh)>>
```

Parameters are passed through the `environment:` block rather than substituted
into the command text. A parameter value therefore arrives as data in an
environment variable and is never evaluated as shell code.

## See also

- [Orb author intro](https://circleci.com/docs/orb-author-intro/)
- [Reusable configuration reference](https://circleci.com/docs/reusing-config/)
