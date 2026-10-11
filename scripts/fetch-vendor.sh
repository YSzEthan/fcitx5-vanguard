#!/bin/sh
# 把上游原始碼抓到 vendor/ 並鎖在固定的 commit。vendor/ 不進版本庫，本機與 CI 都靠這支腳本還原。
# 要升級上游：改下面的 commit，重跑，再跑測試。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fetch() { # 名稱 網址 commit
  dir="$ROOT/vendor/$1"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$2"
  fi
  if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
    git -C "$dir" fetch -q --depth 1 origin "$3"
    git -C "$dir" checkout -q --detach "$3"
  fi
  echo "$1 @ $(git -C "$dir" rev-parse HEAD)"
}

fetch vChewing-LibVanguard     https://github.com/vChewing/vChewing-LibVanguard     4336d90ec3d17fa24a7ed022fd723e612990752c
fetch vChewing-VanguardLexicon https://github.com/vChewing/vChewing-VanguardLexicon fbe80c03f11dd2ed755ef58c6c33fec94fdbc4fc
