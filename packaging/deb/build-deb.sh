#!/bin/sh
# 在 mint-dev 容器內執行（Ubuntu 24.04，等同 Linux Mint 22 的底層）：做出 deb。
# 前提：dist/engine 已經由 packaging/stage-engine.sh 產生。
# 產物：dist/fcitx5-vanguard_<版本>-1_amd64.deb
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^project(fcitx5-vanguard VERSION \([0-9.]*\).*/\1/p' "$ROOT/addon/CMakeLists.txt")"
REVISION=1
ARCH="$(dpkg --print-architecture)"
WORK="$ROOT/dist/deb"
PKG="$WORK/debian/fcitx5-vanguard"
DEB="$ROOT/dist/fcitx5-vanguard_${VERSION}-${REVISION}_${ARCH}.deb"
# 容器的家目錄是隔離的，讀不到主機的 git 身分，所以取最近一次 commit 的作者。
MAINTAINER="${VANGUARD_MAINTAINER:-$(git -C "$ROOT" log -1 --format='%an <%ae>')}"

rm -rf "$WORK"
mkdir -p "$PKG/DEBIAN"
cmake -S "$ROOT/addon" -B "$WORK/build" -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
  -DVANGUARD_ENGINE_BUNDLE="$ROOT/dist/engine" >/dev/null
cmake --build "$WORK/build" 2>&1 | tail -1
DESTDIR="$PKG" cmake --install "$WORK/build" --strip >/dev/null

DOC="$PKG/usr/share/doc/fcitx5-vanguard"
mkdir -p "$DOC"
sed "s|@LICENSES@|/usr/share/fcitx5-vanguard/licenses|" "$ROOT/packaging/deb/copyright.in" > "$DOC/copyright"

# 相依套件由 dpkg-shlibdeps 從外掛實際連到的系統函式庫算出來。
# 引擎與 Swift 執行期是包在套件裡的私有函式庫，沒有 shlibs 資訊，所以要 --ignore-missing-info。
cat > "$WORK/debian/control" <<CTL
Source: fcitx5-vanguard

Package: fcitx5-vanguard
Architecture: $ARCH
CTL
SHLIBS="$(cd "$WORK" && dpkg-shlibdeps -O --ignore-missing-info \
  -l"$PKG/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/fcitx5-vanguard" \
  $(find debian/fcitx5-vanguard/usr/lib -name '*.so' -printf '-e%p ') 2>"$WORK/shlibdeps.log" | sed -n 's/^shlibs:Depends=//p')"
[ -n "$SHLIBS" ] || { cat "$WORK/shlibdeps.log" >&2; exit 1; }

cat > "$PKG/DEBIAN/control" <<CTL
Package: fcitx5-vanguard
Version: ${VERSION}-${REVISION}
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $(du -sk "$PKG/usr" | cut -f1)
Depends: fcitx5 (>= 5.1), $SHLIBS
Section: utils
Priority: optional
Description: Bopomofo (Zhuyin) input method for Fcitx5 built on the LibVanguard engine
 A Fcitx5 input method addon for typing Traditional Chinese with Bopomofo.
 It loads the LibVanguard engine in-process through a small C interface.
 .
 The package carries its own copy of the Swift runtime libraries in a
 private directory, because the distribution does not provide Swift 6.4.
CTL
(cd "$PKG" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums)
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG/usr" -type f -exec chmod 644 {} +

dpkg-deb --root-owner-group --build "$PKG" "$DEB" >/dev/null
echo "deb：$DEB（$(du -h "$DEB" | cut -f1)）"
dpkg-deb --info "$DEB" | sed -n '/Package:/,$p'
