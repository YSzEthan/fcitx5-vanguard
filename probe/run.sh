#!/bin/sh
# 在 mint-dev 容器內執行：編譯探針與宿主，依序跑三種模式。
set -e
cd "$(dirname "$0")"
swift build 2>&1 | tail -3
mkdir -p build
cc -O1 -g -Wall -o build/host host/host.c -ldl
LIB="$PWD/.build/debug/libVGProbe.so"
for mode in ${@:-none runloop fd}; do
  echo "=== $mode ==="
  timeout 20 ./build/host "$LIB" "$mode" || echo "(exit $?)"
done
