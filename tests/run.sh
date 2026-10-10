#!/bin/sh
# 在 mint-dev 容器內執行：編譯引擎與外掛，啟動真的 fcitx5 行程，透過 DBus 前端送按鍵驗證。
#
# 隔離：容器跟主機共用 session bus 與 /run/user，主機上有使用者在用的 Fcitx5。
# 所以這裡用 env -i 清掉環境、另開一條私有的 DBus（dbus-run-session）、
# HOME 與 XDG 目錄全部指到沙盒，不設 DISPLAY / WAYLAND_DISPLAY，fcitx5 只啟用需要的外掛。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

(cd engine && swift build -c release 2>&1 | tail -1)
PREFIX="$ROOT/addon/prefix"
cmake -S addon -B addon/build -G Ninja -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build addon/build 2>&1 | tail -1
cmake --install addon/build >/dev/null

SANDBOX="$ROOT/addon/build/sandbox"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/home/.config/fcitx5" "$SANDBOX/run"
chmod 700 "$SANDBOX/run"
cp tests/profile "$SANDBOX/home/.config/fcitx5/profile"

LEXICON="$PREFIX/share/fcitx5-vanguard/vanguardTextMap.txtMap"

echo "##### 偏好設定：不經 fcitx5，兩個行程 #####"
PREFS="$ROOT/addon/build/prefs"
rm -rf "$PREFS" && mkdir -p "$PREFS"
cc -O1 -g -Wall -Iengine/include -o addon/build/prefs_host tests/prefs_host.c \
  engine/.build/release/libVGEngine.so -Wl,-rpath,"$ROOT/engine/.build/release"
STATUS=0
for mode in set check; do
  echo "--- $mode"
  env -i PATH=/usr/bin:/bin LANG=C.UTF-8 HOME="$PREFS" XDG_CONFIG_HOME="$PREFS/.config" \
    ./addon/build/prefs_host - "$LEXICON" "$PREFS/userdata" "$mode" >"$PREFS/$mode.log" 2>&1 || STATUS=1
  grep -v vChewingDebug "$PREFS/$mode.log" || true
done
echo "    偏好設定檔：$(cd "$PREFS" && find . -name '*.plist')"

echo "##### 打字：真的 fcitx5 行程，經 DBus #####"
env -i \
  PATH=/usr/bin:/bin \
  LANG=C.UTF-8 \
  HOME="$SANDBOX/home" \
  XDG_CONFIG_HOME="$SANDBOX/home/.config" \
  XDG_DATA_HOME="$SANDBOX/home/.local/share" \
  XDG_CACHE_HOME="$SANDBOX/home/.cache" \
  XDG_RUNTIME_DIR="$SANDBOX/run" \
  XDG_DATA_DIRS="$PREFIX/share:/usr/share" \
  FCITX_ADDON_DIRS="$PREFIX/lib/fcitx5:/usr/lib/x86_64-linux-gnu/fcitx5" \
  FCITX5_LOG="$SANDBOX/fcitx5.log" \
  dbus-run-session -- python3 "$ROOT/tests/dbus_typing_test.py" "$@" || STATUS=1
exit $STATUS
