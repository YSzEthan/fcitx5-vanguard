# fcitx5-vanguard

在 Fcitx5 上打注音的外掛。引擎用的是 [LibVanguard](https://github.com/vChewing/vChewing-LibVanguard)，我只做了把它接到 Fcitx5 的那一層。

An unofficial Fcitx5 addon for typing Traditional Chinese with Bopomofo (Zhuyin), built on the LibVanguard engine. Documentation is in Traditional Chinese.

## 先講清楚

這是非官方的移植。我跟 LibVanguard 的上游沒有任何關係，這個專案也沒有得到上游的背書。

所以這裡出的問題請回報到這裡，不要拿去問上游。上游的 README 寫明了不收外部貢獻，去那邊開 issue 只會給人添麻煩。

引擎本身我沒有改，鎖在固定的 commit 原樣編譯。本專案也不使用上游產品的名稱。

目前是 0.1.0。測試幾乎都是自動化的：啟動真的 fcitx5 行程，透過 DBus 送按鍵再讀回結果。真的坐在螢幕前打字的時間很少，請當成早期版本看待。

## 能做什麼

基本的注音打字、選字、送字都有，辭庫是完整的原廠辭庫。

打字時選取一段文字按 Enter 可以加詞。加過的詞和選字的習慣會存檔，重啟後還在，檔案格式跟 macOS 版一樣，兩邊可以互相複製。

其他有接上的：

- 按著 Shift 打全形標點，`` ` `` 鍵叫出符號選單，Tab 輪替候選字。
- 關聯詞語，用 Shift+Enter 送出就會列出來。
- 磁帶模式，吃 CIN 表格檔。套件不附任何表格，要自己準備。
- 數字小鍵盤。
- 中英混打，也就是引擎的「中英混合輸入回退」，預設關閉。
- 單獨按一下 Shift 切換英數模式；Caps Lock 亮著時直接打英文。
- 選字視窗可以直排或橫排，會顯示頁碼和碼位。
- 一個獨立的設定程式。

## 做不到或還沒做的

只有 x86_64，而且要 glibc 2.38 以上。Ubuntu 24.04、Linux Mint 22 和近期的 Arch 可以，更舊的系統裝不了。

選字視窗長什麼樣子是 fcitx5 的佈景決定的。字型、顏色、外框我都控制不了，所以做不成 macOS 版那個樣子。

引擎的提示文字大多顯示不出來，例如加詞時告訴你成功與否的那一行。它們的翻譯表在 macOS 版的 app 裡，fcitx5 行程讀不到。

fcitx5 預設把左 Shift 設成全域熱鍵。切換中英請用右 Shift，或者到 fcitx5 的全域設定把那個熱鍵拿掉。

其他零碎的：

- 所有視窗共用同一個組字狀態。
- 簡體模式和漢字轉換沒有驗證過，後者根本沒接上。
- 套件大約 80MB。各發行版的官方套件庫都沒有 Swift 6.4，只好把 Swift 執行期整套帶著，光是其中的 ICU 資料就佔了一半。

## 安裝

還沒有發佈編好的套件，要自己建置，步驟在下一節。建置完之後：

| 環境 | 做法 |
|---|---|
| Linux Mint 22／Ubuntu 24.04 | `sudo apt install ./dist/fcitx5-vanguard_0.1.0-1_amd64.deb` |
| Arch | `sudo pacman -U dist/arch/fcitx5-vanguard-0.1.0-1-x86_64.pkg.tar.zst` |
| flatpak 版的 Fcitx5（例如 Steam Deck） | `packaging/flatpak-local/install.sh build`，再 `packaging/flatpak-local/install.sh install` |

裝好後重新啟動 fcitx5，到 fcitx5 設定的輸入法清單把「Vanguard 注音」加進去。

flatpak 那一種值得多說兩句。flatpak 版的 Fcitx5 在沙盒裡，看不到裝進 `/usr` 的外掛，正規做法是做成 flatpak 擴充。這裡走了另一條路：把檔案放進 Fcitx5 自己的資料目錄 `~/.var/app/org.fcitx.Fcitx5/data/`，登記檔用絕對路徑指向外掛。不需要 `flatpak override`，主機也不用裝任何建置工具。要移除就跑 `packaging/flatpak-local/install.sh uninstall`。

## 設定

從應用程式選單開「Vanguard 注音設定」，或直接執行 `fcitx5-vanguard-settings`。需要 Python 3、PyGObject 和 GTK 4。

設定值存在 fcitx5 行程裡的引擎，所以 fcitx5 沒在跑的時候改不了。改了立刻生效，不用按套用。

選項的名稱和說明直接用 macOS 版的繁體中文翻譯表，用詞跟它一樣。

引擎有 119 項偏好設定，這裡只顯示 69 項。沒顯示的 50 項在這個版本沒有作用：26 項是 macOS 專用的，管的是它自己畫的視窗和音效；另外 24 項是這邊沒接上的，例如熱鍵。顯示的 69 項裡，我實測確認改了有差別的是 50 項，剩下 19 項引擎確實有讀，只是要特定條件才看得出效果，我沒辦法保證。

不想開視窗的話也能當命令列用：`--list`、`--get KEY`、`--set KEY=VALUE`。

## 建置

需要 Swift 6.4 以上，這是引擎的要求。另外要 CMake、Ninja、fcitx5 的開發檔、`patchelf` 和 `zstd`。我是在 Ubuntu 24.04 的容器裡開發的。

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

Arch 的套件只有一半是在 Arch 上編的。C++ 的外掛本體在 Arch 編，引擎則沿用 Ubuntu 上編好的二進位檔，因為 Arch 的官方套件庫沒有 Swift。

`.github/workflows/build.yml` 每次 push 都會跑一遍上面的流程，另外再建一份 flatpak 擴充。

## 專案結構

| 目錄 | 內容 |
|---|---|
| `engine/` | 把引擎包成 C 介面的 Swift 動態庫（`libVGEngine.so`），介面在 `engine/include/vanguard.h` |
| `addon/` | fcitx5 外掛本體（C++），只透過上面的 C 介面跟引擎溝通 |
| `settings/` | 設定程式與它用的翻譯表 |
| `tests/` | 啟動真的 fcitx5 行程、經 DBus 送按鍵的測試 |
| `packaging/` | deb、Arch、flatpak 的打包腳本與第三方授權聲明 |
| `probe/`、`shim/` | 早期的實驗，用來確認引擎能不能載進不跑 dispatch 主迴圈的行程。留作紀錄 |

有一件事如果你想改這份程式碼，一定要先知道。引擎是 Swift 寫的，內部大量把工作排到主執行緒佇列，而 fcitx5 跑的是自己的事件迴圈，沒有人去排空那個佇列。外掛的做法是每次呼叫引擎之後，以及每 50 毫秒，各呼叫一次 `RunLoop.main.run(mode:before:)`。

少了這一步，引擎內部的狀態看起來完全正常，Enter 也送得出字，但前端收不到組字區，而且沒有任何錯誤訊息，很難查。

## 授權

我自己寫的部分是 LGPL-3.0-or-later，包括 `addon/`、`engine/`、`settings/` 的程式和各個腳本。全文在 [COPYING.LESSER](COPYING.LESSER) 與 [COPYING](COPYING)。

套件裡帶著的其他東西各有各的授權：

| 元件 | 授權 | 來源 |
|---|---|---|
| LibVanguard 引擎 | LGPL-3.0-or-later，附一份自訂例外條款；其中兩個模組是 MulanPSL-2.0 | <https://github.com/vChewing/vChewing-LibVanguard> |
| 原廠辭庫、關聯詞語範本 | MulanPSL-2.0 | <https://github.com/vChewing/vChewing-VanguardLexicon> |
| 設定程式的翻譯表（`settings/strings/`） | MulanPSL-2.0 | <https://github.com/vChewing/vChewing-macOS> |
| 注音變體資料表 | 衍生自 But Ko 的注音 IVS 字型規格，Apache-2.0 | <https://github.com/ButTaiwan/bpmfvs> |
| Swift 執行期函式庫 | Apache-2.0 WITH Swift-exception；內含 ICU（Unicode 授權）等第三方元件 | <https://www.swift.org>，逐顆對照見 [packaging/third-party/](packaging/third-party/README.md) |

套件裝好後，授權全文都在 `/usr/share/fcitx5-vanguard/licenses/`，Arch 則是 `/usr/share/licenses/fcitx5-vanguard/`。裡面的 `SOURCES.txt` 記著引擎和辭庫是哪一個 commit 編出來的。

引擎是 LGPL，散布套件的人有兩件事要做。建置時會多產生一份 `fcitx5-vanguard-engine-sources-<版本>.tar.zst`，那是對應的原始碼，請跟套件一起提供。另外引擎是以動態庫安裝在 `<libdir>/fcitx5-vanguard/libVanguard.so`，使用者想換成自己編的版本可以直接換。
