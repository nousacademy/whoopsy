# The three commands this repo actually needs, so nobody re-derives them from CLAUDE.md.
#
#   make test                 # build + run all 15 sections
#   make test SECTIONS=13,15  # just those two
#   make ios                  # the real iOS build path
#   make verify               # build + test + ios — the pair CLAUDE.md insists on
#
# `make build` and `make test` are the fast edit/compile loop. `make ios` is the shipping target and
# a different compiler invocation entirely: a green iOS build is not a green host build, and vice
# versa, which is why `verify` runs both.

.PHONY: build test ios verify clean

SECTIONS ?=

build:
	swift build

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
	  xcodebuild -project Whoopsy.xcodeproj -scheme WhoopsyApp \
	  -destination 'generic/platform=iOS' \
	  -derivedDataPath /tmp/whoopsy-dd \
	  CODE_SIGNING_ALLOWED=NO build

verify: build test ios

clean:
	rm -rf /tmp/whoopsy-verify /tmp/whoopsy-dd
