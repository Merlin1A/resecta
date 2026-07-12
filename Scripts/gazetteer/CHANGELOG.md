# Gazetteer Changelog

## 0.1.0

- Scaffold: build script, manifest schema, golden-file test infrastructure.
- Binary format RSBF v1 with MurmurHash3_x64_128 double-hashing (k=10).
- Python `build_bloom.py` with `--golden` mode for cross-language testing.
- Swift `BloomFilter`, `NameGazetteer`, `GazetteerManifest` types.
- No production data bundled yet (see README.md for data acquisition).
