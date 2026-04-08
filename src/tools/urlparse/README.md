# urlparse

Parse and display URL components.

![urlparse demo](demo/demo.gif)

## Usage

```
urlparse [OPTIONS] <url>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `url` | URL to parse |

## Options

| Option | Short | Description |
|--------|-------|-------------|
| `--output-format` | `-o` | Output format (`json`, `markdown`) |
| `--field` | `-f` | Extract a single field (`scheme`, `user`, `password`, `host`, `port`, `path`, `query`, `fragment`) |

When `--output-format` is omitted, `urlparse` renders a styled markdown view if stdout is a TTY, and raw markdown otherwise (so piping to another tool gives you plain text).

## Examples

```bash
# Default output
urlparse "https://user:pass@example.com:8080/path?q=1&lang=en#top"

# JSON output
urlparse --output-format json "https://example.com/api?page=2"

# Markdown table output
urlparse --output-format markdown "https://example.com/api?page=2"

# Extract a single field
urlparse --field host "https://example.com/path"
```
