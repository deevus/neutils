# neutils

Modern CLI utilities for everyday developer tasks.

![urlparse demo](src/tools/urlparse/demo/demo.gif)

## Philosophy

- Each tool does one thing well
- Instant startup, minimal memory
- Consistent interface

## Installation

### From source

Requires [Zig](https://ziglang.org/) 0.15+.

```bash
git clone https://github.com/deevus/neutils
cd neutils
zig build --release=small
```

Binaries in `zig-out/bin/`.

### Pre-built binaries

Download from [GitHub Releases](https://github.com/deevus/neutils/releases) for Linux, macOS, and Windows (x86_64 and aarch64).

## Tools

| Tool | Description |
|------|-------------|
| [`urlparse`](src/tools/urlparse/README.md) | Parse and display URL components |
| [`urlencode`](src/tools/urlencode/README.md) | Percent-encode a string for use in URLs |
| [`mbox-diff`](src/tools/mbox-diff/README.md) | Find new emails between two mbox files |
| [`mbox-index`](src/tools/mbox-index/README.md) | Build an index of an mbox file by message identifier |
| [`mbox-gen`](src/tools/mbox-gen/README.md) | Generate synthetic mbox files for testing |

## Usage

### urlparse

```bash
# Default: rendered markdown on a TTY, raw markdown when piped
urlparse "https://user:pass@example.com:8080/path?q=1&lang=en#top"

# JSON output
urlparse --output-format json "https://example.com/api?page=2"
```

```json
{
  "scheme": "https",
  "host": "example.com",
  "path": "/api",
  "query": "page=2",
  "queryParams": {
    "page": "2"
  }
}
```

```bash
# Markdown table output
urlparse --output-format markdown "https://example.com/api?page=2"

# Extract a single field
urlparse --field host "https://example.com/path"
```

### urlencode

```bash
urlencode "hello world"
# hello%20world

urlencode "price=10&currency=€"
# price%3D10%26currency%3D%E2%82%AC
```

### mbox-diff

Compare two mbox files and output only the new messages (by Message-ID) from the second file that don't exist in the first.

```bash
# Write new emails to a file
mbox-diff base.mbox new.mbox -o diff.mbox

# Example: sync a mailbox incrementally
mbox-diff yesterday.mbox today.mbox -o new-messages.mbox
```

### mbox-index

Build an index mapping message identifiers to byte offsets. Messages without a `Message-ID` header are keyed by the SHA-256 of their contents.

```bash
# Write index next to the mbox (mail.mbox → mail.mbox-index)
mbox-index mail.mbox

# Write index to an explicit location
mbox-index -o mail.idx mail.mbox
```

### mbox-gen

Generate synthetic mbox files for testing and benchmarking.

```bash
# Generate a 100 MB mbox
mbox-gen --size 100M out.mbox

# Reproducible 1 GiB fixture with larger message bodies
mbox-gen --size 1GiB --seed 42 --body-size 4096 fixture.mbox

# Simulate missing Message-IDs on 20% of messages
mbox-gen --size 10M --with-id-ratio 0.8 partial.mbox
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
