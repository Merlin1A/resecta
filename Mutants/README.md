# Mutants

Each file here is a deliberate bug, kept as a patch, that the tests named in its header must fail on.
A mutant shows that a check's tests can fail: if a patch applies and every named
test still passes, the tests do not pin the property the patch breaks.

## How to run one

1. Make a scratch worktree at the commit under review: `git worktree add --detach ../mutant-check <commit>`.
2. In it, `git apply Mutants/<name>.patch`.
3. Run the test command in the patch's header (it names the Xcode, the scheme and the tests; one patch has two commands).
4. Every test listed under "Must go red" must fail. Record the result, then remove the worktree.

The person who reviews a change runs its mutants; its author does not. A patch is named `<area>-<property>.patch`.
A mutant that no test can expose because another guard already makes it harmless is listed as EQUIVALENT,
with its reason and the mutant that is caught in its place.

## Index

| patch | property | must go red |
|---|---|---|
| `hidden-word-drift-correction.patch` | Each surviving word is placed by its line's fitted drift, not by its raw position. | RedactionEngineTests/HiddenWordInkPredicateCases V1 (predicate); RedactionEngineTests/HiddenWordInkPredicateCases V18c; RedactionEngineTests/HiddenWordInkPredicateCases V19 (b); RedactionEngineTests/HiddenWordInkPredicateCases V20; RedactionEngineTests/HiddenWordInkLayerCases V1; RedactionEngineTests/HiddenWordInkLayerCases V2; RedactionEngineTests/HiddenWordInkLayerCases V3 (the RED); RedactionEngineTests/HiddenWordInkLayerCases V4 |
| `hidden-word-unsure-never-passes.patch` | A page with a word it could not place near a box, or a page it could not read, never reads pass. | RedactionEngineTests/HiddenWordInkLayerCases V12; RedactionEngineTests/HiddenWordInkLayerCases V13 |
| `hidden-word-attribution-by-print.patch` | A flagged word is attributed to the box over the word's print, never the box over its hidden glyphs. | RedactionEngineTests/HiddenWordInkPredicateCases V5 |
| `hidden-word-own-fold.patch` | The layer folds its own pages (could-not-verify kept, notes and nothing-to-check kept), not through PerPageOutcomes.record. | RedactionEngineTests/HiddenWordInkLayerCases V10; RedactionEngineTests/HiddenWordInkLayerCases V11; RedactionEngineTests/HiddenWordInkLayerCases V12; RedactionEngineTests/HiddenWordInkLayerCases V13 |
| `hidden-word-centre-rule.patch` | A word is flagged only when the centre of its placed print is inside the paint; one that only crosses the edge is a note. | RedactionEngineTests/HiddenWordInkPredicateCases V16 |
| `hidden-word-near-box-only.patch` | An unplaceable word changes the page only when it could lie under a box. | RedactionEngineTests/HiddenWordInkPredicateCases V17 |
| `hidden-word-offset-plus-scale.patch` | Three or more anchors fit an offset plus a scale along the line, not a shift alone. | RedactionEngineTests/HiddenWordInkPredicateCases V19 (a); RedactionEngineTests/HiddenWordInkPredicateCases V19 (b) |
| `hidden-word-print-by-position.patch` | Whether a placed word has print is decided by position; text keys only choose anchors. | RedactionEngineTests/HiddenWordInkPredicateCases V1 (predicate); RedactionEngineTests/HiddenWordInkPredicateCases V18c |
| `hidden-word-residual-slack.patch` | Anchors must agree within the residual slack, never merely within the drift bound. | RedactionEngineTests/HiddenWordInkPredicateCases V18; RedactionEngineTests/HiddenWordInkPredicateCases V18b |
| `hidden-word-two-anchor-offset.patch` | Exactly two anchors fit an offset alone (scale 1), never an exact line through both. | RedactionEngineTests/HiddenWordInkPredicateCases V18b |
| `hidden-word-ordinal-pairing.patch` | A repeated key is paired by its order on the line, never by the nearest copy. | RedactionEngineTests/HiddenWordInkPredicateCases V20b |
| `hidden-word-align-by-order.patch` | Between candidates inside a word's window, the order of the line's words decides, never the nearest position. | RedactionEngineTests/HiddenWordInkAlignCases (c); RedactionEngineTests/HiddenWordInkAlignCases (d) |
| `hidden-word-unaligned-not-absent.patch` | An export word that cannot be aligned is never read as absent: near a box it leaves the page not inspected. | RedactionEngineTests/HiddenWordInkAlignCases (d′); RedactionEngineTests/HiddenWordInkAlignCases (e′) |
| `hidden-word-align-window.patch` | A candidate counts only inside the word's window (1.5 of its cells plus the slack, from zero or a neighbour); a unique match outside it is unaligned. | RedactionEngineTests/HiddenWordInkAlignCases (a′); RedactionEngineTests/HiddenWordInkAlignCases (f‴) |
| `hidden-word-axis-from-rotation.patch` | The along axis is the page rotation's, for the alignment, the predicate and the reach; a line's own spread only cross-checks it. | RedactionEngineTests/HiddenWordInkAlignCases V22 (axis) |
| `hidden-word-predicate-axis.patch` | The predicate takes the line's axis from the page rotation, not from the words' spread. | RedactionEngineTests/HiddenWordInkPredicateCases V23 |
| `hidden-word-fitted-window.patch` | An unaligned word on a fitted line is near a box when its window mapped through the fit meets the paint, as well as by the drift reach. | RedactionEngineTests/HiddenWordInkAlignCases (e‴) |
| `hidden-word-not-inspected-not-pass.patch` | A word that could lie under a box but cannot be placed makes the page not inspected, never clean. | RedactionEngineTests/HiddenWordInkPredicateCases V8; RedactionEngineTests/HiddenWordInkPredicateCases V9; RedactionEngineTests/HiddenWordInkPredicateCases V18; RedactionEngineTests/HiddenWordInkPredicateCases V18b; RedactionEngineTests/HiddenWordInkPredicateCases V5b; ResectaAppTests/HiddenWordInkRunCases V15 |
| `hidden-word-align-chain.patch` | A word's window is also centred on its nearest aligned neighbours' offsets, so a group's growing offset aligns. | RedactionEngineTests/HiddenWordInkAlignCases (f); RedactionEngineTests/HiddenWordInkAlignCases (f′) |
| `hidden-word-align-cap.patch` | However the chain runs, a match more than six of the word's cells from its glyphs is never accepted. | RedactionEngineTests/HiddenWordInkAlignCases (f⁗) |
| `hidden-word-align-rounds.patch` | Alignment is judged in rounds against the alignments at each round's start, so the result does not depend on list order. | RedactionEngineTests/HiddenWordInkAlignCases (f-shuffle); RedactionEngineTests/HiddenWordInkAlignCases (f″) |
| `ink-fit-key-without-page.patch` | A page's ink-fit box is placed from that page's own read, never from another page's that shares its text, box and picture; the page's index in its document is part of the content key. | RedactionEngineTests/InkFitPageIdentityTests pagesWithOneTextAreFittedApart |
| `share-hint-whole-gate.patch` | Share's hint is spoken exactly when the Share tap's gate would ask. | ResectaAppTests/VerificationResultsActionsTests hintForEachFamily; ResectaAppTests/VerificationResultsActionsTests hintAgreesWithTheGate |
| `paused-notice-ends-in-state.patch` | The paused notice's leaving the screen does not end the pause it reports. | ResectaAppTests/DocumentEditorViewBackgroundBannerTests testPausedNoticeHasNoLeavingHook |
| `verification-fragment-lead-reads-the-flag.patch` | A part-of-a-word result opens with no search remedy. | ResectaAppTests/VerificationRowModelTests fragmentResultHasNoSearchLead |
| `verification-whole-word-lead-kept.patch` | A whole-word result still opens with the search remedy. | ResectaAppTests/VerificationRowModelTests fragmentResultHasNoSearchLead; ResectaAppTests/VerificationRowModelTests needsReviewCaptionIsPrivacySensitive; ResectaAppTests/VerificationRowModelTests expandedBlockItemsPerOutcome; ResectaAppTests/VerificationRowModelTests contentStreamStopLine; ResectaAppTests/VerificationResultsActionsTests pagesOnChipsCaptions |
| `verification-fragment-lead-by-flag-not-check.patch` | The search remedy is left out by the part-of-a-word flag, not by which check it is. | ResectaAppTests/VerificationRowModelTests fragmentResultHasNoSearchLead; ResectaAppTests/VerificationRowModelTests expandedBlockItemsPerOutcome |
| `verification-fragment-keeps-stop-line.patch` | A part-of-a-word result keeps the content-stream stop line. | ResectaAppTests/VerificationRowModelTests fragmentResultHasNoSearchLead |
| `custom-terms-read-at-init.patch` | The custom-terms store holds its file's list from its first moment. | ResectaAppTests/UserTermsStoreHydrationTests "A term added the moment the store exists keeps every stored term" [.alwaysFlag]; ResectaAppTests/UserTermsStoreHydrationTests "A term added the moment the store exists keeps every stored term" [.neverFlag]; ResectaAppTests/UserTermsStoreHydrationTests "The duplicate check and the cap read the stored list from the first moment"; ResectaAppTests/StoreHydrateOffMainActorTests "UserTermsStore loads synchronously: the stored list is visible from init" |
| `results-fold-no-headed-list.patch` | A run where every check passed draws no headed list of checks; its checks are inside the closed row. | ResectaAppTests/VerificationResultsActionsTests noHeadedListOfChecks; ResectaAppUITests/SearchRecheckUITests testSearchRecheck_appliedTextSearch_rowReadsCheckPassed |
| `results-fold-members-on-a-clean-run.patch` | On a run where every check passed, the row holds every check. | ResectaAppTests/VerificationResultsActionsTests listRowHoldsThePassedChecks |
| `results-fold-clean-run-arrives-closed.patch` | The row arrives closed on a clean pass; it opens on arrival only for riding notes. | ResectaAppTests/VerificationResultsActionsTests listRowHoldsThePassedChecks |
| `results-fold-riding-note-arrives-open.patch` | With a riding note and nothing above, the row arrives open. | ResectaAppTests/VerificationResultsActionsTests listRowHoldsThePassedChecks; ResectaAppTests/VerificationResultsActionsTests clusterRules |
| `results-idle-checks-are-members.patch` | The checks that had nothing to check are members of the list row. | ResectaAppTests/VerificationLayerPartitionTests idleChecksJoinTheList; ResectaAppTests/VerificationShareHonestyTests couldNotVerifyGroupRendersAboveTheCluster |
| `results-idle-checks-not-twice.patch` | While the list row exists, the checks that had nothing to check have no group of their own. | ResectaAppTests/VerificationLayerPartitionTests idleChecksJoinTheList; ResectaAppTests/VerificationShareHonestyTests couldNotVerifyGroupRendersAboveTheCluster |
| `results-idle-checks-in-order.patch` | The row's members are in the checks' own order, not passed then idle. | ResectaAppTests/VerificationLayerPartitionTests idleChecksJoinTheList |
| `results-idle-checks-group-without-a-row.patch` | With no list row, the checks that had nothing to check keep their group. | ResectaAppTests/VerificationLayerPartitionTests idleChecksJoinTheList; ResectaAppTests/VerificationShareHonestyTests couldNotVerifyGroupRendersAboveTheCluster |
| `results-idle-checks-counted-in-title.patch` | The row's title and spoken label count the checks that had nothing to check. | ResectaAppTests/VerificationLayerPartitionTests nothingToCheckGroupAndHeaders |
| `results-idle-checks-not-wholly-clean.patch` | A run with a check that had nothing to check is not wholly clean, so its row arrives closed. | ResectaAppTests/VerificationLayerPartitionTests nothingToCheckGroupAndHeaders; ResectaAppTests/VerificationLayerPartitionTests aRunWithIdleChecksArrivesClosed |
| `results-idle-checks-closed-with-the-row.patch` | Closing the row closes an open idle member as well as a passed one. | ResectaAppTests/VerificationLayerPartitionTests closingTheListClosesItsOpenMember |
| `results-idle-checks-keep-their-reason.patch` | An idle member keeps its mark and its reason; only a passed check is drawn bare. | ResectaAppTests/VerificationLayerPartitionTests memberRowsKeepTheirReasons |
| `results-facts-lines-whole.patch` | A run line is shown whole; its instruction never goes behind a tap. | ResectaAppTests/FactRowTests todaysLinesAreShownWhole |
| `results-facts-deselection-after-page-modes.patch` | The row about items left unredacted comes after Page Modes. | ResectaAppTests/FactRowTests cardOrder |
| `results-facts-chevron-only-with-more.patch` | A fact has a chevron, and opens, only when it has something to open to. | ResectaAppTests/FactRowTests aFactOpensOnlyWhenThereIsSomethingToOpen; ResectaAppTests/FactRowTests todaysLinesAreShownWhole; ResectaAppTests/FactRowTests deselectionIsAFact |
| `results-facts-handed-in-kept.patch` | Facts handed in are placed in the card. | ResectaAppTests/FactRowTests cardOrder |
| `results-facts-one-open-item.patch` | Opening a fact closes an open check. | ResectaAppTests/FactRowTests oneRowOpenAtATime |
| `results-facts-door-row-height.patch` | The link row is at least 46 pt high, whatever its text's height. | ResectaAppTests/FactRowTests linkRowCanBeHit |
| `results-facts-door-row-text-teal.patch` | The link row's label is in the teal made for text, not the tint. | ResectaAppTests/FactRowTests linkRowCanBeHit |
| `results-facts-no-symbol.patch` | The card's rows carry no symbol in front. | ResectaAppTests/FactRowTests cardRowsCarryNoSymbol |
| `results-sweep-limit-on-every-outcome.patch` | The limit's row shows on a run that did not pass as well as on one that did. | ResectaAppTests/FactRowTests limitIsInViewExactlyOnce (secureFail) |
| `results-sweep-limit-only-with-the-check.patch` | A run without the Detection Sweep check has no limit row. | ResectaAppTests/FactRowTests limitIsInViewExactlyOnce |
| `results-sweep-limit-words-read-not-typed.patch` | The limit's words are read from the sweep's own row, not typed again. | ResectaAppTests/FactRowTests sweepLimitRowWordsAndPlace |
| `results-sweep-row-keeps-its-limit.patch` | The sweep's own closed row keeps its two sentences. | ResectaAppTests/DetectionSweepRowCaptionTests captionRendersCollapsedOnly; ResectaAppTests/DetectionSweepRowCaptionTests spokenLabelCarriesTheGate; ResectaAppUITests/SearchRecheckUITests testDetectionSweep_drawnBox_rowPresentAndNoDetectionLine |
| `results-sweep-limit-before-page-modes.patch` | The limit's row comes before Page Modes and the facts about pictures. | ResectaAppTests/FactRowTests sweepLimitRowWordsAndPlace |
| `results-sweep-limit-not-twice.patch` | The limit's row is not shown while the sweep's own row is in view in its group. | ResectaAppTests/FactRowTests limitIsInViewExactlyOnce (secureScreenshot) |
| `results-sweep-limit-kept-when-list-opens.patch` | The limit's row stays where the list of checks arrives open. | ResectaAppTests/FactRowTests limitIsInViewExactlyOnce (securePassRidingNote) |
| `results-sweep-limit-reads-the-groups.patch` | Whether the sweep's row is in view is read from the groups the screen draws, not from a list of its own. | ResectaAppTests/FactRowTests limitIsInViewExactlyOnce (secureAllFailed) |
