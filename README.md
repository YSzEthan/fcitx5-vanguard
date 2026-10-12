# fcitx5-vanguard

Fcitx5 上的注音輸入法外掛，引擎是 [LibVanguard](https://github.com/vChewing/vChewing-LibVanguard)。

An unofficial Fcitx5 addon for typing Traditional Chinese with Bopomofo (Zhuyin), built on the LibVanguard engine. Documentation is in Traditional Chinese.

## 這是什麼、不是什麼

- 這是**非官方**的移植，與 LibVanguard 及其上游專案沒有隸屬關係，也沒有得到上游的背書。
- 這裡遇到的問題請回報到這個專案，**不要拿去找上游**。上游的 README 寫明目前不收外部貢獻。
- 本專案不使用上游產品的名稱。引擎本身沒有修改，以固定的 commit 原樣編譯。
- 還在早期階段，版本 0.1.0。測試以自動化為主（透過 DBus 對真的 fcitx5 行程送按鍵），實機使用的經驗很少。

## 目前做得到的

- 注音打字、選字、送字；完整的原廠辭庫。
- 使用者語彙（打字時選取後按 Enter 加詞）與選字記憶，重啟後還在；檔案格式與 macOS 版相同。
- 按著 Shift 打全形標點、`` ` `` 鍵的符號選單、Tab 輪替候選字。
- 中英混打（引擎的「中英混合輸入回退」，預設關閉）、單獨按 Shift 切換英數模式、Caps Lock 直接打英文。
- 選字視窗直排或橫排、頁碼與碼位、翻頁箭頭。
- 獨立的設定程式，列出引擎的偏好設定（已知在這個版本沒有作用的不顯示；有顯示的也不是每一項都驗證過）。

## 已知的限制

- 只有 x86_64，需要 glibc 2.38 以上（Ubuntu 24.04、Linux Mint 22、近期的 Arch）。
- 選字視窗的字型、顏色、外框由 fcitx5 的佈景決定，沒辦法做成 macOS 版的樣子。
- 引擎的提示文字（例如加詞時的提示）大多顯示不出來：它們的翻譯表不在 fcitx5 行程裡。
- 所有視窗共用同一個組字狀態。
- 簡體模式、磁帶模式、漢字轉換等功能沒有驗證過，或沒有接上。
- fcitx5 預設把左 Shift 當成全域熱鍵，所以切換中英要用右 Shift，或先到 fcitx5 的全域設定把那個熱鍵拿掉。
- 套件約 80MB，因為把 Swift 執行期一起帶著：各發行版的官方套件庫都沒有 Swift 6.4。

## 安裝

目前沒有發佈預先編好的套件，要自己建置（見下一節）。建置後：

| 環境 | 做法 |
|---|---|
| Linux Mint 22／Ubuntu 24.04 | `sudo apt install ./dist/fcitx5-vanguard_0.1.0-1_amd64.deb` |
| Arch | `sudo pacman -U dist/arch/fcitx5-vanguard-0.1.0-1-x86_64.pkg.tar.zst` |
| flatpak 版的 Fcitx5（例如 Steam Deck） | `packaging/flatpak-local/install.sh build`，再 `packaging/flatpak-local/install.sh install` |

裝好之後重新啟動 fcitx5，在 fcitx5 設定的輸入法清單加入「Vanguard 注音」。

flatpak 版那一種做法不需要 `flatpak override`，也不用在主機安裝建置工具：檔案放在 Fcitx5 自己的資料目錄（`~/.var/app/org.fcitx.Fcitx5/data/`），登記檔用絕對路徑指向外掛。移除用 `packaging/flatpak-local/install.sh uninstall`。

## 設定

應用程式選單裡的「Vanguard 注音設定」，或執行 `fcitx5-vanguard-settings`。

- 設定值存在 fcitx5 行程裡的引擎，所以 fcitx5 要在執行中。改動立刻生效並存檔。
- 也能當命令列工具：`--list`、`--get KEY`、`--set KEY=VALUE`。
- 選項的名稱與說明取自 macOS 版的繁體中文翻譯表，用詞與它一致。
- 引擎共有 119 項偏好設定，其中 37 項在這個版本沒有作用（多數是 macOS 專用），不顯示。
- 需要 Python 3、PyGObject 與 GTK 4。

## 建置

需要 Swift 6.4 以上（引擎的要求）、CMake、Ninja、fcitx5 的開發檔、`patchelf`、`zstd`。開發時是在 Ubuntu 24.04 的容器裡進行。

```sh
# 1. 把上游原始碼抓到 vendor/，鎖在固定的 commit
./scripts/fetch-vendor.sh

# 2. 編原廠辭庫（約 80 秒，只需要做一次）
(cd vendor/vChewing-VanguardLexicon && swift run -c release VCDataBuilder vanguardTextMap)

# 3. 編引擎、整理成可搬移的目錄、編外掛、跑全部測試
./tests/run.sh

# 4. 做套件
./packaging/deb/build-deb.sh          # Ubuntu／Mint
./packaging/arch/build-pkg.sh         # 在 Arch 上執行；引擎用第 3 步編好的那一包
```

Arch 的套件是「部分預編」：在 Arch 上只編 C++ 的外掛本體，引擎用 Ubuntu 上編好的二進位檔，因為 Arch 的官方套件庫沒有 Swift。

`.github/workflows/build.yml` 會在每次 push 時做同樣的事，並另外建置 flatpak 擴充。

## 專案結構

| 目錄 | 內容 |
|---|---|
| `engine/` | 把引擎包成 C 介面的 Swift 動態庫（`libVGEngine.so`），介面在 `engine/include/vanguard.h` |
| `addon/` | fcitx5 外掛本體（C++），只透過上面的 C 介面跟引擎溝通 |
| `settings/` | 設定程式（Python 加 GTK 4）與它用的翻譯表 |
| `tests/` | 啟動真的 fcitx5 行程、經 DBus 送按鍵的測試 |
| `packaging/` | deb、Arch、flatpak 的打包腳本與第三方授權聲明 |
| `probe/`、`shim/` | 早期用來驗證「引擎能不能載進不跑 dispatch 主迴圈的行程」的實驗，留作紀錄 |

引擎是 Swift 寫的，內部大量使用主執行緒佇列；fcitx5 跑的是自己的事件迴圈。外掛在每次呼叫引擎之後、以及每 50 毫秒，用 `RunLoop.main.run(mode:before:)` 排空主佇列，引擎才動得起來。不排空的話引擎內部狀態看起來正常，但前端完全收不到組字區，而且不會有任何錯誤訊息。

## 授權

本專案自己的程式碼（`addon/`、`engine/`、`settings/` 的程式、腳本）：**LGPL-3.0-or-later**，全文見 [COPYING.LESSER](COPYING.LESSER) 與 [COPYING](COPYING)。

套件裡另外帶著下列元件，各有自己的授權：

| 元件 | 授權 | 來源 |
|---|---|---|
| LibVanguard 引擎 | LGPL-3.0-or-later，附一份自訂例外條款；其中兩個模組是 MulanPSL-2.0 | <https://github.com/vChewing/vChewing-LibVanguard> |
| 原廠辭庫 | MulanPSL-2.0 | <https://github.com/vChewing/vChewing-VanguardLexicon> |
| 設定程式的翻譯表（`settings/strings/`） | MulanPSL-2.0 | <https://github.com/vChewing/vChewing-macOS> |
| 注音變體資料表 | 衍生自 But Ko 的注音 IVS 字型規格，Apache-2.0 | <https://github.com/ButTaiwan/bpmfvs> |
| Swift 執行期函式庫 | Apache-2.0 WITH Swift-exception；內含 ICU（Unicode 授權）等第三方元件 | <https://www.swift.org>，逐顆對照見 [packaging/third-party/](packaging/third-party/README.md) |

套件安裝後，各份授權全文在 `/usr/share/fcitx5-vanguard/licenses/`（Arch 在 `/usr/share/licenses/fcitx5-vanguard/`）。引擎與辭庫是哪一個 commit 編出來的，記在裡面的 `SOURCES.txt`。

引擎是 LGPL：建置時會另外產生一份對應原始碼的壓縮檔 `fcitx5-vanguard-engine-sources-<版本>.tar.zst`，散布套件時請一併提供。引擎以動態庫的形式安裝在 `<libdir>/fcitx5-vanguard/libVanguard.so`，可以用自己編的版本換掉。
