#!/bin/sh
# 在 mint-dev 容器內執行：把引擎編成 release，連同它需要的 Swift 執行期函式庫、辭庫、
# 授權檔整理成一個可搬移的目錄（預設 dist/engine），再壓成 tarball。
#
# 為什麼要這一步：`swift build` 的產物 RUNPATH 寫死本機工具鏈的絕對路徑，換一台機器就載不起來；
# 而 Arch 與 Ubuntu／Mint 的官方套件庫都沒有 Swift 6.4 的執行期可以依賴，所以整套帶著走。
# 這個目錄只依賴 glibc（建置機是 Ubuntu 24.04，glibc 2.39），外掛的 CMake 直接拿它來連結與安裝。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^project(fcitx5-vanguard VERSION \([0-9.]*\).*/\1/p' "$ROOT/addon/CMakeLists.txt")"
OUT="${1:-$ROOT/dist/engine}"
LIBVANGUARD="$ROOT/vendor/vChewing-LibVanguard"
LEXICON_REPO="$ROOT/vendor/vChewing-VanguardLexicon"
LEXICON="$LEXICON_REPO/Build/Release/vanguard-textmap/VanguardFactoryDict4Typing.txtMap"

[ -f "$LEXICON" ] || { echo "找不到辭庫 $LEXICON，先在 $LEXICON_REPO 跑 swift run -c release VCDataBuilder vanguardTextMap" >&2; exit 1; }

(cd "$ROOT/engine" && swift build -c release 2>&1 | tail -1)
BUILD="$ROOT/engine/.build/release"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/share" "$OUT/include" "$OUT/licenses"

cp "$BUILD/libVGEngine.so" "$BUILD/libVanguard.so" "$OUT/lib/"
# Swift 執行期：取引擎實際連到的那些（含間接依賴），也就是跟 libswiftCore.so 同目錄的全部。
RUNTIME_DIR="$(dirname "$(ldd "$BUILD/libVGEngine.so" | awk '$1 == "libswiftCore.so" { print $3 }')")"
ldd "$BUILD/libVGEngine.so" | awk -v dir="$RUNTIME_DIR/" 'index($3, dir) == 1 { print $3 }' | while read -r lib; do
  cp "$lib" "$OUT/lib/"
done
# 去掉除錯資訊與非動態符號（順序：先 strip 再 patchelf，反過來有弄壞檔案的前例）。
# 只在同一個目錄裡互相找，不留任何建置機的路徑。
for lib in "$OUT"/lib/*.so; do
  strip --strip-unneeded "$lib"
  patchelf --set-rpath '$ORIGIN' "$lib"
done

cp "$LEXICON" "$OUT/share/vanguardTextMap.txtMap"
cp "$LIBVANGUARD/Sources/BPMFVS/Resources/phonic_table_Z.txt" "$OUT/share/"
cp "$ROOT/engine/include/vanguard.h" "$OUT/include/"

mkdir -p "$OUT/licenses/LibVanguard" "$OUT/licenses/VanguardLexicon" "$OUT/licenses/swift" "$OUT/licenses/fcitx5-vanguard"
cp "$ROOT/COPYING" "$ROOT/COPYING.LESSER" "$OUT/licenses/fcitx5-vanguard/"
cp "$LIBVANGUARD/COPYING" "$OUT/licenses/LibVanguard/"
cp -r "$LIBVANGUARD/LICENSES" "$OUT/licenses/LibVanguard/"
cp "$LEXICON_REPO"/LICENSE*.txt "$OUT/licenses/VanguardLexicon/"
cp "$(dirname "$RUNTIME_DIR")/../../share/swift/LICENSE.txt" "$OUT/licenses/swift/"
# Swift 執行期各顆函式庫的來源對照，以及工具鏈沒有附的第三方聲明（swift-foundation 的 NOTICE、ICU 的授權）。
cp "$ROOT"/packaging/third-party/* "$OUT/licenses/swift/"
cat > "$OUT/licenses/SOURCES.txt" <<SRC
這個目錄裡的二進位檔由下列原始碼編出，未經修改：

libVanguard.so（LGPL-3.0-or-later，各模組另有例外條款，見 LibVanguard/）
  https://github.com/vChewing/vChewing-LibVanguard
  commit $(git -C "$LIBVANGUARD" rev-parse HEAD)

vanguardTextMap.txtMap（MulanPSL-2.0）
  https://github.com/vChewing/vChewing-VanguardLexicon
  commit $(git -C "$LEXICON_REPO" rev-parse HEAD)
  指令：swift run -c release VCDataBuilder vanguardTextMap

phonic_table_Z.txt：取自 LibVanguard 的 Sources/BPMFVS/Resources/，授權見 LibVanguard/LICENSES/。

libVGEngine.so：本專案 engine/ 目錄，把引擎包成 C 介面（LGPL-3.0-or-later，見 fcitx5-vanguard/）。

其餘 lib*.so：Swift 執行期函式庫（Apache-2.0 WITH Swift-exception），
  $(swiftc --version 2>/dev/null | head -1)
  各顆的來源專案與第三方聲明見 swift/README.md。

LGPL 要求能取得對應的原始碼：上面兩個 commit 的完整原始碼，連同 libVGEngine.so 的原始碼，
打包成 fcitx5-vanguard-engine-sources-$VERSION.tar.zst，跟這個套件放在同一個地方發佈。
SRC

# 對應原始碼的壓縮檔：不依賴上游 repo 還在不在、歷史有沒有被改寫。
SOURCES_TARBALL="$ROOT/dist/fcitx5-vanguard-engine-sources-$VERSION.tar.zst"
SOURCES_DIR="$(mktemp -d)"
trap 'rm -rf "$SOURCES_DIR"' EXIT
STEM="fcitx5-vanguard-engine-sources-$VERSION"
mkdir -p "$SOURCES_DIR/$STEM"
git -C "$LIBVANGUARD" archive --prefix="vChewing-LibVanguard-$(git -C "$LIBVANGUARD" rev-parse --short HEAD)/" HEAD | tar -x -C "$SOURCES_DIR/$STEM"
git -C "$LEXICON_REPO" archive --prefix="vChewing-VanguardLexicon-$(git -C "$LEXICON_REPO" rev-parse --short HEAD)/" HEAD | tar -x -C "$SOURCES_DIR/$STEM"
mkdir -p "$SOURCES_DIR/$STEM/fcitx5-vanguard"
cp -r "$ROOT/engine/Package.swift" "$ROOT/engine/Sources" "$ROOT/engine/include" "$ROOT/COPYING" "$ROOT/COPYING.LESSER" \
  "$SOURCES_DIR/$STEM/fcitx5-vanguard/"
cp "$OUT/licenses/SOURCES.txt" "$SOURCES_DIR/$STEM/"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$SOURCES_DIR" -cf - "$STEM" | zstd -q -19 -T0 -f -o "$SOURCES_TARBALL"

TARBALL="$ROOT/dist/fcitx5-vanguard-engine-$VERSION-x86_64.tar.zst"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$(dirname "$OUT")" -cf - "$(basename "$OUT")" | zstd -q -19 -T0 -f -o "$TARBALL"
echo "引擎目錄：$OUT（$(du -sh "$OUT" | cut -f1)）"
echo "tarball：$TARBALL（$(du -h "$TARBALL" | cut -f1)）"
echo "原始碼：$SOURCES_TARBALL（$(du -h "$SOURCES_TARBALL" | cut -f1)）"
