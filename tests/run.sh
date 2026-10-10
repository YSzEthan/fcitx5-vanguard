#!/bin/sh
# 在 mint-dev 容器內執行：編譯引擎與外掛，啟動真的 fcitx5 行程，透過 DBus 前端送按鍵驗證。
#
# 隔離：容器跟主機共用 session bus 與 /run/user，主機上有使用者在用的 Fcitx5。
# 所以這裡用 env -i 清掉環境、另開一條私有的 DBus（dbus-run-session）、
# HOME 與 XDG 目錄全部指到沙盒，不設 DISPLAY / WAYLAND_DISPLAY，fcitx5 只啟用需要的外掛。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

(cd engine && swift build 2>&1 | tail -1)
PREFIX="$ROOT/addon/prefix"
cmake -S addon -B addon/build -G Ninja -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build addon/build 2>&1 | tail -1
cmake --install addon/build >/dev/null

SANDBOX="$ROOT/addon/build/sandbox"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/home/.config/fcitx5" "$SANDBOX/run"
chmod 700 "$SANDBOX/run"
cp tests/profile "$SANDBOX/home/.config/fcitx5/profile"

exec env -i \
  PATH=/usr/bin:/bin \
  LANG=C.UTF-8 \
  HOME="$SANDBOX/home" \
  XDG_CONFIG_HOME="$SANDBOX/home/.config" \
  XDG_DATA_HOME="$SANDBOX/home/.local/share" \
  XDG_CACHE_HOME="$SANDBOX/home/.cache" \
  XDG_RUNTIME_DIR="$SANDBOX/run" \
  XDG_DATA_DIRS="$PREFIX/share:/usr/share" \
  FCITX_ADDON_DIRS="$PREFIX/lib/fcitx5:/usr/lib/x86_64-linux-gnu/fcitx5" \
  FCITX5_VANGUARD_TEXTMAP="$ROOT/vendor/vChewing-LibVanguard/Sources/LXAssemblyMaterials4Tests/Resources/vanguardTextMap_test.txtMap" \
  FCITX5_LOG="$SANDBOX/fcitx5.log" \
  dbus-run-session -- python3 "$ROOT/tests/dbus_typing_test.py" "$@"
