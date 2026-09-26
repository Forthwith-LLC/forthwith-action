# Forthwith localization PR action

This companion to the [read-only check action](../README.md) runs the pinned
Forthwith CLI on the repository's default branch, then creates or updates one
`forthwith/localize` pull request. It never merges the PR. Do **not** call it
from `pull_request`, `pull_request_target`, or `workflow_run` on untrusted code.

## Setup

Copy the [localization PR workflow template](https://github.com/Forthwith-LLC/forthwith-docs/blob/main/github-actions/forthwith-localize.yml)
to `.github/workflows/forthwith-localize.yml`. Replace the two action SHA
placeholders, set the default branch name, and choose an explicit
`max-strings` value. Commit a valid `.forthwith.yml` at the repository root.

Add `FORTHWITH_TOKEN` as an Actions secret. This is a Forthwith API token; do
not put it in the workflow file. The current token is user-owned. A dedicated
automation identity and server-side budget controls are planned separately.
The `max-strings` input limits distinct source entries per run, **not** cost
or usage across target languages.

The workflow grants only `contents: write` and `pull-requests: write`. In
repository or organization Actions settings, allow Actions to create pull
requests. The default `GITHUB_TOKEN` is enough to create the branch and PR.
GitHub [runs `pull_request` checks from a `GITHUB_TOKEN`-created PR only after
a maintainer approves them](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow#triggering-a-workflow-from-a-workflow).
If the localization PR needs its read-only check to run automatically,
provide a fine-grained PAT as `FORTHWITH_GITHUB_TOKEN` with access limited to
this repository and Contents and Pull requests write permissions. The
template uses that token for checkout, branch updates, and PR creation;
otherwise it falls back to `github.token`. A GitHub App can also be used, but
its [installation token expires after one hour](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app),
so long-running translation workflows need a token-refresh design; do not
store a one-time installation token as a static repository secret.

## Behavior

- Runs only for `push` or manual dispatch on the repository's default branch.
- Downloads an exact Linux x64 CLI release and verifies it with the release
  checksum before execution.
- Uses Ruby's standard YAML parser to ensure a generated first-run `project_id`
  is the only semantic change to `.forthwith.yml`. The pinned
  [Ubuntu 24.04 runner image](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)
  includes Ruby; self-hosted runners must provide it alongside Bash, Git,
  `gh`, `jq`, `curl`, `tar`, and `sha256sum`.
- Translates with `--json --yes --force --max-strings`, so no interactive prompt
  can hang CI.
- Rebases an existing localization branch onto the latest default branch
  **before** starting a paid translation. This preserves its unmerged
  translations and `.forthwith.lock`. A conflict fails before translation;
  it must be resolved by a maintainer.
- Commits only files listed by the CLI in `files_updated`, `.forthwith.lock`,
  and a first-run `.forthwith.yml` `project_id` update. Unexpected files fail
  the run.
- Opens or updates one PR, with source SHA, target languages, translated
  count, changed files, and a machine-generated-review notice.
- If some translations fail but the CLI reports usable partial results, the
  completed files are saved in the PR and the workflow fails for attention.
  CLI-level errors publish nothing.
- Never pushes to the default branch or merges the PR.

The branch name `forthwith/localize` is reserved for this workflow. Do not
push unrelated changes to it. If its PR is closed without merging, resolve or
delete that branch before rerunning. Enable GitHub's automatic head-branch
deletion so a merged PR does not leave a stale branch. The action rebases this
branch and uses a guarded force-push when the default branch advances, so any
branch rule for `forthwith/localize` must allow that update.

`FORTHWITH_AUTH_TOKEN` and `GH_TOKEN` must be supplied as environment
variables. Do not pass either as an action input or command-line argument.
