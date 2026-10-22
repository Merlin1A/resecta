# Changelog

All notable changes to Resecta are recorded in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). Subsection ordering within a release: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`, then a project-specific `Internal`.

## [Unreleased]

### Added

- Double-tap the page to return to the fit zoom.
- Page bar: a Mark Whole Page control beside the page chevrons adds one redaction region covering the page on screen, through the same path a drawn region takes — the counter reads "1 region", Undo removes it in one step, and no search term is captured from it.
- Import: a password-protected PDF can be opened by entering its password; the import checks run on the unlocked document, and the redacted copy is not password-protected. The password is held in memory while the document is open and released when the session closes; the failed-state card beneath the password sheet reads as locked rather than damaged. A document that was encrypted — one opened with a password, or one carrying only an owner password — shows a notice at import and a caption on the Share card saying the redacted copy carries neither the password nor the original's usage restrictions.

### Changed

- Search sheet: the recent-search recall chips, the per-term section headers of the results list and the saved-search names are marked privacy-sensitive, matching the result rows and the saved-query previews.
- Import: a file over the 50 MB cap is refused by its size on disk before any byte is read, from the Files picker and from a drop alike; a dropped file arrives as a file and is read inside its transfer rather than as 50 MB of memory.
- Verification results: the Verification Details list groups each check by its outcome — findings first, then checks that could not verify part of the output or were skipped (Share asks you to confirm before sending), then notes and checks that had nothing to check, then one line for the checks that passed, which opens to the individual rows. Every row shows the check's glyph, one status mark and one status word; the header counts only passing checks as passed and names failed checks, checks that need review, checks that could not verify, warnings, notes and checks with nothing to check separately. The ten core checks carry plain-language titles, a passing check's row says in one line what the check reads, and the results headline names warnings and checks that could not verify in the list's words.
- Documentation: the privacy policy describes the detection the app performs (the seventeen text categories a scan reads from the page text layer or from recognized text, with the bundled gazetteers, Bloom filters and context scorer; no face or barcode sentence), says the app makes no network requests of its own and names the two system services that do, drops the detection-priors clause no shipped path stores or reads, and states the failed-state screen, the delete-all controls, the per-session workspace and its sweep, and the in-place metadata patches as they work; the EULA's Searchable Redaction fallback names hidden text. Both effective dates move to 2026-10-15.
- Documentation: the threat model says the share confirmation lists a line for each check that reported or could not verify, and no longer describes OCR word hints the shipped flow never builds.
- Documentation: the security policy gains a recipe for verifying a signed release tag: `.github/allowed_signers` lists the release-tag signing key under `security@resecta.app`, and `git tag -v` checks a tag against it once `gpg.ssh.allowedSignersFile` points at the file; the threat model's signed-tag row points at the recipe.
- Import: a page the app could not render — a side under 10 points, a page-scale entry (`/UserUnit`) other than the default, or a rotation PDFKit and Core Graphics read apart — is refused at import with the error the render would raise, instead of opening and failing at Redact.
- Verification: a hand-drawn region captures the words the Searchable filter would touch, line by line, and checks each line as the page text reads it ("123-45-6789", "j.doe@example.com", "Account Number 1234" whole); a region over one word keeps that word; a single word of a longer run is checked on its own only when it carries a digit, or has four characters or more and is not one of about 150 common English words (articles, prepositions, pronouns, auxiliaries, the nouns of forms and statements).
- Search sheet: the undo action for an applied search reads "Mark N Instances", the verb the toast uses, with no document text.
- Import: a document whose structure the app cannot read in full is refused rather than opened unscanned. The reader the active-content and hidden-layer walks inspect must open, be unlocked, read a catalog and agree with PDFKit on the page count; a walk that cannot read a page or follow an action chain to its bound refuses instead of answering clean; an `/OCProperties` entry without its default configuration reads as a hidden layer. An owner-password-only document still opens.
- Documentation: the licence notices name ParaNames' data licence (CC BY 4.0) with its attribution and the changes made, state the OpenStreetMap and OpenAddresses rows as provenance acknowledgements for inputs no build reads, and attribute the Inter typeface embedded in the bundled sample document.
- The Search sheet's OCR source row appears only when a page reads via OCR or an OCR filter is set.
- The Custom Terms screen states that a literal always-flag term matches inside words and in any case.
- The "Marked N" notice is shorter so its "Not redacted until you tap Redact" clause fits at the default text size.
- A saved search's suggested name no longer carries the query text.
- The page bar stays while a match walk is parked.
- Moving to another page clears the region selection.

### Removed

- The search sheet's disabled audit-export, scan-coverage, doctype-diagnostic and category-strip surfaces, the navigation-scope controls, the custom-terms template picker and the two debug launch arguments that revealed them: each sat behind a flag that was false in every shipped build, so no shipped screen changes. The match rationale's classifier explanation and the coverage counts the verification screen reads stay.
- The workspace's in-editor file importer and its "Replace the open document?" dialog, which nothing could present (the drop target stays), and the second sample packet bundled with no screen that opened it.
- The paused-detection resume path.
- The unreachable face, barcode and signature detection code.

### Security

- The app opts into Apple's hardened-process protections in their reporting mode.
- The pre-commit hook and the pull-request gate scan the whole shipping source, on every run, for the call-shaped networking and hand-off symbols (a bare `Link(`, the Network framework's listener and browser, the socket and stream constructors, `openURL`, `UIApplication.shared.open(`, an `import Network` line) against the sites pinned in `Scripts/audit-lint.sh` with their reasons; one site is pinned, the Settings view's `mailto:` feedback link.
- The shipped-asset fence (`Scripts/verify-shipped-asset-hashes.sh`) verifies the gazetteer manifest's Ed25519 signature with a verifier outside the engine (OpenSSL 3, else CryptoKit through `swift`; no verifier fails the fence), beside the blob and digest pins it already held.
- `SECURITY.md` says how a security fix is announced: the changelog's `Security` heading of the release that carries it, the App Store availability date, a GitHub security advisory with a CVE through GitHub's CNA where a report warrants one, and that a fix reaches users only as an update. `THREAT-MODEL.md`'s build-and-distribution boundary says that the app repository holds no Actions secret, so no workflow can sign or upload a build, and that the detection-data signing key never enters a repository.
- `THREAT-MODEL.md` §7 re-dated at `28b9a777` (2026-10-20), with rows for the release-tag ruleset (`v*` tags cannot be updated, deleted or force-pushed once pushed), immutable releases in the app repository, and the mail policy on the reporting domain (DMARC `p=reject`, SPF `-all`); the branch-rules row states that the admin role may bypass the required check on a pull request, and names the rulesets API as the check a reader can run without a login.
- Searchable redaction treats optional content as hidden when the default configuration turns layers off through its base state, when a page inherits the resources that name it, or when a form object carries it; a glyph outside the visible page counts as showing no ink.
- The Searchable-mode ink test treats a glyph box whose pixels all lie within a fixed tolerance of one color as showing no ink, so near-white, nearly transparent and nearly covered text exports as an image only.
- Document canvas: with a hardware keyboard, Select All then Copy (⌘A, ⌘C) no longer places the document's text on the system pasteboard. The canvas view refuses the copy, cut, paste, select and select-all actions and builds its menu without the edit, look-up, learn and share groups; in 1.2.0 that keyboard path copied the whole document's text with no selection shown.
### Fixed

- Search: a phrase whose words are separated by more than one space, a tab, a line break or an invisible character is now found, and a match that wraps onto a second line gets a box on each line, counted once per line. Before, such a phrase was not found at all.
- Search: in Regex mode, the start and end anchors (`^` and `$`) match at each line of the page. Before, they matched only the start and the end of the whole page.
- Search: with every term required, the result cap counts the matches that pass the every-term test. Before, a page dense in one term alone could fill the cap and leave later pages unread.
- Search: in Regex mode on a scanned page, a match that runs across two recognised lines is boxed on every line it touches. Before, the box covered only the line where the match began.
- Scan: a name read after a role word or honorific ("Mr.", "Patient:", "Plaintiff") is boxed to its full width when the page text carries more than one space between the name's words. Before, the box was one character short per extra space, the name's last character stayed visible, and the coverage check, which re-runs the same reading, did not report the gap.
- Scan of a scanned or sparse page: a value on a line below an emoji or another character wider than one UTF-16 unit is boxed on its own line. Before, each such character ahead of the match moved its line lookup one unit later, which usually widened the box to the next line and, for a value at the end of a line below enough of them, placed the box on the next line alone.
- Verification: on a password-protected document with 128-bit encryption, the Search Re-check's coverage check now reads the original pages unlocked with the session's password. Before, it read a copy that stayed locked, found no matches and passed. When the original pages cannot be read, the check now reports "could not verify" instead of passing; and the OCR Check reports the start or the end of a redacted term read beside a box on a page that also carries a fill artifact, with the results row naming the term and the box as the remedy.
- Verification: the Search Re-check also re-runs each applied search and scan on the original page and fails when a redaction box leaves part of a match uncovered, and the OCR Check reports the start or the end of a redacted term read beside a box. Before, a box placed off its text by one or more characters passed every check while the uncovered characters stayed printed on the page: the rebuilt text layer dropped them, the text-reading checks read that layer, and the OCR Check read only the box.
- Search: a match's rect now covers the matched glyphs on every page, in Text mode and in Regex mode. Before, on a page whose text layer carries a ligature or another character that normalization expands, the rect sat as many characters to the right as the expansions before the match had added (and Regex mode still placed it there); and on a page with an emoji, a letter written with a separate accent mark or another character wider than one text unit before the match, the rect sat to the left of the match and short by those units.
- In Regex mode the Case-sensitive option now governs the pattern; with it off, "smith" matches "Smith".
- Redact: a page that finishes after Stop no longer brings the progress card back for a frame — Stop invalidates the run, and the run's later reports are dropped.
- Redact: the per-page retry's memory check estimates the 150-DPI render it performs, instead of a 96-DPI render the rasterizer never makes.
- Done and Home reset the session through the one Start Over path, so a re-imported document no longer shows the previous document's form-field notice.
- Home at the compact width: Cancel on the close dialog brings a presented search session back whole — its results and selections — instead of dropping it.
- Redact and ⇧⌘R are unavailable while the search sheet holds selected matches that are not applied, with the hint "Apply or clear the selected matches first", instead of tearing the session down and dropping them.
- Redact clears the undo history at the Apply seam, as the results card says; an Undo after Keep Editing no longer unlinks the built output.
- Search sheet: the "unapplied matches cleared" toasts no longer count matches a region already covers.
- Search sheet: the custom-term time-limit toast names neither the term nor the page, and is shown once for a scan instead of once per page.
- Accessibility: the search sheet's header stacks Dismiss, the title and Apply on lines of their own at accessibility text sizes, so no button hyphenates and the title keeps its words.
- Accessibility: a toast's icon scales with its message and sits beside the first character instead of on it at accessibility text sizes.
- Accessibility: a search result row speaks its category (an address, a Social Security number), its page, its confidence and whether it is applied — never the matched text; the row's default action toggles its selection instead of parking the sheet.
- Accessibility: a staged search term's remove control is named "Remove" with the term and meets the 46-point target; the Custom Terms add row's Regex toggle and add button meet it too.
- Accessibility: the parked strip's Apply capsule is named "Applied" once the match is marked, with the match's position as its value, and every element of the strip offers a "Show full sheet" action.
- Accessibility: the page bar's counter is one spoken element, "Page k of N, n regions"; filter chips report when they are selected.
- Custom terms and saved patterns: a regular expression holding a character whose uppercase form is two letters (such as ß or the ﬁ ligature) no longer stops the app when the pattern is validated.
- Verification: the search re-check and the detection sweep list a page as not checked when a custom regular-expression term ran out of time on it, instead of counting the page as read.
- Verification: the detection sweep reports a custom term added after a scan was applied as a possible item instead of discarding it as the scan's.
- Verification: the sweep's count of items you left unredacted pairs each one with what it reads on the output by its text first and its position second, so scanned output no longer misattributes them.
- Verification: a typed pattern that ran out of time marks only its own search as not checked on that page; the detection sweep's row no longer carries another search's timeout.
- Verification: two applied scans that share a category count an item they both read once.
- Verification: the string-search check's note on manual regions names the mechanism — pages with no text layer to capture terms from — instead of calling the pages image-only.
- Custom terms: a literal term typed with a ligature or a compatibility character matches its plain spelling on pages whose text is plain ASCII.
- Verification: the Character Count and Font Verification checks report the per-page warnings their checks raise — a count excess as a note, a page whose fonts could not be inspected as not verified — where before the check passed.
- Searchable Redaction: a page whose text layout does not settle within the re-flow limit is written without a text layer instead of with a character placed inside a redacted area.
- Verification results: the Verification Details summary no longer counts notes or checks with nothing to check as passed, and no longer reports a check that could not verify part of the output as completed.
- Share: a report with a skipped check asks for confirmation before sharing even when another check reported a routine warning.
- Verification results: a search line starting 'Scan (' keeps its term formatting.
- The Source filter can be changed back from OCR on a document whose pages read as text, Reset to Defaults clears it, and the empty results state offers Show All.
- An always-flag or never-flag term of one character is refused with the reason.
- A query of spaces no longer runs via Search Anyway.
- Save current search is disabled while the session has no query or terms.
- The footer says how many selected matches a filter hides.
- The Scan category chips wrap instead of clipping at the right edge.
- Tapping an already-selected region without moving it no longer records a Move or Resize step, re-arms Redo or clears the sheet's applied markers.
- With Add to Selection on, a marquee adds to the selection and an empty marquee leaves it unchanged.
- VoiceOver announces region resizes.

### Internal

- The app's unit tests build their settings on a scratch defaults suite: the shared coordinator helpers take a fresh suite by default, and the source check that lists tests reading the shared defaults domain now fails on any such site.
- The engine package's test copy of the app's per-page mode choice is removed; the app's tests check the production choice through the coordinator, on a right-to-left page and on every page of the bundled sample.
- App tests: the six trapping requires in the mode-switch toast tests are throwing requires, and the hosting and transition smoke tests assert what they name; the two review-dismiss UI tests call their survival check from the test body.
- Context-scored pattern matches build their explanation through one factory; the signal order is unchanged.
- Decoded fields nothing reads are dropped: the per-filter manifest entries and the unapplied document-type temperature; the temperature file is read only for the startup diagnostics.
- Detection loaders: the context keyword sets switch over the typed scored families; the context keyword loader and the driver's-licence and passport pattern tables share one version check and one loading path; the state-code pattern is compiled once.
- The output re-check's page extraction runs off the main actor (`@concurrent`), one reader on the output document at a time; the rasterizer's test seam keeps a page failing for a given number of attempts, so the per-page retry's second-failure branch is driven through the production wrapper.
- The engine's password message names the missing password rather than unsupported encryption; the import checks read one parser's view of the document (the walks inspect the parsed document's own reader, unlocked with the same password, instead of a second parse of the bytes). The robustness mirror and the verification corpus runner take the same password; the runner gains two plain seed documents and three locked twins whose outputs must match their seeds byte for byte.

- `Scripts/release-flag-check.sh` censuses the remaining debug-only launch argument, the saved-searches sim-drive hook, as its positive control.
- The search sheet's row display contracts, copy catalogs, banners and Scan options sit in their own files (`SearchResultRow+Contracts.swift`, `SearchResultsCopy.swift`, `SearchResultsBanners.swift`, `SearchToolbarSection+Scan.swift`), the copy catalogs under names that say what they hold; one detection-kind label table serves the canvas badge and the review surfaces; the two search-preparation guards share one failure path.
- The pull-request gate counts the engine package's `public` and `open` declaration lines and fails a change whose count exceeds the cap the script carries, printing the count, the headroom under the cap and the release line caps on the largest source files (`Scripts/engine-public-surface-check.sh`); a change that adds to the count names the declarations in its description.
- The growth ratchet tracks the two test trees as well as the source trees: a test file over 800 lines at the base of a change may not grow.
- The audit lint's shorthand check reads five more shapes on added Swift and string-catalog lines: a section sign with no standard or repository document named beside it, a Markdown file name the repository does not track, and, in comments, planning-process words, step tokens and the maintainer's first name.
- A report-only test lists every app test that builds its settings on the shared defaults domain instead of a scratch suite; with `RESECTA_PIN_SCRATCH_DEFAULTS=1` it fails on them.
- `CHANGELOG.md` merges with git's union driver (`.gitattributes`), so two pull requests that each add lines under `[Unreleased]` no longer conflict on them.
- `pr-closed.yml` leaves a merged pull request's runs to finish; only a pull request closed without a merge has its `ci` and `sim-suite` runs cancelled, so the hosted simulator suite of a merged change reaches a verdict.
- The batched runner (`Scripts/test-batched.sh`) reads its stall allowance and its recovery shape from the environment: the hosted simulator suite widens the no-output watchdog to 900 seconds, and a recovery after a wedge shuts the simulator down and boots it again, waiting for it, instead of erasing it (the erase stays opt-in). Its suite enumerator reads `@Test` functions inside extensions of a suite type. A runtime exclusion list (`TEST_BATCHED_EXCLUDE`) names suites not run on a given runtime, lists them in the summary and counts them in the verdict; the hosted suite names the five suites whose verification pass, OCR sweep or OCR re-check hangs on the virtual machine, and the pre-push hook still runs every suite.
- `sim-suite.yml` names the account's five-macOS-job cap in its header, runs the editor's link-policy UI tests on the weekly and tag runs, and reports a failed weekly or tag run through an error annotation, a step summary and, when the repository variable `NTFY_TOPIC` is set, a post to that ntfy topic.
- The asset-tamper matrix measures the bundled assets with the name-model probe forced present, so a simulator without the OS name model measures every cell instead of raising the banner on each.
- Removed: the golden Bloom builder under `Scripts/gazetteer/` (its fixture is committed; the shipped filters come from the data pipeline), `engine-suite.yml` (the on-demand host run of the engine package, which never reached a verdict; the simulator suite's engine job is the hosted run) and five permanently disabled wall-clock tests.
- `Scripts/doc-metrics.sh` counts the log interpolations marked `privacy: .public` and the `print`, `NSLog` and `debugPrint` calls in the shipping source and holds `ENGINEERING.md` to both numbers (61 and none); its `--self-test` proves the claims move. The pull-request gate's checkout no longer keeps the token, and its toolchain is selected by name (`DEVELOPER_DIR`) with the version printed in the summary. The ignore file refuses an age wrapper, a private key, a PEM file and a derived-data directory, with the one tracked public key named as the exception.
- The audit exporter blanks the exemption, citation and note fields when sensitive content is excluded (the app passes none).
- The engine's unsupported-format message names the formats: PDF files and JPEG, PNG and HEIC images.
- Import lives in `Services/Import/`: a loader protocol with its payload, limits and facts types; a router that reads the leading bytes, never the declared type, and refuses every image signature before any decode; the PDF stages as a pure function of the bytes; and a wrapper that applies the facts to the editor's state in one place and reports whether the import completed. The image decode and image-to-PDF render no door reached, and the Live Photo auxiliary-metadata stripper only they called, are deleted.
- The run's page-data bridge is a pure function of values (`RunInputs.pageData`); the rasterization steps sit in `PipelineCoordinator+Rasterization.swift`; the stores share one lenient row wrapper and one legacy-defaults move; the regex sentinel is entered through one `PatternAdmission` path; the sidebar's thumbnail cache keys on the document as well as the page.
- The pre-push hook refuses a stale generated project, runs only the test schemes the pushed change touches (both for an engine change, none for documentation), and accepts the batched runner's passing verdict for the same tree in place of a re-run.
- The batched runner writes a verdict file beside its logs: the scheme, the counts, the commit and tree it ran on, the simulator and runtime, and the Xcode build.
- Release: `Scripts/release-identity.sh --archive` writes an identity record of the archived release build (the main executable's UUID and SHA-256, its linked libraries, its imported symbols counted against a list of networking interfaces, its entitlements, the security-relevant Info.plist keys, the privacy manifest and the SHA-256 of every other bundled file), and `--check` compares a published record with a fresh derivation from the archive. `RELEASES/1.2.0-identity.md` is the 1.2.0 record, made from the submitted build's archive after submission.
- A page whose hidden-text check cannot run — no bitmap to read, no page dictionary to inspect — takes the secure path and records that the check could not run, instead of reading as clean; the first-render bitmap is wiped when the render releases it, the image handed on being a copy. The robustness runner's import mirror and the verification corpus mirror follow the same reader rules.
- The reconstruction sweep test no longer races its siblings for the shared temporary directory.
- CI: CodeQL runs from a workflow in the repository (`.github/workflows/codeql.yml`) instead of the default setup; the Swift job builds the Xcode project, so the app target and the engine package are both in the Swift database, and the Actions and Python analyses run without a build.
- The engine's verification tests are organised by layer, and the security suites run through the production page pipeline.
- The polygon containment test the text-layer writer uses lives with the other polygon geometry; the writer no longer reaches into the verification code.
- The stale temporary-file sweep lives beside the per-session temporary directory it cleans up after.
- Resolution selection and the pre-render page checks live in one page memory policy file.
- The structural and metadata verification layers, and the dispatch of the text-layer checks, live in their own files.
- The text-layer position check is split into its three techniques over one shared scan state.
- The verification status ranking is an exhaustive switch over every status; the test-only tuning values are bound per task.
- Rendering a page from a PDFKit page and from its Core Graphics page runs one render body.
- The rectangle and polygon character filters share one sort, search and cancellation skeleton.
- Engine: the public surface is reduced to the document-runner API and what the app and its tests name; 103 more declarations become `internal` (access level only).

## [1.2.0] — 2026-09-29

### Added

- Saved searches: a Delete All control in the saved-search list, one per interface, matching the Custom Terms and Saved Regexes controls; the Settings reset dialog names all three stores.
- **Search re-check.** Verification gains a check that re-runs each search you applied — the same text, pattern, or term list with the same options, except that OCR is always on — on the redacted output through the search engine, and reports per search how many matches it found, how many you applied, and how many remain in the text the app can read. In Secure Rasterization the output has no text layer, so the check reads the rendered pages with OCR and says so. Pages the check could not read are listed rather than counted as clear. Both modes end with this re-check and the detection sweep below; Secure Rasterization output now runs a 7-layer check and Searchable Redaction a 12-layer check.
- **Detection sweep.** Verification ends with a check that runs the app's detectors on the redacted output through the search engine — your applied scan's categories and every other category at the current preset, except names and addresses, which are not swept — and reports what remains, minus the items you chose to leave unredacted, with the pages they are on. In Secure Rasterization the check reads the rendered pages with OCR and says so; pages it could not read are listed rather than counted as clear.

### Changed

- Verification results: the two informational notes that every run carried — page content outside the redacted regions, and the writer's fixed metadata fields — now read as passing checks with a detail line; the results screen no longer carries the "Automated detection did not run" line — the Detection Sweep row reports what the structured detectors observed on the output, and names and addresses are not swept, which the row states in its collapsed line.
- Verification: the words fully inside a manual region on a page with a text layer are carried into the term checks, so a word you covered by hand that is still readable elsewhere on the output is reported as Attention Needed; a manual region on a page without a usable text layer is noted in the string-search check.
- **Stepping through matches.** As you step through matches with Previous/Next on the parked Search/Scan strip, each match is centred on the page; the page bar steps aside while you step and returns when the sheet expands.
- Diagnostics export: the coverage snapshot share writes inside the per-session directory with complete protection at write time and is withheld while the screen is captured, matching the audit export.
- Verification: the OCR check now reports a redacted term that is still readable outside every redacted region as Attention Needed on both output modes, naming the text on the results screen; it was an informational note before.
- Verification: the text-layer checks report pages without per-page mode data as not checked instead of passing them.
- Verification: a page written as image-only that still carries a text layer now fails the spatial check instead of being skipped; characters whose position could not be measured are reported as not checked; the text-extraction check reads each page's own output mode.
- Verification: the metadata check confirms the producer field carries the fixed value and warns when it does not.
- Export: the creation and modification timestamps the system PDF writer adds are rewritten to a fixed value, like the producer tag; the metadata check confirms all three.
- Documentation: shorter code of conduct; README/CONTRIBUTING/SECURITY trimmed and corrected.
- Documentation: the README links the App Store listing and resecta.app.
- Temporary files: the orphan sweep also runs when the app returns to the foreground; a region change removes the previous output file at once; closing a session removes any leftover intermediate file.
- Documentation: storage wording for Custom Terms and saved regexes, the supported-versions table, the outbound-links and export-metadata passages, and the audit-lint check ids; the documented-counts check runs in the pull-request gate.
- Sharing: a verification result in which a check could not run on part of the output routes Share through the same slide-to-confirm as a skipped verification, listing what those checks reported.
- Verification: the operator re-extraction check scans the decoded operator text in its normalized form as well, as the string search already does, so a term spelled with a compatibility character is reported by both checks.
- Verification results: the text a check names for review and the searches the re-check lists are marked privacy-sensitive, matching the search and review surfaces.
- Saved regexes: the add row and your own patterns now sit above the built-in list.
- Trust strip reads "On-device" again, matching the home screen's tagline.
- Import: the annotation notice also counts filled form fields; their values are drawn by the viewer but are not carried into the output.
- Search: when a regular expression is refused and its shape is one a built-in detector covers, the reason names that detector.
- **Verification Details.** The details list on the results screen opens from a card that summarises the run. Checks that need review, failed, carry a warning or were skipped stay grouped under a Findings header and informational notes under a Notes header; a passing check with nothing more to show is a compact row with a check mark, and checks that did not pass show a status tile with a shape badge, with rows that need review or failed tinted. Check titles drop the "Layer N:" prefix and a check's run time moves into its expanded detail. A check's detail text no longer repeats its summary line, and the spatial check's edge-touch warning lists every page it links.
- Scan: names are also recognised after a role or field label's colon, beside a caption's "v.", after a sign-off or a salutation; words such as Plaintiff or DL no longer surface as names alone.
- Scan: context keywords match whole words only; the bare word "number" is no longer a phone cue (phrases such as "phone number" are), so a labelled account number with no phone cue is not read as a phone.
- Scan: a card number no longer starts inside a letter-led token.
- Scanned pages: digit groups joined by spaces, hyphens, dots, slashes or parentheses are read as digits when any group in the run has a clearly read digit.
- Search: pages with many matches no longer drop results, and a cancelled search's results stay out of the next.
- Search: bounded repetition such as `(-\d{4})?` is accepted; a refused pattern shows its reason and a plain-text option, and the re-check lists it as not checked; literal always-flag terms match ligature and full-width forms.
- Documentation: a public threat model (`THREAT-MODEL.md`) with a dated security-posture table; the security policy gains a note on report classes, the machine-readable policy pointer and an advisory-history line.
- Documentation: the README, threat model, engineering notes, security policy, known-issues list and contributing guide re-read against the 1.2.0 tree and corrected; the contributing guide shortened to the gates that exist; the package README's module notes corrected.
- Documentation: the privacy policy's on-device detection paragraph revised and its image-import note dated to the releases that opened images; the agreement's scope paragraph and one heading corrected.

### Removed

- Image input: this release opens PDF files only; 1.0.0 and 1.1.0 also opened JPEG, PNG and HEIC images from Files or a drop. The Files picker lists PDFs, a dropped image is declined with the unsupported-format message, and that message now names PDF; the first-launch agreement screen and the empty sidebar say PDF, and the Paranoid Mode note no longer mentions Live Photos.

### Fixed

- Searchable Redaction: on pages stored with a rotation, the text layer is rebuilt along the source lines and reads in the source's order; the spatial check reads the layer along the axis its lines run on. The rebuilt layer on such pages was previously assembled across lines and could run off the page.
- A page with an unsupported size or scale factor is reported as unsupported page geometry instead of a memory failure.
- Temporary files: the foreground sweep leaves the open document's session directory in place, and a session directory removed behind the app is re-created before the next export.
- Redact: the regions, terms and settings a run uses are read once when the run starts, and a region drawn while the run is starting is included in that run; the changed-since-verification notice follows the regions the run burned; an import is declined while a run is pending, and closing the document cancels a pending run first.
- Search: the live preview's count honours the text-layer classification and counts multi-term AND mode by page.

### Security

- Links inside an imported document are not followed when tapped in the editor, and data detectors are turned off for the document the editor shows.
- Import: a document that carries JavaScript or a launch action in its catalog's name tree, in its open action, in a page's additional actions, or in an annotation's action is refused at import, as a document with those entries at the top of the catalog already was. The refusal names active content instead of a damaged file.
- Redact: a page whose rotation is not a right angle is refused before rendering, and the render follows the rotation the viewer displays.
- Export: the file identifier the system PDF writer adds is rewritten to a value derived from the file's own contents, so it carries nothing about the device, the build or the moment of export; the metadata check confirms it. Two exports of identical content carry the same identifier.
- Searchable Redaction: a page whose unmarked text shows no ink (white on white, invisible, or under a box drawn into the page) is exported as an image only; the results screen names the reason.
- Detection assets: each bundled table is checked against the size and SHA-256 digest the signed manifest lists for it at first load; a mismatch on any signature-gated table withholds all five signature-gated loaders and raises the degraded-detection banner, and a mismatch on one of the other tables, the classifier assets or the audit rule catalog raises the banner while the asset stays in use unless its own loader rejects it.
- Detection assets: every versioned table fences its wire version; a table from another schema is refused by name and, for all but the nickname and name common-word lists and the audit rule catalog, reported through the load diagnostics.
- Detection assets: the manifest signing key was rotated; the bundled public key's fingerprint is pinned by a test, and the data pipeline's `KEY-MANAGEMENT.md` describes how the key is held, backed up and rotated.
- Verification: outcomes a check could not fully verify — a page OCR did not read, characters without a measurable position, terms too short to search — take precedence over informational notes and reach the report as could-not-verify; a page with both in-region text and a redacted term outside every region reports the stronger of the two.
- Verification: an encrypted output fails the structure check, whether or not it opens without a password.
- Search: the regular-expression gate refuses more shapes whose matching time can grow exponentially; the gate's accept/reject checks run in the gating test suite.
- Custom terms: a slow always-flag term no longer uses up the page's time budget for the terms after it; a term that runs out of time is reported as not fully checked on that page.

### Internal

- Polygon regions, which the editor does not offer in this release: a polygon that covers no pixel is reported as a failed fill, and the polygon commit path applies the rectangle tool's 10-point minimum size.
- CI: the engine host suite runs on demand only; the pull-request gate's base-branch lint set includes the silent-guard scanner, and a missing or failing scanner fails the gate; `Scripts/release-flag-check.sh --archive` checks an archived app for debug-only launch arguments and bundled test fixtures as a recorded release step; the app's unit suite runs on pull requests to `main` as a non-required check and both batched suites run weekly.
- Engine: the public surface is narrowed toward the document-runner API, whose symbols are pinned at compile time (`EnginePublicSurfaceTests`); many detection, search and model internals become `internal`.

## [1.1.0] — 2026-08-28

### Added

- **Run-facts disclosure on the verification results screen.** Lines beneath the verdict state what the run did not cover: pages too large to scan for text, runs where detection never ran, and a degraded detector.
- **Post-share acknowledgment.** A "Shared." toast after the share sheet reports completion.
- **Review orientation line.** "N pages · M with hits" beneath the sheet header after a completed run; the page bar stays reachable while the sheet is parked at its compact height.
- **Zero-result guidance.** The zero-result state reads "No items flagged" with a calibration line and pointers to the existing controls.
- **Home from the editor.** The iPhone editor's overflow menu offers Home, which closes the open document and returns to the home screen (it replaces the menu's Open Document entry; opening a file is done from the home screen).
- **Apply from the minimized bar.** The minimized Search/Scan bar now includes an Apply button that marks just the result you are viewing; the bar is slightly taller.

### Changed

- **Share confirm for reported issues.** The alert is now a sheet that lists the reported items and completes with a slide gesture; it also covers runs whose checks were partly skipped. Backing out of the share sheet re-arms the confirm; a completed share leaves it spent for that report.
- **Confidence reads as a tier** — high, medium, or low — on review rows and region details, instead of a number.
- **Apply toast** names the remaining step: nothing is redacted until you tap Redact.
- **Dialog grammar** normalized across confirms (sentence-case question titles, verb buttons; the import-while-editing confirm reads "Replace").
- **Touch targets** floored at the default type size on the page bar, review rows, sheet header and footer buttons, popups, chips, and the canvas resize handles.
- **Reduce Motion** now applies to every slide-in transition; the post-run banner tints orange only for warnings; toast and status colors use the measured text tier; the editor toolbar keeps the brand tint on Redact only; search option toggles wait for a running search.
- **Easier-to-read support text.** The home and verification screens render their explanatory text one size larger in a darker grey; the version line and the On device / No tracking / Open source strip are no longer faint.
- **Results screen layout.** The verdict title now leads the screen directly beneath the toolbar (the symbol slot above it is removed), and a passing run shows the title alone (the "All N verification checks completed" line beneath it is gone; the check count stays in the Verification Details row). The audit-scope note closes the screen well beneath the run's timing line, the top-left toolbar button is Home, and the home screen's Settings button uses the same neutral tint as the editor toolbar.
- **Result navigation.** The Previous/Next result buttons now step through matches with the review sheet parked at its compact height, where the buttons and the position counter stay available; the current match is outlined on the page, and the list scrolls to it when the sheet is expanded.
- **Result rows.** Search and scan matches now appear highlighted inside their surrounding text, with page labels carried by the section headers and the selection count and Select All in the footer.
- **Stepping through results now zooms small matches to a readable size** and returns to the full page for large ones; on single-page documents the page stays clear of the parked search strip.

### Removed

- Unreferenced code and assets across the app and engine (no behavior change; detection outputs unchanged).
- **"Snap to Text Boxes" setting.** Rectangle edges align to other boxes and page guides; the text-row assist the setting described is not available in this release.
- **The "Add to selection…" menu** in the review sheet's footer (select-where). Rows select one at a time or with Select All; Deselect All clears.
- **The "Reason:" summary line** beneath an expanded result row. Details still opens the match rationale, which carries the detector's signals, the scores, and now that summary line.
- **The confidence word on search and scan result rows.** The match confidence is read in the match rationale; each row's colored edge is unchanged.

### Fixed

- **Verification matches ligature and compatibility forms.** The verification pass now matches ligature and compatibility forms of a sensitive term — the same normalization the search path applies — so a residue the search can locate is never invisible to the verifier.
- **A transient face-detection error no longer discards a page's other detections.**
- **Truthful degraded-detection diagnostics.** On a gazetteer-manifest signature failure the diagnostics name only the signature-gated corpora; the three reference tables that load outside the signature are no longer attributed to it, and the public detector initializer now honours the same signature verdict.
- **Drawing beneath the minimized review sheet.** With the Scan or Search sheet parked at its compact height, drawing, moving and resizing regions on the page now work; the sheet's drag gesture on iOS 26 no longer cancels the touch before the page receives it.
- **The review sheet closes when Redact starts.** Tapping Redact closes the Scan or Search sheet before the run, so it no longer covers the progress card, the results screen or the preview; Keep Editing returns with Scan and Search available again.
- **Zoom floor on the document view.** Pinching out stops at the page's fit size — the whole page in view — in the editor and in the redacted preview; the page no longer shrinks into the canvas background.
- **Rectangle tool.** Drawing always starts a new box while the tool is on (existing boxes are moved or resized with the tool off); a box's starting corner stays put while its far edge aligns to guides; boxes stay within the page; the canvas redraws after every gesture (no lingering dashed box, size label, or guide lines); size and touch thresholds are measured on screen so they feel the same at any zoom; turning the tool on clears the selection and the Add-to-Selection toggle.
- **Applying search results twice in quick succession can no longer duplicate regions.** Applies are serialized: a second apply waits for the first to commit and then skips every match the first already covered.

### Internal

- Test-suite integrity: assertion-free and tautological tests replaced or removed; the Settings suites are isolated; the perf-isolation list is complete; the pre-push hook runs the batched test runner.
- GitHub Actions: a pull-request gate (XcodeGen, app + test-bundle builds, audit and claims lints on the diff, shipped-asset hash fence); on-demand and release-tag workflows for the engine host suite and the batched simulator suite; `audit-lint.sh` gains a commit-range mode.
- Toast enqueueing uses static main-actor isolation instead of a runtime thread check.
- Regenerated gazetteer, context-keyword, adversarial and packet fixtures: provenance prose only, entry counts unchanged; fixture hash pins updated. Context assets per the approved change plans: the negative-context placeholder entry is `corp.`, the bare `ein`/`mbi` suppression tokens are label phrases (166 → 171 entries), labeled license plates carry their own context words, multi-word doctype keywords are single tokens, and the FOIA and generic doctype vocabularies are rebalanced.
- The license-plate context-keyword fallback profile carries the same positive terms as the bundled context-keyword asset.
- Comments, test names and documentation rewritten to stand alone: ticket vocabulary, references to private planning documents and decision-record prose removed tree-wide; README and ENGINEERING counts regenerated by `Scripts/doc-metrics.sh`; CONTRIBUTING's branch name and sign-off posture updated.

## [1.0.0] — 2026-08-12

Initial public release.

### Added

- **Two redaction modes.** Secure Rasterization produces image-only output with a 5-layer verification pass. Searchable Redaction preserves non-redacted text via a fresh monospace font with uniform spacing — designed to remove the glyph-positioning side channels identified in academic research on sandwich PDFs — and runs a 10-layer verification pass (the five additional layers cover the preserved-text layer).
- **Two marking interfaces: Scan and Search.** Scan runs the on-device PII text detectors across the document and stages what they flag for review. Search matches exactly what you ask for, in three modes — Text, Regex, and Multi-term. Both interfaces deliver results into one review list with one selection model and one apply path, and each keeps its own saved list (saved scans; saved searches).
- **Review-first arrival.** Results arrive with nothing selected; a redaction happens only for items you explicitly select and apply.
- **On-device PII detection.** Regex patterns plus `NLTagger` named-entity recognition. Bundled gazetteers: federal-agency institution names (1,343 rows), address components, ZIP-to-state mapping, surname and given-name Bloom filters.
- **Custom Terms.** Single-entry CRUD for user-defined detection terms. Bulk operations (paste-many, CSV import / export, share-profile) are not part of this release.
- **Audit export schema (surface disabled in V1.0).** The v4 match-audit wire schema ships in code, with the user-facing export surface disabled for this release; enabling it is scoped to a future release.
- **Doctype temperature and preset thresholds** calibrated against an iPhone 17 / A19 softmax dump.
- **Core workflow** — Import → View → Mark → Apply → Verify → Export — covering PDF input from Files or the bundled sample document, with export via the system share sheet. The Files picker and drag-and-drop also accepted image files such as JPEG, PNG and HEIC, each redrawn from its pixels as a one-page PDF.

### Removed

- **The "Review Detections Before Applying" setting** (during pre-release development). Review-before-apply is the only behavior now: detected items always stage for review, and nothing is applied without an explicit selection, so the opt-out toggle was removed.
- **The per-run confidence slider** (during pre-release development). Detection Sensitivity in Settings is the one detection-level control; result lists show every above-threshold result, with confidence sorting and select-where filters in the slider's place.

### Security

- **No network requests of its own.** The codebase contains no `URLSession` or `NWConnection` usage. Verifiable at the source level via `grep`.
- **No accounts, no analytics, no telemetry, no server-side components.**
- **Document metadata stripped on export** — author, editing history, tagged structure, and other source metadata fields are removed from exported documents. The rebuilt file carries a producer tag replaced with a fixed value ("Resecta", identifying neither the operating system version nor the build), and fresh creation/modification timestamps from the system PDF writer (not metadata-free — see `PRIVACY.md`).
- **Pixel-destruction core shared by both modes.** Every page is rasterized, marked or not; vector text and images are converted into flat bitmap data, and the redaction process is designed to remove the original text layer from marked regions.
- **Searchable Redaction text-layer design.** The reconstructed text layer uses a fresh monospace font with uniform spacing, designed to remove the glyph-positioning side channels identified in academic research on sandwich PDFs.

[Unreleased]: https://github.com/Merlin1A/resecta/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/Merlin1A/resecta/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Merlin1A/resecta/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Merlin1A/resecta/releases/tag/v1.0.0
