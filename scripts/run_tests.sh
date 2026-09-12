#!/bin/bash
set -e
swift build
swiftc -I .build/arm64-apple-macosx/debug/Modules .build/arm64-apple-macosx/debug/Whoopsy.build/*.o Tests/WhoopsyTestRunner/main.swift -o .build/WhoopsyTestRunner
./.build/WhoopsyTestRunner
