# The commands this repo actually needs, so nobody re-derives them from CLAUDE.md.
#
#   make test                 # build + run all 20 sections
#   make test SECTIONS=13,15  # just those two
#   make ios                  # the real iOS build path
#   make verify               # build + test + ios — the pair CLAUDE.md insists on
#   make backend-check        # the Worker's own gate — NOT part of `verify`
#
# `make build` and `make test` are the fast edit/compile loop. `make ios` is the shipping target and
# a different compiler invocation entirely: a green iOS build is not a green host build, and vice
# versa, which is why `verify` runs both.

.PHONY: build test ios verify backend-check clean

SECTIONS ?=

build:
	swift build --package-path ios

test:
	@./scripts/test.sh $(SECTIONS)

# `xcode-select` points at CommandLineTools on this machine, so bare `xcodebuild` errors out and
# `xcrun --sdk iphoneos` cannot find the SDK. The DEVELOPER_DIR prefix sidesteps that without a
# `sudo xcode-select -s`. `-scheme`, not the legacy `-target`: the latter cannot resolve SwiftPM
# dependencies and fails with `Unable to resolve module dependency: 'GRDB'`.
#
# CODE_SIGNING_ALLOWED=NO because there is no development team and no certificate — this builds
# everything up to signing, which is how to check iOS compilation without one.
ios:
	DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
	  xcodebuild -project ios/Whoopsy.xcodeproj -scheme WhoopsyApp \
	  -destination 'generic/platform=iOS' \
	  -derivedDataPath $(CURDIR)/tmp/build/whoopsy-dd \
	  CODE_SIGNING_ALLOWED=NO build

verify: build test ios

# The Worker's own gate, and the four steps are one argument: install, prove the types, prove the
# behaviour, then prove the committed contract is the one the code generates. The last step is why the
# generator writes unconditionally — a run that changed nothing rewrites identical bytes, so this
# `git diff` answers "is `shared/openapi.json` current?" and not a second question about intent.
#
# **Deliberately NOT a prerequisite of `verify`.** `verify` is the pair CLAUDE.md insists on — a green
# iOS build is not a green host build — and it must stay runnable without a Node toolchain, a
# `node_modules` install and a network. `npm ci` here is also what the lockfile is for: it installs
# exactly what CI will, where `npm install` would quietly resolve something newer.
backend-check:
	npm --prefix backend ci
	npm --prefix backend run typecheck
	npm --prefix backend test
	npm --prefix backend run openapi
	git diff --exit-code -- shared/openapi.json

# Build output lives under the repo's own `tmp/build/` so nothing is written outside the tree;
# it is gitignored, and `tmp/README.md` says what the folder is for.
clean:
	rm -rf $(CURDIR)/tmp/build
