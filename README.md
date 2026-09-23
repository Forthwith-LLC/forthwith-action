# Forthwith localization check action

This read-only GitHub Action runs `forthwith check --json`, writes a GitHub
step summary, and adds file/line annotations for diagnostics. It never reads
or needs `FORTHWITH_AUTH_TOKEN`; use it on pull requests, including fork PRs.

The action is MIT licensed. The Forthwith CLI downloaded by the action is
separate proprietary software and remains subject to its own license.

## Usage

```yaml
name: Forthwith localization

on:
  pull_request:
    paths:
      - ".forthwith.yml"
      - "**/*.json"
      - "**/*.xml"
      - "**/*.strings"
      - "**/*.stringsdict"
      - "**/*.po"

permissions:
  contents: read

jobs:
  check:
    name: Forthwith localization
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<PINNED_SHA>
      - uses: Forthwith-LLC/forthwith-action@<PINNED_SHA>
        with:
          cli-version: v1.0.1
          warnings-as-errors: "false"
```

Replace both placeholders with immutable commit SHAs before using this in a
production repository. The CLI release version is intentionally a separate,
exact tag so customers control upgrades.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `cli-version` | `v1.0.1` | Exact Forthwith CLI release tag. |
| `working-directory` | `.` | Project directory containing `.forthwith.yml`. |
| `warnings-as-errors` | `false` | Fail when warnings are reported. |
| `annotate` | `true` | Emit at most 50 workflow annotations. |
| `write-summary` | `true` | Add the complete report to the job summary. |

The action currently supports GitHub-hosted Linux x64 runners. It downloads
the matching release archive and verifies it against that release's
`checksums.txt` before execution.

## Required check

After the workflow has run once, repository administrators can require its
stable job name, `Forthwith localization`, in their branch protection rule or
ruleset. This action deliberately does not attempt to alter branch protection.
