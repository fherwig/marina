#!/bin/sh
# Let Marina build with the Command Line Tools alone, no Xcode.
#
# Two things in the CLT stand in the way, and each has a way round:
#
# 1. SwiftTerm lists Shaders.metal as a resource to *process*, which needs the
#    `metal` compiler — part of Xcode, not the CLT. Marina never uses the Metal
#    renderer, and SwiftTerm compiles the shader from source at run time when
#    no precompiled library is bundled, so copying the file is enough. The
#    checkout under .build/ is patched in place, which leaves Package.swift and
#    Package.resolved alone.
#
# 2. From the macOS 27 SDK on, SwiftUI's @State is a macro whose plugin
#    (SwiftUIMacros) only Xcode ships. Older SDKs still declare it a property
#    wrapper, so the newest CLT SDK without the macro is used.
#
# 3. Built that way, the linker records the deployment target (14.0) as the
#    SDK the app was built with, and macOS then runs it as a macOS 14 app:
#    the old toolbar, a gap above the sidebar, and clicks in the sidebar
#    landing on the wrong row. The SDK's real version is passed explicitly.
#
# Writes the environment the build needs to .build/clt-env and the extra
# swift build flags to .build/clt-flags (both empty with Xcode).
# Idempotent; `make clean` undoes it.
set -e

ENV_FILE=.build/clt-env
FLAGS_FILE=.build/clt-flags
mkdir -p .build
: > "$ENV_FILE"
: > "$FLAGS_FILE"

case "$(xcode-select -p)" in
    *CommandLineTools*) ;;
    *) exit 0 ;;        # full Xcode: nothing to work around
esac

# 1. SwiftTerm without the Metal compile
if ! xcrun --find metal >/dev/null 2>&1; then
    swift package resolve >/dev/null
    manifest=.build/checkouts/SwiftTerm/Package.swift
    if grep -q '\.process("Apple/Metal/Shaders.metal")' "$manifest"; then
        sed -i '' 's|\.process("Apple/Metal/Shaders.metal")|.copy("Apple/Metal/Shaders.metal")|' "$manifest"
        echo "clt-setup: building SwiftTerm without the Metal compiler" >&2
    elif ! grep -q '\.copy("Apple/Metal/Shaders.metal")' "$manifest"; then
        echo "error: SwiftTerm's Package.swift has changed; Support/clt-setup.sh needs updating." >&2
        exit 1
    fi
fi

# 2. an SDK whose SwiftUI has no @State macro
SDKS=/Library/Developer/CommandLineTools/SDKs
for sdk in $(ls -d "$SDKS"/MacOSX[0-9]*.[0-9]*.sdk | sort -V -r); do
    iface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    [ -f "$iface" ] || continue
    if ! grep -q '"StateMacro"' "$iface"; then
        [ "$sdk" = "$(xcrun --show-sdk-path)" ] || \
            echo "clt-setup: building against $(basename "$sdk") (newer SDKs need Xcode's SwiftUI macros)" >&2
        echo "SDKROOT=$sdk" > "$ENV_FILE"
        # 3. record the SDK actually used, not the deployment target
        minos=$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1.0/p' Package.swift)
        version=$(plutil -extract Version raw -o - "$sdk/SDKSettings.json")
        echo "-Xlinker -platform_version -Xlinker macos -Xlinker $minos -Xlinker $version" > "$FLAGS_FILE"
        exit 0
    fi
done

echo "error: no Command Line Tools SDK can build Marina without Xcode." >&2
echo "       Install Xcode, or use the .pkg from https://github.com/fherwig/marina/releases/latest" >&2
exit 1
