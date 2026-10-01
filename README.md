# Forthwith localization check action

This read-only GitHub Action runs `forthwith check --json`, writes a GitHub
step summary, and adds file/line annotations for diagnostics. It never reads
or needs `FORTHWITH_AUTH_TOKEN`; use it on pull requests, including fork PRs.

For default-branch translation and a reviewable PR, use the separate
[localization PR action](localize/README.md). It requires credentials and must
never run on untrusted pull-request code.

Start with the public, copyable [pull-request check workflow](examples/forthwith-check.yml)
and [localization PR workflow](examples/forthwith-localize.yml). The localization
example is manual-only until you opt into its commented push trigger.

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
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<PINNED_SHA>
      - uses: Forthwith-LLC/forthwith-action@<PINNED_SHA>
        with:
          cli-version: latest
          warnings-as-errors: "false"
```

Replace both placeholders with immutable commit SHAs before using this in a
production repository. `latest` resolves the newest published CLI release on
each run; the job log, summary, and `cli-version` output show the exact version
used. Set an exact tag instead if you want reproducible checks or to review CLI
upgrades before adopting them. The paid localization PR example stays pinned
to an exact CLI version.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `cli-version` | `v1.0.3` | Exact Forthwith CLI release tag or `latest`. |
| `working-directory` | `.` | Project directory containing `.forthwith.yml`. |
| `warnings-as-errors` | `false` | Fail when warnings are reported. |
| `annotate` | `true` | Emit at most 50 workflow annotations. |
| `write-summary` | `true` | Add the complete report to the job summary. |

Outputs include `status`, `errors`, `warnings`, `cli-version`, `report-path`,
and `sarif-path`.

The action also writes a SARIF 2.1.0 report and exposes its absolute path as
the `sarif-path` output. To publish diagnostics in GitHub code scanning, add
the upload step below and grant `security-events: write` to the workflow. The
upload step is optional; keeping the default workflow at `contents: read`
preserves its least-privilege, fork-PR setup.

```yaml
permissions:
  contents: read
  security-events: write

steps:
  - uses: actions/checkout@<PINNED_SHA>
  - id: forthwith
    uses: Forthwith-LLC/forthwith-action@<PINNED_SHA>
  - if: always() && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.fork == false)
    uses: github/codeql-action/upload-sarif@<PINNED_SHA>
    with:
      sarif_file: ${{ steps.forthwith.outputs.sarif-path }}
```

GitHub may reject code-scanning uploads from fork pull requests because the
workflow token is read-only there. Keep the ordinary check and annotations as
the fork-safe feedback path; enable SARIF upload where the repository's
permissions and code-scanning configuration allow it.

The action currently supports GitHub-hosted Linux x64 runners. It downloads
the matching release archive and verifies it against that release's
`checksums.txt` before execution.

## Required check

After the workflow has run once, repository administrators can require its
stable job name, `Forthwith localization`, in their branch protection rule or
ruleset. This action deliberately does not attempt to alter branch protection.
