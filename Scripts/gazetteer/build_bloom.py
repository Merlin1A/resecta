#!/usr/bin/env python3
"""
Build Bloom filter binary files (.bloom) from name source CSVs/TSVs.

Usage:
    python build_bloom.py --sources-dir ./sources \
        --output-dir ../../Packages/RedactionEngine/Sources/RedactionEngine/Resources/Gazetteers \
        --manifest-version 0.1.0

    # Generate golden test file from built-in 1,000-name list:
    python build_bloom.py --golden \
        --output-dir ../../Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources

Binary format (RSBF):
    Header (63 bytes):
      [0..3]    Magic "RSBF" (4 bytes ASCII)
      [4..5]    Version (u16 LE) = 1
      [6]       k (u8) — number of hash functions
      [7..14]   m (u64 LE) — number of bits
      [15..22]  Seed (u64 LE)
      [23..30]  Row count (u64 LE)
      [31..62]  SHA-256 of sorted, NFKC-lowercased source rows (32 bytes)
    Body:
      [63..]    Bit array, ceil(m/8) bytes, LE bit ordering

Cross-language consistency:
    - Keys are NFKC-normalized + lowercased + UTF-8 encoded before hashing
    - MurmurHash3_x64_128 with seed (lower 32 bits used by hash)
    - Double-hashing: pos_i = ((h1 + i * h2) & 0xFFFFFFFFFFFFFFFF) % m
    - Python and Swift must produce identical bit arrays for identical inputs
"""

import argparse
import csv
import hashlib
import json
import math
import struct
import sys
import unicodedata
from pathlib import Path

try:
    import mmh3
except ImportError:
    print("ERROR: mmh3 not installed. Run: pip install mmh3>=4.0", file=sys.stderr)
    sys.exit(1)

# --- Constants ---

MAGIC = b"RSBF"
VERSION = 1
SEED = 42
K = 10  # Number of hash functions
TARGET_FPR = 0.001  # 0.1%
MASK64 = 0xFFFFFFFFFFFFFFFF


# --- Bloom filter construction ---

def optimal_m(n: int, fpr: float) -> int:
    """Compute optimal bit count for given n and target FPR."""
    if n <= 0:
        return 64  # minimum
    m = math.ceil(-n * math.log(fpr) / (math.log(2) ** 2))
    return max(m, 64)


def normalize_key(name: str) -> str:
    """NFKC normalize and lowercase a name string."""
    return unicodedata.normalize("NFKC", name).lower()


def hash_key(key: str, seed: int) -> tuple[int, int]:
    """Hash a normalized key with MurmurHash3_x64_128.

    Returns (h1, h2) as unsigned 64-bit integers.
    """
    key_bytes = key.encode("utf-8")
    # mmh3.hash128 returns unsigned 128-bit integer (mmh3 v4+)
    full = mmh3.hash128(key_bytes, seed=seed, signed=False)
    h1 = full & MASK64
    h2 = (full >> 64) & MASK64
    return h1, h2


def build_filter(names: list[str], seed: int = SEED, k: int = K,
                 fpr: float = TARGET_FPR) -> tuple[bytearray, int]:
    """Build a Bloom filter bit array from a list of normalized names.

    Returns (bit_array, m) where m is the number of bits.
    """
    n = len(names)
    m = optimal_m(n, fpr)
    byte_count = (m + 7) // 8
    bits = bytearray(byte_count)

    for name in names:
        h1, h2 = hash_key(name, seed)
        for i in range(k):
            pos = ((h1 + i * h2) & MASK64) % m
            bits[pos // 8] |= 1 << (pos % 8)

    return bits, m


def source_hash(names: list[str]) -> bytes:
    """SHA-256 of sorted, NFKC-lowercased source rows."""
    h = hashlib.sha256()
    for name in sorted(names):
        h.update(name.encode("utf-8"))
        h.update(b"\n")
    return h.digest()


def write_bloom(path: Path, names: list[str], seed: int = SEED, k: int = K,
                fpr: float = TARGET_FPR) -> dict:
    """Write a .bloom file and return metadata dict."""
    bits, m = build_filter(names, seed, k, fpr)
    sha = source_hash(names)
    n = len(names)

    header = bytearray()
    header.extend(MAGIC)
    header.extend(struct.pack("<H", VERSION))
    header.append(k)
    header.extend(struct.pack("<Q", m))
    header.extend(struct.pack("<Q", seed))
    header.extend(struct.pack("<Q", n))
    header.extend(sha)

    assert len(header) == 63, f"Header size mismatch: {len(header)}"

    with open(path, "wb") as f:
        f.write(header)
        f.write(bits)

    return {"n": n, "m": m, "k": k, "fpr_target": fpr, "size_bytes": 63 + len(bits)}


# --- Golden file generation ---

# Deterministic 1,000-name list for cross-language testing.
# Names chosen to cover: ASCII, accented, multi-word, short, long.
GOLDEN_NAMES = sorted(set(normalize_key(n) for n in [
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
    "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
    "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin",
    "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez", "Clark",
    "Ramirez", "Lewis", "Robinson", "Walker", "Young", "Allen", "King",
    "Wright", "Scott", "Torres", "Nguyen", "Hill", "Flores", "Green",
    "Adams", "Nelson", "Baker", "Hall", "Rivera", "Campbell", "Mitchell",
    "Carter", "Roberts", "Gomez", "Phillips", "Evans", "Turner", "Diaz",
    "Parker", "Cruz", "Edwards", "Collins", "Reyes", "Stewart", "Morris",
    "Morales", "Murphy", "Cook", "Rogers", "Gutierrez", "Ortiz", "Morgan",
    "Cooper", "Peterson", "Bailey", "Reed", "Kelly", "Howard", "Ramos",
    "Kim", "Cox", "Ward", "Richardson", "Watson", "Brooks", "Chavez",
    "Wood", "James", "Bennett", "Gray", "Mendoza", "Ruiz", "Hughes",
    "Price", "Alvarez", "Castillo", "Sanders", "Patel", "Myers", "Long",
    "Ross", "Foster", "Jimenez", "Powell", "Jenkins", "Perry", "Russell",
    "Sullivan", "Bell", "Coleman", "Butler", "Henderson", "Barnes",
    "Gonzales", "Fisher", "Vasquez", "Simmons", "Griffin", "McDaniel",
    "Washington", "Begay", "Yazzie", "Benally", "Tsosie", "Nez",
    "Blackhorse", "Yellowhair", "Redhorse", "Whitefeather", "Stonecrow",
    "Chen", "Wang", "Li", "Zhang", "Liu", "Yang", "Huang", "Wu", "Zhou",
    "Xu", "Sun", "Ma", "Zhu", "Hu", "Guo", "Lin", "He", "Gao", "Luo",
    "Zheng", "Liang", "Xie", "Song", "Tang", "Han", "Deng", "Feng",
    "Tanaka", "Suzuki", "Takahashi", "Watanabe", "Ito", "Yamamoto",
    "Nakamura", "Kobayashi", "Saito", "Kato", "Yoshida", "Yamada",
    "Sasaki", "Yamaguchi", "Matsumoto", "Inoue", "Kimura", "Shimizu",
    "Hayashi", "Mori", "Abe", "Ikeda", "Hashimoto", "Ogawa", "Ishikawa",
    "Park", "Choi", "Jung", "Kang", "Cho", "Yoon", "Jang", "Lim",
    "Yoo", "Shin", "Oh", "Seo", "Kwon", "Bae", "Ryu", "Moon", "Song",
    "Ahn", "Hwang", "Jeon", "Ko", "Ha", "Yun", "Noh", "Woo",
    "Mueller", "Schmidt", "Schneider", "Fischer", "Weber", "Meyer",
    "Wagner", "Becker", "Schulz", "Hoffmann", "Schaefer", "Koch",
    "Bauer", "Richter", "Klein", "Wolf", "Schroeder", "Neumann",
    "Schwarz", "Zimmermann", "Braun", "Krueger", "Hofmann", "Hartmann",
    "Dubois", "Moreau", "Laurent", "Simon", "Michel", "Lefevre",
    "Leroy", "Roux", "David", "Bertrand", "Morel", "Fournier",
    "Girard", "Bonnet", "Dupont", "Lambert", "Fontaine", "Rousseau",
    "Vincent", "Muller", "Guerin", "Boyer", "Garnier", "Chevalier",
    "Rossi", "Russo", "Ferrari", "Esposito", "Bianchi", "Romano",
    "Colombo", "Ricci", "Marino", "Greco", "Bruno", "Gallo",
    "Conti", "DeLuca", "Costa", "Giordano", "Mancini", "Rizzo",
    "Silva", "Santos", "Ferreira", "Pereira", "Oliveira", "Souza",
    "Rodrigues", "Almeida", "Nascimento", "Lima", "Araujo", "Fernandes",
    "Carvalho", "Gomes", "Martins", "Rocha", "Ribeiro", "Alves",
    "Monteiro", "Cardoso", "Teixeira", "Correia", "Dias", "Freitas",
    # Accented and special-character names
    "O'Brien", "O'Connor", "O'Neill", "McDonald", "McKenzie",
    "Gonzalez-Reyes", "Fernandez-Lopez", "Castillo-Moreno",
    "van der Berg", "van Dijk", "de Vries", "von Braun",
    "Al-Hassan", "El-Sayed", "Abu-Bakr", "Ibn-Khaldun",
    "Johansson", "Eriksson", "Lindqvist", "Svensson", "Bergstrom",
    "Kowalski", "Wisniewski", "Kaminski", "Lewandowski", "Zielinski",
    "Novak", "Dvorak", "Horak", "Nemec", "Kral",
    "Popov", "Ivanov", "Smirnov", "Kuznetsov", "Petrov",
    "Sokolov", "Lebedev", "Kozlov", "Novikov", "Morozov",
    "Volkov", "Alekseev", "Fedorov", "Makarov", "Kovalev",
    "Singh", "Kumar", "Sharma", "Gupta", "Verma",
    "Joshi", "Yadav", "Mishra", "Pandey", "Agarwal",
    "Mehta", "Shah", "Desai", "Deshpande", "Kulkarni",
    "Pham", "Tran", "Le", "Do", "Dang",
    "Bui", "Hoang", "Vuong", "Ngo", "Duong",
    # Extend to 1,000 with numbered synthetic names
    *(f"testname{i:04d}" for i in range(1, 700)),
]))

# Known non-members for golden-file negative testing
GOLDEN_NONMEMBERS = [
    "docket", "invoice", "plaintiff", "mortgage", "defendant",
    "subpoena", "deposition", "arbitration", "collateral", "amortization",
    "jurisdiction", "adjudication", "indemnification", "disbursement",
    "encumbrance", "fiduciary", "garnishment", "hypothecation",
    "injunction", "jurisprudence", "liquidation", "malfeasance",
    "negligence", "ordinance", "promissory", "quitclaim",
    "receivership", "surety", "tortfeasor", "usufruct",
    "123456789", "000-00-0000", "9999999999",
    "the", "and", "for", "with", "from", "that", "this", "have",
    "will", "been", "each", "make", "like", "just", "over", "such",
    "take", "year", "them", "some", "time", "very", "when", "come",
    "could", "now", "than", "first", "been", "call", "who",
    "its", "find", "long", "down", "day", "did", "get", "has",
    "him", "his", "how", "may", "new", "old", "see", "way",
    "boy", "did", "let", "put", "say", "she", "too", "use",
    "patient", "diagnosis", "prescription", "pharmaceutical",
    "radiology", "anesthesia", "oncology", "pathology",
    "cardiology", "neurology", "orthopedics", "dermatology",
    "pediatrics", "psychiatry", "urology", "ophthalmology",
    "tracking", "reference", "confirmation", "receipt",
]


def generate_golden(output_dir: Path):
    """Generate golden test files: .bloom + members.txt + nonmembers.txt."""
    output_dir.mkdir(parents=True, exist_ok=True)

    names = GOLDEN_NAMES[:1000]  # Exactly 1,000
    assert len(names) == 1000, f"Expected 1000 golden names, got {len(names)}"

    bloom_path = output_dir / "golden-1000.bloom"
    meta = write_bloom(bloom_path, names, seed=SEED, k=K, fpr=TARGET_FPR)
    print(f"Golden bloom: {bloom_path} ({meta['size_bytes']} bytes, "
          f"n={meta['n']}, m={meta['m']})")

    members_path = output_dir / "golden-1000-members.txt"
    with open(members_path, "w") as f:
        for name in sorted(names):
            f.write(name + "\n")

    nonmembers_path = output_dir / "golden-1000-nonmembers.txt"
    nonmembers = [normalize_key(w) for w in GOLDEN_NONMEMBERS[:100]]
    # Ensure no overlap with members
    nonmembers = [w for w in nonmembers if w not in set(names)][:100]
    with open(nonmembers_path, "w") as f:
        for word in nonmembers:
            f.write(word + "\n")

    print(f"Members: {members_path} ({len(names)} entries)")
    print(f"Non-members: {nonmembers_path} ({len(nonmembers)} entries)")

    # Verify round-trip
    with open(bloom_path, "rb") as f:
        data = f.read()
    verify_bloom(data, names, nonmembers)


def verify_bloom(data: bytes, members: list[str], nonmembers: list[str]):
    """Verify a bloom filter's membership queries."""
    # Parse header
    assert data[:4] == MAGIC, "Bad magic"
    version = struct.unpack_from("<H", data, 4)[0]
    assert version == VERSION, f"Bad version: {version}"
    k = data[6]
    m = struct.unpack_from("<Q", data, 7)[0]
    seed = struct.unpack_from("<Q", data, 15)[0]

    bits = data[63:]

    hits = 0
    for name in members:
        h1, h2 = hash_key(name, seed)
        found = True
        for i in range(k):
            pos = ((h1 + i * h2) & MASK64) % m
            if not (bits[pos // 8] & (1 << (pos % 8))):
                found = False
                break
        if found:
            hits += 1
        else:
            print(f"  FALSE NEGATIVE: '{name}' not found!", file=sys.stderr)

    print(f"Verification: {hits}/{len(members)} members found")
    assert hits == len(members), "False negatives detected!"

    fp = 0
    for word in nonmembers:
        h1, h2 = hash_key(word, seed)
        found = True
        for i in range(k):
            pos = ((h1 + i * h2) & MASK64) % m
            if not (bits[pos // 8] & (1 << (pos % 8))):
                found = False
                break
        if found:
            fp += 1
    fpr = fp / len(nonmembers) if nonmembers else 0
    print(f"Verification: {fp}/{len(nonmembers)} false positives "
          f"(FPR={fpr:.4f})")


# --- Source file reading ---

def read_names_from_csv(path: Path, name_column: int = 0,
                        skip_header: bool = True) -> list[str]:
    """Read names from a CSV file, normalize, and deduplicate."""
    names = set()
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        if skip_header:
            next(reader, None)
        for row in reader:
            if row and len(row) > name_column:
                raw = row[name_column].strip()
                if raw:
                    names.add(normalize_key(raw))
    return sorted(names)


def read_names_from_tsv(path: Path, name_column: int = 0,
                        skip_header: bool = True) -> list[str]:
    """Read names from a TSV file."""
    names = set()
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.reader(f, delimiter="\t")
        if skip_header:
            next(reader, None)
        for row in reader:
            if row and len(row) > name_column:
                raw = row[name_column].strip()
                if raw:
                    names.add(normalize_key(raw))
    return sorted(names)


# --- CLI ---

def main():
    parser = argparse.ArgumentParser(
        description="Build Bloom filter .bloom files from name sources.")
    parser.add_argument("--sources-dir", type=Path,
                        help="Directory with source CSV/TSV files")
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="Output directory for .bloom + manifest")
    parser.add_argument("--manifest-version", default="0.1.0",
                        help="Semantic version for the manifest")
    parser.add_argument("--golden", action="store_true",
                        help="Generate golden test file (1,000 names)")
    parser.add_argument("--seed", type=int, default=SEED,
                        help=f"Hash seed (default: {SEED})")
    args = parser.parse_args()

    if args.golden:
        generate_golden(args.output_dir)
        return

    if not args.sources_dir:
        parser.error("--sources-dir required when not using --golden")

    sources_dir = args.sources_dir
    if not sources_dir.is_dir():
        print(f"ERROR: Sources directory not found: {sources_dir}",
              file=sys.stderr)
        sys.exit(1)

    # Read source files (this will be populated after H1 data acquisition)
    surname_sources = []
    given_sources = []

    # Census 2010 surnames
    census_path = sources_dir / "census-2010-surnames.csv"
    if census_path.exists():
        names = read_names_from_csv(census_path, name_column=0)
        surname_sources.append(("census-2010", names))
        print(f"Census 2010: {len(names)} surnames")

    # Census Spanish surnames
    spanish_path = sources_dir / "census-spanish-surnames.csv"
    if spanish_path.exists():
        names = read_names_from_csv(spanish_path, name_column=0)
        surname_sources.append(("census-spanish", names))
        print(f"Census Spanish: {len(names)} surnames")

    # SSA baby names
    ssa_dir = sources_dir / "ssa-baby-names"
    if ssa_dir.is_dir():
        names = set()
        for yob_file in sorted(ssa_dir.glob("yob*.txt")):
            for row in csv.reader(open(yob_file)):
                if row:
                    names.add(normalize_key(row[0]))
        given_sources.append(("ssa-baby-names", sorted(names)))
        print(f"SSA baby names: {len(names)} given names")

    # Popular names by country
    popnames_path = sources_dir / "popular-names-by-country.csv"
    if popnames_path.exists():
        names = read_names_from_csv(popnames_path, name_column=0)
        surname_sources.append(("popular-names-surnames", names))
        given_sources.append(("popular-names-given", names))
        print(f"Popular names: {len(names)} names")

    if not surname_sources and not given_sources:
        print("WARNING: No source files found in", sources_dir,
              file=sys.stderr)
        print("Place raw data files per README.md, then re-run.",
              file=sys.stderr)
        sys.exit(1)

    # Deduplicate and build
    args.output_dir.mkdir(parents=True, exist_ok=True)

    all_surnames = sorted(set(
        n for _, names in surname_sources for n in names))
    all_given = sorted(set(
        n for _, names in given_sources for n in names))

    from datetime import datetime, timezone

    filters = []

    if all_surnames:
        path = args.output_dir / "surnames.bloom"
        meta = write_bloom(path, all_surnames, seed=args.seed, k=K,
                           fpr=TARGET_FPR)
        print(f"Surnames: {path} ({meta['size_bytes']} bytes)")
        filters.append({
            "name": "surnames",
            "type": "surname",
            "n": meta["n"], "m": meta["m"], "k": meta["k"],
            "fprTarget": meta["fpr_target"],
            "sources": [s for s, _ in surname_sources],
            "builtAt": datetime.now(timezone.utc).isoformat(),
        })

    if all_given:
        path = args.output_dir / "given-names.bloom"
        meta = write_bloom(path, all_given, seed=args.seed, k=K,
                           fpr=TARGET_FPR)
        print(f"Given names: {path} ({meta['size_bytes']} bytes)")
        filters.append({
            "name": "given-names",
            "type": "givenName",
            "n": meta["n"], "m": meta["m"], "k": meta["k"],
            "fprTarget": meta["fpr_target"],
            "sources": [s for s, _ in given_sources],
            "builtAt": datetime.now(timezone.utc).isoformat(),
        })

    manifest = {
        "version": args.manifest_version,
        "hashAlgorithm": "MurmurHash3_x64_128",
        "seed": args.seed,
        "filters": filters,
    }
    manifest_path = args.output_dir / "gazetteer-manifest.json"
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"Manifest: {manifest_path}")


if __name__ == "__main__":
    main()
