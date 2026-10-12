#!/bin/sh
# 啟動真的 fcitx5 行程，透過 DBus 前端送按鍵驗證；另外不經 fcitx5 直接驗證偏好設定。
#
#   tests/run.sh            在 mint-dev 容器內：整理引擎目錄、編外掛、裝到 addon/prefix，測那一份
#   tests/run.sh --system   測已經裝進系統（/usr）的套件，不編任何東西。用來驗證 deb 與 Arch 套件
#
# 隔離：distrobox 容器跟主機共用 session bus 與 /run/user，主機上有使用者在用的 Fcitx5。
# 所以這裡用 env -i 清掉環境、另開一條私有的 DBus（dbus-run-session）、
# HOME 與 XDG 目錄全部指到沙盒，不設 DISPLAY / WAYLAND_DISPLAY，fcitx5 只啟用需要的外掛。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$1" = "--system" ]; then
  shift
  PREFIX=/usr
  LIBDIR=
  for dir in /usr/lib/x86_64-linux-gnu /usr/lib; do
    [ -e "$dir/fcitx5/vanguard.so" ] && LIBDIR="$dir" && break
  done
  [ -n "$LIBDIR" ] || { echo "系統裡找不到 fcitx5/vanguard.so，套件沒裝好" >&2; exit 1; }
  WORK="${VANGUARD_TEST_WORKDIR:-$(mktemp -d)}"
  # 沒有編譯器的乾淨環境：用 mint-dev 事先編好的那一顆。
  PREFS_HOST="$ROOT/dist/prefs_host"
  ADDON_DIRS=
  DATA_DIRS=
else
  ./packaging/stage-engine.sh | tail -2
  PREFIX="$ROOT/addon/prefix"
  LIBDIR="$PREFIX/lib"
  WORK="$ROOT/addon/build"
  rm -rf "$PREFIX"
  cmake -S addon -B addon/build -G Ninja -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
  cmake --build addon/build 2>&1 | tail -1
  cmake --install addon/build >/dev/null
  # 不寫 rpath，執行時用 LD_LIBRARY_PATH 指到要測的那一份引擎。
  PREFS_HOST="$ROOT/dist/prefs_host"
  cc -O1 -g -Wall -Idist/engine/include -o "$PREFS_HOST" tests/prefs_host.c \
    -Ldist/engine/lib -lVGEngine -Wl,-rpath-link,dist/engine/lib
  ADDON_DIRS="$LIBDIR/fcitx5:/usr/lib/x86_64-linux-gnu/fcitx5"
  DATA_DIRS="$PREFIX/share:/usr/share"
fi

ENGINE_LIBDIR="$LIBDIR/fcitx5-vanguard"
LEXICON="$PREFIX/share/fcitx5-vanguard/vanguardTextMap.txtMap"
echo "受測安裝：外掛 $LIBDIR/fcitx5/vanguard.so，引擎 $ENGINE_LIBDIR，fcitx5 $(fcitx5 --version 2>/dev/null)"

SANDBOX="$WORK/sandbox"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/home/.config/fcitx5" "$SANDBOX/run"
chmod 700 "$SANDBOX/run"
cp tests/profile "$SANDBOX/home/.config/fcitx5/profile"

echo "##### 偏好設定：不經 fcitx5，兩個行程 #####"
PREFS="$WORK/prefs"
rm -rf "$PREFS" && mkdir -p "$PREFS"
STATUS=0
for mode in set check; do
  echo "--- $mode"
  env -i PATH=/usr/bin:/bin LANG=C.UTF-8 HOME="$PREFS" XDG_CONFIG_HOME="$PREFS/.config" \
    LD_LIBRARY_PATH="$ENGINE_LIBDIR" \
    "$PREFS_HOST" - "$LEXICON" "$PREFS/userdata" "$mode" >"$PREFS/$mode.log" 2>&1 || STATUS=1
  grep -v vChewingDebug "$PREFS/$mode.log" || true
done
echo "    偏好設定檔：$(cd "$PREFS" && find . -name '*.plist')"

echo "##### 打字：真的 fcitx5 行程，經 DBus #####"
# 有 GTK 4 與它的 broadway 後端時，順便把設定程式的視窗建起來檢查（不需要螢幕）。
GUI=
if command -v gtk4-broadwayd >/dev/null && python3 -c 'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null; then
  GUI=1
  mkdir -p "$WORK/screenshots"
fi
env -i \
  PATH=/usr/bin:/bin \
  LANG=C.UTF-8 \
  HOME="$SANDBOX/home" \
  XDG_CONFIG_HOME="$SANDBOX/home/.config" \
  XDG_DATA_HOME="$SANDBOX/home/.local/share" \
  XDG_CACHE_HOME="$SANDBOX/home/.cache" \
  XDG_RUNTIME_DIR="$SANDBOX/run" \
  ${DATA_DIRS:+XDG_DATA_DIRS="$DATA_DIRS"} \
  ${ADDON_DIRS:+FCITX_ADDON_DIRS="$ADDON_DIRS"} \
  FCITX5_LOG="$SANDBOX/fcitx5.log" \
  ${GUI:+VANGUARD_TEST_GUI=1} \
  ${GUI:+VANGUARD_TEST_SCREENSHOTS="$WORK/screenshots/settings"} \
  dbus-run-session -- python3 "$ROOT/tests/dbus_typing_test.py" "$@" || STATUS=1
exit $STATUS
