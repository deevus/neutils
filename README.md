# neutils

Modern CLI utilities for everyday developer tasks.

## Philosophy

- Each tool does one thing well
- Instant startup, minimal memory
- Consistent interface: `--help`, `--version`, `--json`
- Plain text by default

## Installation

Requires [Zig](https://ziglang.org/) 0.15+.

```bash
git clone https://github.com/yourusername/neutils
cd neutils
zig build -Doptimize=ReleaseSmall
```

Binaries in `zig-out/bin/`.

## Tools

| Tool | Description |
|------|-------------|
| `urlparse` | Parse and display URL components |

## Usage

### urlparse

```bash
urlparse "https://user:pass@example.com:8080/path?q=1#top"

urlparse --json "https://example.com/api"

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
