# Engine tests

The `RedactionEngineTests` target holds the engine package's Swift Testing
suites. The rules below describe where a new test goes, how the runner treats
it, and the shapes it uses.

## Placement

- `SecurityTests/` — a property of the redacted output that an attacker
  would read: text or bytes that must be absent, metadata that must be
  stripped, structure that must not survive.
- `DetectionTests/` — what a detector reports for a given input.
- `VerificationTests/` — one verification layer, or the verification
  schedule as a whole.
- The other directories are named for the subsystem they exercise
  (`SearchTests/`, `SandwichTests/`, `Pipeline/`, `PerformanceTests/`,
  `CorpusTests/`, `FuzzTests/` and so on). Shared builders and helpers live
  in `Fixtures/` and `Support/`.
- The single-file directories and the files at the target root keep their
  place; a new test goes into the directory whose rule above it meets.

## Runner tiers

`Scripts/test-batched.sh <scheme>` builds once and runs the suites in serial
batches on one simulator. It is the runner for local runs and the pre-push
hook, and the hosted `sim-suite` workflow calls it too.

- **Gating batches.** Every suite not named below runs in a batch, and a red
  sets the exit status.
- **Perf-alone** (`PERF_ALONE_RedactionEngine`). Suites that assert
  wall-clock, ratio or percentile budgets run one at a time after the
  batches, report-only: their reds are read by hand and never gate.
- **Non-gating** (`NON_GATING`). Suites whose wall-clock bounds move with
  other work on the same machine run inside the batches, report-only.
- **Hosted exclusions** (`TEST_BATCHED_EXCLUDE` in
  `.github/workflows/sim-suite.yml`). Suites whose full verification or OCR
  pass never returns on the hosted virtual machine, and timing pins whose
  limits that machine cannot meet, are left out there and named in its
  verdict; local runs and the pre-push hook run them.
- **Disabled.** A test carrying `.disabled("…")` does not run anywhere. A
  new one says in its reason string why, and what would bring it back.

A new correctness assertion goes into a gating suite, not into a suite on the
perf-alone or non-gating list.

## Resources and environmental gates

- A resource the repository tracks (a fixture file, a bundled gazetteer, a
  value the test computes itself) is unwrapped with `try #require`. Its
  absence fails the test. A new test does not use `try!`: a trap ends the
  whole test process instead of failing one test.
- A test that cannot run in this environment (a runtime asset that is not
  provisioned, an output path that was not requested) calls
  `TestGate.skip("…")` and then `return`s. The gate records a warning in the
  result bundle, so a run that skipped a body reads differently from a run
  that proved something.
- In a new test, a loop never holds the only assertion behind a
  `continue`, and an assertion never sits below an early `return` that
  skips it silently.

## Emitters

Some suites write measurements to a directory instead of asserting. They run
only when their environment variables are set (`RESECTA_*`; through
`xcodebuild` the same names carry the `TEST_RUNNER_` prefix), in an isolated
run of that one suite, and they are report-only. A new emitter skips through
`TestGate` when its variables are unset.

## Production paths and controls

- A new `.critical` tag goes only on a test of production code that runs
  in a gating tier.
- A new test of an engine path calls the engine type that the product
  calls. It does not reimplement an engine or app path inside the test
  target (a stand-in or a mirror); a path that has no engine entry is tested
  where it lives.
- A new leak assertion (text or bytes absent from an output) comes with a
  negative control: the same input without the redaction, asserting the
  text or bytes are present, which shows the assertion can fail.

## Growing a large suite

A suite type that grows past a comfortable file size gains files that each
hold one `extension <Suite> { … }` along a real seam (a layer, a subsystem),
named for that seam. The base type keeps at least one `@Test` in its own
body. The runner enumerates suites from the column-0 type declarations and
their extensions, so the extension files run with the base type under the
same suite name.
