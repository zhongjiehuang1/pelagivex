#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The standalone macOS Command Line Tools ship Swift Testing outside the default search paths.
developer="$(xcode-select -p)/Library/Developer"
if [[ -f "$developer/usr/lib/lib_TestingInterop.dylib" && -d "$developer/Frameworks/Testing.framework" ]]; then
  exec swift test --disable-xctest -Xswiftc -F -Xswiftc "$developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$developer/Frameworks" -Xlinker -rpath -Xlinker "$developer/usr/lib" "$@"
fi
exec swift test --disable-xctest "$@"
