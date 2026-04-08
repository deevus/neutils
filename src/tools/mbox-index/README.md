# mbox-index

Build an index of an mbox file mapping message identifiers to byte offsets.
Messages without a `Message-ID` header are keyed by the SHA-256 hash of their
contents instead.

## Usage

```
mbox-index [OPTIONS] <mbox>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `mbox` | Mbox file to index |

## Options

| Option | Short | Description |
|--------|-------|-------------|
| `--output` | `-o` | Output file (default: `<mbox-basename>.mbox-index` next to the input) |

## Examples

```bash
# Write index next to the mbox (mail.mbox → mail.mbox-index)
mbox-index mail.mbox

# Write index to an explicit location
mbox-index -o mail.idx mail.mbox
```
