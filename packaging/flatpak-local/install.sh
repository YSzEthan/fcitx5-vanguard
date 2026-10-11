#!/bin/sh
# 在主機上執行：不做 flatpak 擴充，直接把外掛放進 flatpak 版 Fcitx5 自己的資料目錄。
#
#   packaging/flatpak-local/install.sh build      編出要放的檔案（進 mint-dev 容器編），不動 Fcitx5
#   packaging/flatpak-local/install.sh install    把檔案放進 Fcitx5 的資料目錄並登記外掛
#   packaging/flatpak-local/install.sh uninstall  全部移除（使用者語彙與選字記憶保留）
#
# 原理：flatpak 版 Fcitx5 的沙盒看不到主機的 /usr，啟動腳本又把 FCITX_ADDON_DIRS 寫死，
# 但它讀得到自己的資料目錄 ~/.var/app/org.fcitx.Fcitx5/data，而且 fcitx5 會從
# <資料目錄>/fcitx5/addon、inputmethod 讀外掛登記檔，登記檔的 Library 可以寫絕對路徑。
# 所以不需要 flatpak override、不需要改啟動方式，也不需要安裝任何建置工具到主機。
# 外掛本體是在 Ubuntu 24.04（fcitx5 5.1.7）編的，跟 flatpak 裡的 fcitx5 5.1.23 同一個 soname。
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=org.fcitx.Fcitx5
DATA="${VANGUARD_FLATPAK_DATA:-$HOME/.var/app/$APP/data}"
PREFIX="$HOME/.var/app/$APP/data/fcitx5-vanguard"   # 辭庫路徑會編進外掛，所以這個位置是固定的
STAGE="$ROOT/dist/flatpak-local"

write_conf() { # $1 = 資料目錄（裡面有 fcitx5/）
  mkdir -p "$1/fcitx5/addon" "$1/fcitx5/inputmethod"
  sed "s|^Library=.*|Library=$PREFIX/lib/fcitx5/vanguard|" "$ROOT/addon/data/vanguard-addon.conf" \
    > "$1/fcitx5/addon/vanguard.conf"
  cp "$ROOT/addon/data/vanguard-im.conf" "$1/fcitx5/inputmethod/vanguard.conf"
}

case "$1" in
  build)
    rm -rf "$STAGE"
    "$ROOT/scripts/in-container.sh" "
      set -e
      ./packaging/stage-engine.sh | tail -2
      cmake -S addon -B '$STAGE/build' -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX='$PREFIX' -DCMAKE_INSTALL_LIBDIR=lib >/dev/null
      cmake --build '$STAGE/build' | tail -1
      DESTDIR='$STAGE/root' cmake --install '$STAGE/build' --strip >/dev/null"
    echo "已編好：$STAGE/root$PREFIX"
    ;;
  install)
    [ -d "$STAGE/root$PREFIX" ] || { echo "先跑 $0 build" >&2; exit 1; }
    rm -rf "$PREFIX"
    cp -r "$STAGE/root$PREFIX" "$PREFIX"
    # 登記檔改放在 fcitx5 的使用者資料目錄，前綴裡那兩份用不到。
    rm -rf "$PREFIX/share/fcitx5"
    write_conf "$DATA"
    echo "已安裝到 $PREFIX"
    echo "登記檔：$DATA/fcitx5/addon/vanguard.conf、$DATA/fcitx5/inputmethod/vanguard.conf"
    echo "接著重新啟動 Fcitx5，再到 Fcitx5 設定把「Vanguard 注音」加進輸入法清單。"
    ;;
  uninstall)
    rm -rf "$PREFIX"
    rm -f "$DATA/fcitx5/addon/vanguard.conf" "$DATA/fcitx5/inputmethod/vanguard.conf"
    rmdir "$DATA/fcitx5/addon" "$DATA/fcitx5/inputmethod" 2>/dev/null || true
    echo "已移除。使用者語彙與選字記憶還在 $DATA/fcitx5/vanguard，偏好設定在 $HOME/.var/app/$APP/config/fcitx5.plist。"
    echo "如果已經把輸入法加進清單，請到 Fcitx5 設定把它移掉，再重新啟動 Fcitx5。"
    ;;
  write-conf)
    write_conf "$2"
    ;;
  *)
    sed -n '2,7p' "$0"; exit 2
    ;;
esac
