# Threat model

This document states what Resecta is built to protect, whom it is built to protect it from, where its trust boundaries lie, and what it does not claim to handle. It is the model the project's own security work is measured against, and it is published so that anyone can hold the code to it. It describes design intent and mechanisms. It is not a promise of any outcome: no tool can confirm that a redaction is complete, and the verification pass is a check, not a substitute for your own review.

The companion documents: [`SECURITY.md`](./SECURITY.md) (how to report a vulnerability, scope, safe harbor), [`PRIVACY.md`](./PRIVACY.md) (what the app stores and what it does not), [`ENGINEERING.md`](./ENGINEERING.md) (how each load-bearing claim is checked in this repository).

## 1. The promise, and why the promise is the threat

Resecta is a free, offline, open-source iPhone app that redacts PDFs. A redaction that a person trusts but that only appears to redact is worse than no redaction: it turns caution into false safety, and the document is shared anyway. So the properties that carry the most weight here are not confidentiality in transit or account security. They are the irreversibility of the file the app produces, and the honesty of what the app tells you about that file.

The security policy scopes four properties the app is designed to provide: redaction integrity, verification integrity, metadata handling, and on-device-only operation. Hostile input is a declared non-goal in the narrow sense that the app does not sandbox Apple's PDF and image frameworks. It is still reviewed, because a crafted document that produced a silently under-redacted export would breach the core promise through a side door.

## 2. Assets — what must not leak

- **A1 — Redacted content in the exported file.** The text or image regions you marked for removal, in the redacted PDF the app hands to the share sheet. A leak here is the whole point failing.
- **A2 — Original document content on the device.** The imported source and anything derived from it, after you believe the session is over or the document is gone.
- **A3 — Sensitive literals you typed.** Custom Terms, saved searches and saved patterns, which may themselves be your own identifiers.
- **A4 — The truth of the app's public claims.** A statement about the app that turns out to be false is itself a harm to the person who relied on it.

## 3. Adversaries — who gets what, and when

Resecta is offline and single-user, so the classic remote attacker is mostly beside the point. The adversaries the design is measured against:

- **The recipient of the shared document.** Receives exactly the exported file (A1), has unlimited time offline and every PDF and forensics tool. This is the primary adversary. Content this recipient can recover from a file the app presented as redacted is the most serious failure the project recognizes.
- **Anyone with the locked device, its backup, or what it left behind.** A lost, stolen or serviced phone while locked, a device backup, a forensic extraction, or another app reading a shared location. Gets whatever residue exists (A2, A3). Access to an unlocked device is out of scope, as the security policy states: at that point the attacker already has whatever you were redacting.
- **A malicious document author.** Crafts the PDF you import. The aims, in rising order of seriousness: crash the app, exhaust it, or cause it to export something under-redacted while you believe it redacted.
- **The reader who trusts the claims.** Not an attacker: a person who relied on a public claim (A4) that was false. This is why claim accuracy is treated as a security property and linted like one.

## 4. Trust boundaries

- **Import.** Untrusted bytes arrive as a PDF from Files or by drag and drop and are parsed by Apple's PDFKit and Core Graphics; text recognition runs through Apple's Vision framework. At the boundary: a file-size cap; password-protected PDFs are refused; a PDF that carries JavaScript or a launch action at the top of its catalog, in the catalog's name tree, in the open action, in a page's additional actions, or in an annotation's action is refused; page-count and page-dimension limits apply; a page whose rotation is not a right angle is refused before rendering; hidden layers force image-only handling; a dropped payload that is not a PDF is declined, and a file chosen from Files is routed by its type and then validated by parsing its content. Images inside a PDF reach the exported file only as redrawn page pixels. The parsers themselves are Apple's, run inside the app's process, and are not sandboxed by the app.
- **Export.** The redacted output goes to the system share sheet. Once handed off, iOS may copy it into another app's or extension's container outside Resecta's control. The app's duty ends at producing a clean file and reporting honestly on it. Verification is advisory: a reported issue routes sharing through an explicit confirmation that lists what was reported; it does not silently block, and it does not silently pass. The pass ends with a re-run of each search you applied on the output and a sweep of the app's detectors over it; the sweep reads the structured categories, and names and addresses are not swept.
- **Detection data.** The gazetteers, pattern tables and classifier weights the detector uses are built in a separate open-source pipeline and shipped inside the app as bundled assets. At first detector initialization the app verifies an Ed25519 signature over the asset manifest, then checks each listed file's size and SHA-256 digest against its manifest entry. The public key ships inside the app bundle, and a test pins its fingerprint. Stated plainly: this proves provenance, that the bytes the detector reads are the bytes the pipeline signed, and not runtime tamper-resistance. Tamper detection of the installed app is the app-bundle code signature, which seals these same files and the public key with them. On a failed signature, or a digest failure on any file the signature-gated loaders read, five data loaders are withheld and a visible banner says detection is degraded; the pattern detectors keep running and manual redaction stays available. Three reference tables and the classifier assets load outside that verdict by design; a digest failure on one of them is recorded in the load diagnostics and raises the same banner while the asset's fallback stands. How the signing key is held, backed up and rotated is described in the data pipeline's `KEY-MANAGEMENT.md`.
- **Persistence.** Custom Terms and the saved-search and saved-pattern libraries are kept in the app's own files on the device, under the complete file-protection class, and are excluded from device backups. Your remaining preferences (your settings, the per-category detection priors the app maintains, an export counter, the last search filter you used, and your acceptance of the in-app agreement) live in the system preference store, which participates in device backups; none of them holds document content or text you typed. The imported document is held in memory; transient export artifacts live in a hardened per-session workspace that is removed when the session closes, with a sweep at launch and on each return to the foreground for anything an interrupted session left behind.
- **Build and distribution.** The App Store binary is built and signed through Apple's toolchain, and no reproducible-build story exists for it. What you can verify is the source, the tests, and a build you make from that source yourself.

## 5. Out of scope

These are accepted platform realities, recorded so that no one mistakes a mitigation for a promise:

- **A compromised or jailbroken device.** If the device is compromised, the attacker already has whatever you are redacting.
- **Operating-system memory handling.** Paging or swapping of process memory is the OS's business; bitmap buffers are zeroed after use as a best-effort measure, not a promise.
- **The App Switcher snapshot store.** The capture shield reduces what those snapshots can contain and is a mitigation, not a promise.
- **A one-shot screenshot** taken with the side button while the document is on screen.
- **Network adversaries.** The app contains no network client code and makes no network requests of its own; the check takes about a minute and is described in `ENGINEERING.md`.
- **Human review of the output.** You are responsible for looking at the redacted document before sharing it.
- **Third-party services and dependencies** outside this repository; the app has no third-party dependencies (its only package is its own engine, and a contribution rule holds it there).

## 6. Accepted risks

Each of the following is true of the current design and is accepted rather than fixed:

1. Apple's PDF, image and text-recognition frameworks parse untrusted input inside the app's process; a flaw in them is outside what this app can fix.
2. The bundled public key proves where the detection data came from, not that the installed app is untouched; that rests on the app-bundle code signature.
3. Once a file is handed to the share sheet, copies can exist outside the app's control.
4. Verification helps you check redaction completeness; it can report an issue and ask for confirmation, but it cannot prove the absence of a leak, and a reported issue does not block sharing.
5. Three reference tables and the classifier assets load outside the signed verdict by design; a digest failure on them degrades detection with a banner rather than withholding it.
6. Preferences other than Custom Terms and the saved libraries live in the system preference store and are included in device backups.
7. Memory zeroing and the capture shield are best-effort mitigations against exposure the operating system controls.
8. No reproducible build of the App Store binary exists; what can be verified is the source and a build you make from it.
9. In Searchable Redaction, text you did not redact is preserved in the rebuilt layer. A page whose unmarked text shows no ink on the rendered page (white on white, invisible, or beneath a box drawn into the page) is exported as an image only, and the results screen names the reason; the ink test reads rendered pixels against a threshold, so it is a measurement, not a proof.
10. The detection sweep at the end of verification reads the structured categories; names and addresses are not swept, so a name or address you did not mark is not something the sweep reports.
11. The checks read the text the app can read: the rebuilt text layer where one exists, and OCR of the rendered pages otherwise. A page OCR could not read is listed as not checked rather than counted as clear; text OCR misreads is text the checks did not see.

## 7. Security posture as of 2026-09-28 (commit f3a76aaf)

Each line names how a reader can check the state without trusting this document. States are what was true on the date above; the repository's settings pages and the files named are the source of truth after that. The state is recorded for the three public repositories (the app, the data pipeline and the sample-document generator) unless a line says otherwise.

| Control | State | How to check |
|---|---|---|
| Secret scanning | On | Each repository's Settings → Code security; or the GitHub API `security_and_analysis` field |
| Push protection | On | The same page |
| Dependabot alerts and security updates | On | The same page; `.github/dependabot.yml` lists the ecosystems that receive version updates |
| Private vulnerability reporting | On | Each repository's Security tab shows "Report a vulnerability" |
| CodeQL code scanning | On | Each repository's Security tab → Code scanning |
| GitHub Actions restricted to an allow-list and required to be pinned to full commit SHAs | On | Each repository's Settings → Actions → General; read any workflow file under `.github/workflows` |
| Branch rules on `main`: changes land through pull requests, and each repository's CI check must pass before merge | On | Each repository's Settings → Rules |
| The app's pull-request gate builds the app and runs the documented lints from the base branch | On | The job list in `.github/workflows/ci.yml` |
| The app's test suite runs on every pull request | Runs, not yet required | `.github/workflows/sim-suite.yml`; the rule set on `main` lists the required checks |
| The regular-expression safety gate's accept/reject checks run in the gating test suite | On | `RegexGateFunctionalTests` in the engine package |
| Signed detection-data manifest with per-asset digests, and a pinned public-key fingerprint | On | `Detection/GazetteerLoader.swift`, `Detection/Gazetteer/AssetIntegrity.swift`; the `SignedManifestTests`, `AssetTamperMatrixTests` and `ManifestPublicKeyPinTests` suites |
| Signing-key custody documented (location, backup, rotation, compromise procedure) | On | `KEY-MANAGEMENT.md` in the data pipeline repository |
| Release build checked for debug-only launch arguments and bundled test fixtures before submission | On (a recorded release step) | `Scripts/release-flag-check.sh --archive` |
| Signed release tag | Not yet: `v1.1.0` is an unsigned tag; the signing key is registered and the next release tag is to be signed | `git tag -v <tag>`; the tag's Verified badge on GitHub |
| Public threat model | On (this document) | This file |
| `security.txt` and a published disclosure policy | On | `https://resecta.app/.well-known/security.txt` (expires 2027-04-19) |
| Mail authentication on the reporting domain (DMARC) | On | `dig +short TXT _dmarc.resecta.app` |
| Secrets and access on the public repositories | No Actions secrets; one collaborator; no deploy keys or webhooks | The GitHub API `actions/secrets`, `collaborators`, `keys`, `hooks` endpoints |

## 8. How to report

Suspected vulnerabilities go through the channels in [`SECURITY.md`](./SECURITY.md): email `security@resecta.app`, or a private security advisory on this repository's Security tab. Please do not file public issues for security matters until disclosure has been coordinated, and please reproduce with the synthetic test corpus rather than real documents.

## About this document

The project keeps an internal review record (issues and evidence) that is not published. What is published is this model, the code, the tests named here, and the changelog's security entries. This document changes when the model changes, and the posture section is re-dated whenever it is re-checked.
