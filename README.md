# neutils

Modern CLI utilities for everyday developer tasks.

![urlparse demo](demo/urlparse.gif)

## Philosophy

- Each tool does one thing well
- Instant startup, minimal memory
- Consistent interface: `--help`, `--version`, `--json`
- Plain text by default

## Installation

### From source

Requires [Zig](https://ziglang.org/) 0.15+.

```bash
git clone https://github.com/deevus/neutils
cd neutils
zig build -Doptimize=ReleaseSmall
```

Binaries in `zig-out/bin/`.

### Pre-built binaries

Download from [GitHub Releases](https://github.com/deevus/neutils/releases) for Linux, macOS, and Windows (x86_64 and aarch64).

## Tools

| Tool | Description |
|------|-------------|
| `urlparse` | Parse and display URL components |

## Usage

### urlparse

```bash
urlparse "https://user:pass@example.com:8080/path?q=1&lang=en#top"
```

```json
{
  "scheme": "https",
  "user": "user",
  "password": "pass",
  "host": "example.com",
  "port": 8080,
  "path": "/path",
  "query": "q=1&lang=en",
  "queryParams": {
    "q": "1",
    "lang": "en"
  },
  "fragment": "top"
}
```

```bash
# JSON output
urlparse --json "https://example.com/api?page=2"

# Markdown table output
urlparse --markdown "https://example.com/api?page=2"

# Extract a single field
urlparse --field host "https://example.com/path"
```

## Development

```bash
# Use mise for tooling
mise install

# Build all tools
zig build

# Build single tool
zig build urlparse
```

## License

MIT
