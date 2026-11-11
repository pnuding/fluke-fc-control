#!/bin/bash
# Runs the FlukeCore unit tests. This Mac has only the Command Line Tools (no Xcode), whose Swift
# Testing install lives outside the default search paths, hence the framework flags.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW="$(xcode-select -p)/Library/Developer/Frameworks"
cd "$DIR"
swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" "$@"
