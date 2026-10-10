#!/bin/sh
# 在 mint-dev 容器內執行：編譯 shim 與宿主，依序跑各模式。
# 每次執行都用全新的 HOME / XDG 目錄，避免引擎寫進 UserDefaults 的偏好設定影響下一次。
set -e
cd "$(dirname "$0")"
swift build 2>&1 | tail -1
mkdir -p build
cc -O1 -g -Wall -o build/host host/host.c -ldl
LIB="$PWD/.build/debug/libVGShim.so"
MAP="$PWD/../vendor/vChewing-LibVanguard/Sources/LXAssemblyMaterials4Tests/Resources/vanguardTextMap_test.txtMap"
for mode in ${@:-none runloop aftercall fd}; do
  echo "=== $mode ==="
  SANDBOX="$PWD/build/home-$mode"
  rm -rf "$SANDBOX" && mkdir -p "$SANDBOX"
  HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" XDG_DATA_HOME="$SANDBOX/.local/share" \
    timeout 30 ./build/host "$LIB" "$MAP" "$mode" || echo "(exit $?)"
  echo "--- 引擎在 HOME 底下留下的檔案："
  (cd "$SANDBOX" && find . -type f | head -20)
done
