# og-check

Fetch a URL and render its OpenGraph / Twitter Card metadata, and validate that the required fields are present.

![og-check screenshot](images/screenshot.png)

## Usage

```
og-check [OPTIONS] <url>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `url` | URL to fetch and inspect |

## Options

| Option | Short | Description |
|--------|-------|-------------|
| `--output-format` | `-o` | Preview format (`opengraph`, `twitter`, `table`, `json`, `none`) |
| `--issue-format` | `-f` | Validation issue format (`human`, `json`, `ci`) |

## Output streams

`og-check` writes two independent streams:

- **stdout** — the "success story": a preview of the page's metadata, shaped by `--output-format`.
- **stderr** — the "failure story": validation issues, shaped by `--issue-format`.

As a convenience for pipelines, `--issue-format json` is emitted on **stdout** when `--output-format none` (i.e. when nothing else would be written to stdout). This lets `| jq …` work on the issue report without shell redirection.

The process exits with status `1` if any errors were reported; warnings alone do not fail the run.

## Preview formats (`--output-format`)

| Value | Description |
|-------|-------------|
| `opengraph` | Styled preview of `og:*` fields (default in a terminal) |
| `twitter` | Styled preview of `twitter:*` fields, falling back to `og:*` |
| `table` | All meta tags as a markdown table, grouped by namespace |
| `json` | All meta tags as a JSON document, grouped by namespace |
| `none` | Skip the preview entirely (default under CI) |

The chosen format also selects which schema(s) are validated:

- `opengraph` → validates OpenGraph required fields (`og:title`, `og:image`, `og:type`, `og:url`)
- `twitter` → validates Twitter Card required fields (`twitter:card`, and a title/image from either namespace)
- `table`, `json`, `none` → validates both schemas

## Issue formats (`--issue-format`)

| Value | Description |
|-------|-------------|
| `human` | Markdown with ✅ / ❌ / ⚠️ glyphs, grouped by schema (default in a terminal) |
| `ci` | GitHub / Forgejo Actions workflow commands (`::error title=…::…`) — default under CI |
| `json` | Linter-style JSON document with `tool`, `version`, `status`, `summary`, `issues[]` |

## CI auto-detection

When the `GITHUB_ACTIONS` or `FORGEJO_ACTIONS` environment variable is set, `og-check` defaults to:

- `--output-format none` — no preview noise in the job log
- `--issue-format ci` — annotations surface inline on the PR

Either default can be overridden by passing the flag explicitly.

> **Note**: Inline images (`og:image`, `twitter:image`) are only displayed when your terminal supports the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/). In other terminals, only the image URL is shown.

## Examples

```bash
# Default: rendered OpenGraph preview, human-readable issues
og-check https://github.com/deevus/neutils

# Twitter Card preview (falls back to og:* fields when twitter:* are absent)
og-check -o twitter https://github.com/deevus/neutils

# All meta tags as a table, grouped by namespace
og-check -o table https://github.com/deevus/neutils

# Machine-readable preview
og-check -o json https://github.com/deevus/neutils

# CI mode: no preview, workflow-command annotations on stderr
og-check -o none -f ci https://github.com/deevus/neutils

# Structured JSON issue report (suitable for piping into jq)
og-check -o none -f json https://github.com/deevus/neutils
```
