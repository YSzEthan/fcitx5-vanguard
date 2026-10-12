#!/bin/sh
# 在 arch-dev 容器內執行：用 packaging/arch/PKGBUILD 做出 Arch 套件。
# 前提：dist/fcitx5-vanguard-engine-<版本>-x86_64.tar.zst 已經由 mint-dev 裡的
# packaging/stage-engine.sh 產生（Arch 這邊不需要 Swift）。
# 產物：dist/arch/fcitx5-vanguard-<版本>-1-x86_64.pkg.tar.zst
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^pkgver=//p' "$ROOT/packaging/arch/PKGBUILD")"
ENGINE="fcitx5-vanguard-engine-$VERSION-x86_64.tar.zst"
SOURCE="fcitx5-vanguard-$VERSION.tar.gz"
WORK="$ROOT/dist/arch"

[ -f "$ROOT/dist/$ENGINE" ] || { echo "找不到 dist/$ENGINE，先在 mint-dev 跑 packaging/stage-engine.sh" >&2; exit 1; }
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ROOT/dist/$ENGINE" "$WORK/"
# 外掛的原始碼（addon/ 底下三樣）與設定程式（settings/）。
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-01-01 00:00:00' \
  --transform "s|^|fcitx5-vanguard-$VERSION/|" -C "$ROOT" \
  -czf "$WORK/$SOURCE" addon/CMakeLists.txt addon/src addon/data \
  settings/fcitx5-vanguard-settings settings/strings settings/org.fcitx.Fcitx5.Addon.Vanguard.Settings.desktop

SUM_SOURCE="$(sha256sum "$WORK/$SOURCE" | cut -d' ' -f1)"
SUM_ENGINE="$(sha256sum "$WORK/$ENGINE" | cut -d' ' -f1)"
awk -v a="$SUM_SOURCE" -v b="$SUM_ENGINE" '
  /^sha256sums=\(.SKIP.$/ { print "sha256sums=(\x27" a "\x27"; getline; print "            \x27" b "\x27)"; next }
  { print }' "$ROOT/packaging/arch/PKGBUILD" > "$WORK/PKGBUILD"

cd "$WORK"
makepkg --force --syncdeps --noconfirm "$@"
ls -la "$WORK"/*.pkg.tar.zst
