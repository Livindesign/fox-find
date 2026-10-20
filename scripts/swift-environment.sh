#!/bin/bash
# Source this file to pair the selected Swift compiler with its own macOS SDK.
# This changes only the current process, never xcode-select or system settings.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  FOX_SWIFTC="$(xcrun --find swiftc)"
  case "$FOX_SWIFTC" in
    */Toolchains/*.xctoolchain/usr/bin/swiftc)
      export DEVELOPER_DIR="${FOX_SWIFTC%%/Toolchains/*}" ;;
    */CommandLineTools/usr/bin/swiftc)
      export DEVELOPER_DIR="${FOX_SWIFTC%/usr/bin/swiftc}" ;;
  esac
  unset FOX_SWIFTC
fi
# /usr/bin/python3 may inject a Command Line Tools SDK into child processes.
# Resolve the selected toolchain's SDK afresh; intentional cross-SDK builds can
# opt in explicitly through FOX_BUILD_SDKROOT.
export SDKROOT="${FOX_BUILD_SDKROOT:-$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)}"
