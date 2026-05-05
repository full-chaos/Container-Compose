# Define variables.
prefix      ?= /usr/local
bindir       = $(prefix)/bin
binary_name  = container-compose
swift_product = container-compose
release_bin  = .build/release/$(swift_product)

# Default target: a release build.
.PHONY: all build release debug test test-json build-tests coverage clean install uninstall help

all: build

# Release build of just the CLI product. --product narrows the dependency
# closure to the executable's deps, so TestHelpers (which uses @testable
# import) is not pulled into the release build.
build release:
	swift build -c release --product $(swift_product) --disable-sandbox

# Debug build for local development.
debug:
	swift build --product $(swift_product)

# Compile both the executable and every test target without running them.
# Mirrors what CI does (`swift build --build-tests`) — useful as a fast
# check that the package still type-checks.
build-tests:
	swift build --build-tests

# Run the entire test suite. Dynamic tests skip themselves on hosts where
# Apple `container` isn't installed (see Tests/TestHelpers/RuntimeAvailability.swift),
# so this is safe to run on CI without the runtime.
test:
	swift test

# Run the static suite under swift-testing's event stream and emit a structured
# report. Useful for agent-driven test reading or CI parsing. Defaults to
# fast-feedback path: skipping the dynamic Apple-container target (use
# `make test` for the full run including dynamics).
#
# NOTE: --parallel intentionally NOT used. The static suite contains tests
# (ResourceArgsTests, LifecycleArgsTests, GpusBlkioTests) that `dup2` global
# STDOUT_FILENO to a Pipe to capture printed warnings; under --parallel they
# race on the shared FD and `readDataToEndOfFile()` hangs indefinitely.
#
# Exit code mirrors the report: 0 = all passed, 1 = any failed, 2 = no events.
test-json:
	rm -f .build/test-events.jsonl
	-swift test --skip Container-Compose-DynamicTests --experimental-event-stream-output .build/test-events.jsonl
	swift run test-report .build/test-events.jsonl --format json

# Regenerate coverage.json from the inline JSON in coverage.html.
coverage:
	bash scripts/regen-coverage.sh

clean:
	rm -rf .build

install: build
	install -d "$(bindir)"
	install "$(release_bin)" "$(bindir)/$(binary_name)"

uninstall:
	rm -f "$(bindir)/$(binary_name)"

help:
	@echo "Targets:"
	@echo "  build / release   Release build of $(binary_name)"
	@echo "  debug             Debug build of $(binary_name)"
	@echo "  build-tests       Compile tests without running (CI-equivalent)"
	@echo "  test              Run all tests (dynamic ones self-skip without Apple container)"
	@echo "  test-json         Run static tests + emit structured JSON report (skips dynamic; for agents/CI)"
	@echo "  coverage          Regenerate coverage.json from coverage.html"
	@echo "  clean             Remove .build/"
	@echo "  install           Build + install to \$$(bindir) (default $(bindir))"
	@echo "  uninstall         Remove the installed binary"
