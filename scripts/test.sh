#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/module-cache"

developer="$(xcode-select -p)"
frameworks="$developer/Library/Developer/Frameworks"
macros="$developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=()
if [[ "$developer" == */CommandLineTools && -d "$frameworks/Testing.framework" && -f "$macros" ]]; then
    flags=(-Xswiftc -F -Xswiftc "$frameworks" -Xswiftc -load-plugin-library -Xswiftc "$macros"
        -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi

swift test --disable-sandbox --disable-xctest --build-system native "${flags[@]}"
