#!/bin/sh
# 在主機上執行：用 flatpak 版 Fcitx5 的沙盒跑同一套 DBus 打字測試。
# 前提：packaging/flatpak-local/install.sh build 跑過，且檔案已經複製到
#       ~/.var/app/org.fcitx.Fcitx5/data/fcitx5-vanguard（辭庫路徑編在外掛裡，位置固定）。
#
# 這會另外啟動一個 Fcitx5 沙盒實例，跟使用者正在用的那個互不干擾：
#   - 私有的 DBus（dbus-run-session），不會去搶正在用的 org.fcitx.Fcitx5 名稱
#   - 關掉 wayland／x11 socket，不會接到螢幕上
#   - 執行 flatpak 時把 HOME 換成 dist/flatpak-test/home，所以沙盒用的是那底下全新的
#     .var/app/org.fcitx.Fcitx5，不讀也不寫真正的 Fcitx5 設定。
#     （注意：flatpak 會無視 --env=XDG_CONFIG_HOME 這類設定，一律用 $HOME/.var/app/<應用程式>；
#       第一次測試就是這樣誤用了真正的設定目錄，見 STATUS.md。只有換 HOME 才隔離得了。）
#   - 啟動指令就是沙盒裡原本的 /app/bin/fcitx5，外掛靠登記檔裡的絕對路徑被找到
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=org.fcitx.Fcitx5
T="$ROOT/dist/flatpak-test"
[ -e "$HOME/.var/app/$APP/data/fcitx5-vanguard/lib/fcitx5/vanguard.so" ] || { echo "外掛還沒放進 Fcitx5 的資料目錄" >&2; exit 1; }

REAL_PREFIX="$HOME/.var/app/$APP/data/fcitx5-vanguard"
rm -rf "$T"
FAKE_HOME="$T/home"
export XDG_CONFIG_HOME="$FAKE_HOME/.var/app/$APP/config" XDG_DATA_HOME="$FAKE_HOME/.var/app/$APP/data"
mkdir -p "$XDG_CONFIG_HOME/fcitx5" "$XDG_DATA_HOME"
cp "$ROOT/tests/profile" "$XDG_CONFIG_HOME/fcitx5/profile"
"$ROOT/packaging/flatpak-local/install.sh" write-conf "$XDG_DATA_HOME"

export FCITX5_LOG="$T/fcitx5.log"
# 外掛裝在真正的家目錄底下（路徑編在外掛裡），換了 HOME 之後沙盒看不到，所以唯讀掛進去。
export VANGUARD_FCITX5_CMD="env HOME=$FAKE_HOME flatpak run --nosocket=wayland --nosocket=x11 --nosocket=fallback-x11 --nosocket=inherit-wayland-socket --filesystem=$REAL_PREFIX:ro --command=fcitx5 $APP"
unset DISPLAY WAYLAND_DISPLAY
echo "受測：flatpak $APP $(flatpak info $APP | sed -n 's/^ *Version: //p')，外掛 $REAL_PREFIX"
exec dbus-run-session -- python3 "$ROOT/tests/dbus_typing_test.py" "$@"
