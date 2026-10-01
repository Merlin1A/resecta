# Golden-file Bloom builder

Builds the golden-file Bloom filter that the engine's Bloom-filter and
name-gazetteer tests read
(`Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources/golden-1000.bloom`);
`BloomFilterTests` is the cross-language check of the format. The production
filters the app ships are built and signed by
[resecta-datapipeline](https://github.com/Merlin1A/resecta-datapipeline), not here.

## Scaffold inputs

The scaffold's optional raw inputs (placed in `sources/`) are:

| File | Source | License (SPDX) | Description |
|------|--------|-----------------|-------------|
| `census-2010-surnames.csv` | U.S. Census Bureau | Public domain | Surnames with race and ethnicity columns |
| `census-spanish-surnames.csv` | U.S. Census Bureau | Public domain | Spanish-origin surnames |
| `ssa-baby-names/` | Social Security Administration | Public domain | Given names, one `yob*.txt` file per birth year |
| `popular-names-by-country.csv` | sigpwned | CC0-1.0 | Popular given names and surnames by country |

These are scaffold inputs only. The shipped filters' sources are listed in the
signed `gazetteer-manifest.json` and in the pipeline's `SOURCES.md`.

## Known coverage limitation

No permissively-licensed dataset for Indigenous and Native American names
is bundled in this release. The gazetteer is designed to supplement — not
replace — other detection signals (NLTagger, context scoring, entity
clustering). Coverage for underrepresented name populations may be lower
than for populations well-represented in Census and SSA data.

## Build instructions

### Prerequisites

```bash
pip install -r requirements.txt
```

### Generate the golden test file (no raw data needed)

```bash
python build_bloom.py --golden \
    --output-dir ../../Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources
```

### Production filters — built by resecta-datapipeline

The shipped filters are built by resecta-datapipeline (seed 20260416, signed
manifest). Do not point `--output-dir` at `Resources/Gazetteers/`: this script
writes a manifest without `assets[]` or a signature, which the shipped-asset
hash check and the runtime signature check both refuse.

## Binary format (RSBF v1)

See `Packages/RedactionEngine/Sources/RedactionEngine/Detection/Gazetteer/BloomFilter.swift`
for the full specification. Summary:

- 63-byte header: magic "RSBF", version, k, m, seed, row count, SHA-256
- Body: ⌈m/8⌉ bytes, little-endian bit ordering
- Hash: MurmurHash3_x64_128, Kirsch-Mitzenmacher double-hashing
- Normalization: NFKC + lowercase + UTF-8 before hashing

## Versioning

See `CHANGELOG.md`. The shipped manifest version (now 1.1.0) is set by
resecta-datapipeline; this scaffold stays at 0.1.0.
