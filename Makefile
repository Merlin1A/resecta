# Resecta — repo-level convenience targets.
#
# This Makefile lets PR authors rewrite the
# stress baseline without having to remember the long
# `xcodebuild -only-testing:...` invocation.
#
# Most day-to-day work still goes through Xcode / `./regenerate.sh`
# directly; this file is intentionally small.

SIM_DEST ?= platform=iOS Simulator,name=iPhone 17
ENGINE_PACKAGE ?= Packages/RedactionEngine
STRESS_DIR := $(ENGINE_PACKAGE)/Tests/RedactionEngineTests/IntegrationTests/StressTests

.PHONY: help stress-baseline stress-smoke coverage-report

COVERAGE_BUNDLE ?= /tmp/resecta-cov.xcresult

help:
	@echo "Targets:"
	@echo "  stress-baseline  Run the 500-page stress test and"
	@echo "                   overwrite stress-baseline.json with the result."
	@echo "                   Use this after an intentional perf change."
	@echo "  stress-smoke     Run only the fixture-builder smoke test (fast)."

# Run the long stress test, then promote the emitted result JSON over
# the committed baseline. The test writes its result next to the
# source file (see StressCorpusTests.swift `#filePath` resolver), so
# no extra path arithmetic is needed here.
#
# This target is intended to be run from the repo root. The
# stress baseline runs locally only — there is no remote workflow.
#
# The documented developer gate (pre-push hook) excludes the stress
# suite via
# `-skip-testing:RedactionEngineTests/StressCorpusTests`; this target's
# explicit `-only-testing` is the deliberate opt-in that runs it.
stress-baseline:
	cd $(ENGINE_PACKAGE) && xcodebuild test \
		-scheme RedactionEngine \
		-destination '$(SIM_DEST)' \
		-only-testing:RedactionEngineTests/StressCorpusTests/testStressCorpusBaseline\(\)
	@if [ ! -f "$(STRESS_DIR)/stress-result.json" ]; then \
		echo "stress-result.json missing; baseline not updated"; \
		exit 1; \
	fi
	mv "$(STRESS_DIR)/stress-result.json" "$(STRESS_DIR)/stress-baseline.json"
	@echo "Baseline updated:"
	@cat "$(STRESS_DIR)/stress-baseline.json"

# Cheap sanity check — confirms the fixture builder produces 500
# pages. Useful in iterative development to avoid waiting on the
# full pipeline run.
stress-smoke:
	cd $(ENGINE_PACKAGE) && xcodebuild test \
		-scheme RedactionEngine \
		-destination '$(SIM_DEST)' \
		-only-testing:RedactionEngineTests/StressCorpusTests/testFixtureHas500Pages\(\)

# Advisory line-coverage report. The coverage targets are
# aspirational and NOT CI-enforced (remote CI is
# disabled at the repo level); this target makes them measurable on demand.
# Excludes the 500-page stress suite the same way the developer gate does
# (the `-skip-testing` convention; no xctestplan exists). xccov emits the
# per-target line coverage as JSON; the summary grep uses /usr/bin/grep because
# the shell shims `grep`→ugrep on this Mac, which mangles the flag combo.
coverage-report:
	rm -rf "$(COVERAGE_BUNDLE)"
	cd $(ENGINE_PACKAGE) && xcodebuild test \
		-scheme RedactionEngine \
		-destination '$(SIM_DEST)' \
		-enableCodeCoverage YES \
		-resultBundlePath "$(COVERAGE_BUNDLE)" \
		-skip-testing:RedactionEngineTests/StressCorpusTests
	xcrun xccov view --report --json "$(COVERAGE_BUNDLE)" > coverage-report.json
	@echo "Coverage report written to coverage-report.json"
	@echo "--- Summary (advisory targets; enforcement is manual):"
	@/usr/bin/grep -E '"lineCoverage"|"name"' coverage-report.json | head -40
