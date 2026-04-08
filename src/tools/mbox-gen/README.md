# mbox-gen

Generate synthetic mbox files for testing and benchmarking.

## Usage

```
mbox-gen [OPTIONS] <output>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `output` | Destination mbox file |

## Options

| Option | Short | Description |
|--------|-------|-------------|
| `--size` | `-s` | Target output size (e.g. `100M`, `1GiB`, `4096`) — required |
| `--seed` |  | PRNG seed (default `0`) |
| `--body-size` |  | Body bytes per message (default `1024`) |
| `--with-id-ratio` |  | Fraction of messages that include a `Message-ID` header, in `[0.0, 1.0]` (default `1.0`) |
| `--force` | `-f` | Overwrite the output file if it exists |

## Examples

```bash
# Generate a 100 MB mbox
mbox-gen --size 100M out.mbox

# Reproducible 1 GiB fixture with larger message bodies
mbox-gen --size 1GiB --seed 42 --body-size 4096 fixture.mbox

# Simulate missing Message-IDs on 20% of messages
mbox-gen --size 10M --with-id-ratio 0.8 partial.mbox

# Overwrite an existing file
mbox-gen --size 50M --force out.mbox
```
