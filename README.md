# content-freshness-gate

`content-freshness-gate` is a Docker-based GitHub Action that scans markdown files, detects stale content, creates actionable issues, and optionally closes those issues after files are updated.

## Problem We Are Solving

Documentation often becomes stale faster than teams notice. Outdated docs create delivery risk by causing wrong setup steps, broken links, and inconsistent behavior between what is documented and what actually runs in production.

This action turns documentation freshness into a continuous quality gate by:

- measuring file age from git history,
- flagging warning/stale content before it becomes critical,
- opening actionable issues with clear next steps,
- and closing those issues when the document is refreshed.

## Research Background

Software engineering research shows that outdated documentation reduces developer productivity and leads to incorrect system usage.

Forward & Lethbridge (2002) — documentation is critical but often ignored
https://ieeexplore.ieee.org/document/1000682
Uddin & Robillard (2015) — API documentation frequently fails due to being outdated or incomplete
https://dl.acm.org/doi/10.1109/ICSE.2015.56

Recent work in Generative Engine Optimization (GEO) highlights that regularly updated content is more likely to be surfaced and cited by AI systems.

GEO (KDD 2024) — optimizing content for AI-generated search
https://arxiv.org/abs/2311.09735

This project builds on these insights by introducing an automated system to detect and surface stale documentation using version control history.

## Features

- Scans markdown paths from configurable glob patterns.
- Classifies files as:
  - `WARNING` when older than `warn-days`
  - `STALE` when older than `stale-days`
- Creates issues with labels and actionable checklists.
- Avoids duplicate issues using an embedded marker per file.
- Optionally assigns issue to likely last author.
- Optionally auto-closes managed issues after updates.
- Handles empty git history, missing/deleted files, and API rate-limit scenarios.
- Includes `dry-run` and `debug` modes.

## Project Structure

```text
content-freshness-gate/
├── action.yml
├── entrypoint.sh
├── Dockerfile
├── README.md
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `paths` | Yes | - | Comma-separated glob patterns (example: `docs/**/*.md,README.md`) |
| `stale-days` | No | `90` | File age (in days) above which a file is `STALE` |
| `warn-days` | No | `60` | File age (in days) above which a file is `WARNING` |
| `max-issues-per-run` | No | `5` | Maximum new issues to create in one run |
| `create-issues` | No | `true` | Create issues for stale/warning files |
| `assign-last-author` | No | `true` | Try assigning issue to last author |
| `close-on-update` | No | `true` | Close managed issue if the file is updated later |
| `github-model` | No | `gpt-4o-mini` | Model hint text included in suggestion section |
| `dry-run` | No | `false` | Log actions without writing via API |
| `debug` | No | `false` | Enable verbose debug logs |

## Outputs

| Output | Description |
| --- | --- |
| `files-scanned` | Number of files scanned |
| `stale-detected` | Number of stale files detected |
| `warning-detected` | Number of warning files detected |
| `issues-created` | Number of issues created |
| `issues-closed` | Number of issues closed |

## Required Permissions

Use these permissions in your workflow:

```yaml
permissions:
  contents: read
  issues: write
```

## Usage

```yaml
name: Content Freshness Gate

on:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:

jobs:
  freshness:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run content-freshness-gate
        uses: ./
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          paths: "docs/**/*.md,README.md"
          stale-days: "90"
          warn-days: "60"
          max-issues-per-run: "5"
          create-issues: "true"
          assign-last-author: "true"
          close-on-update: "true"
          github-model: "gpt-4o-mini"
          dry-run: "false"
          debug: "false"
```

## Issue Behavior

- Managed issues include a hidden marker in the body:
  - `<!-- content-freshness-gate:file=<path> -->`
- This marker is used to:
  - prevent duplicates for the same file
  - find and close matching issues after content updates
- Warning issues can be escalated to stale issues when a file crosses `stale-days`.

## Notes

- Ensure the workflow has full git history (`fetch-depth: 0`) so `git log` returns correct results.
- Assigning by email is heuristic-based and may fall back to no assignee.
- If API rate limits are hit, the action logs and skips additional writes.
