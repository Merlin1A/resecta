# Gazetteer Build Pipeline

Builds Bloom filter binary files (`.bloom`) for the Resecta name gazetteer
from public-domain and CC0-licensed name datasets.

## Data Sources

| File | Source | License (SPDX) | Description |
|------|--------|-----------------|-------------|
| `census-2010-surnames.csv` | U.S. Census Bureau | Public domain | ~150K surnames with ethnicity columns |
| `census-spanish-surnames.csv` | U.S. Census Bureau | Public domain | ~12K Spanish-origin surnames |
| `ssa-baby-names/` | Social Security Administration | CC0-1.0 | ~100K given names (yob1880–present) |
| `paranames-per.tsv` | ParaNames (Wikidata) | CC0-1.0 | PER entities, sitelinks ≥ 5 |
| `popular-names-by-country.csv` | sigpwned | CC0-1.0 | ~50K names across countries |

Place downloaded files in `sources/` before running the build.

## Known Coverage Limitation

No permissively-licensed dataset for Indigenous and Native American names
is bundled in this release. The gazetteer is designed to supplement — not
replace — other detection signals (NLTagger, context scoring, entity
clustering). Coverage for underrepresented name populations may be lower
than for populations well-represented in Census and SSA data.

## Build Instructions

### Prerequisites

```bash
pip install -r requirements.txt
```

### Generate golden test file (no raw data needed)

```bash
python build_bloom.py --golden \
    --output-dir ../../Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources
```

### Build production filters (requires downloaded sources)

```bash
python build_bloom.py \
    --sources-dir ./sources \
    --output-dir ../../Packages/RedactionEngine/Sources/RedactionEngine/Resources/Gazetteers \
    --manifest-version 1.0.0
```

### Validate FPR (after building)

```bash
python fpr_validation.py \
    --filters-dir ../../Packages/RedactionEngine/Sources/RedactionEngine/Resources/Gazetteers
```

## Binary Format (RSBF v1)

See `BloomFilter.swift` for the full specification. Summary:

- 63-byte header: magic "RSBF", version, k, m, seed, row count, SHA-256
- Body: ⌈m/8⌉ bytes, little-endian bit ordering
- Hash: MurmurHash3_x64_128, Kirsch-Mitzenmacher double-hashing
- Normalization: NFKC + lowercase + UTF-8 before hashing

## Versioning

See `CHANGELOG.md`. The manifest includes a semantic version string.
Version 0.1.0 = scaffold (no production data). Version 1.0.0 = first
production build with all sources.
