# 套件裡帶著的 Swift 執行期：各顆函式庫的來源與授權

套件把引擎需要的 Swift 執行期函式庫一起帶著（裝在 `<libdir>/fcitx5-vanguard/`），
因為 Arch 與 Ubuntu／Mint 的官方套件庫都沒有 Swift 6.4。這些檔案取自 swift.org 發佈的
Swift 6.4.0 工具鏈（Ubuntu 24.04 版），沒有修改，只做過 `strip` 與改寫 RUNPATH。

| 檔案 | 來自哪個專案 | 授權 |
|---|---|---|
| `libswiftCore.so`、`libswift_Concurrency.so`、`libswiftObservation.so`、`libswiftSynchronization.so`、`libswiftGlibc.so`、`libswift_Builtin_float.so` | [swiftlang/swift](https://github.com/swiftlang/swift) | Apache-2.0 WITH Swift-exception |
| `libswift_StringProcessing.so`、`libswift_RegexParser.so` | [swiftlang/swift-experimental-string-processing](https://github.com/swiftlang/swift-experimental-string-processing) | Apache-2.0 WITH Swift-exception |
| `libdispatch.so`、`libswiftDispatch.so`、`libBlocksRuntime.so` | [swiftlang/swift-corelibs-libdispatch](https://github.com/swiftlang/swift-corelibs-libdispatch) | Apache-2.0 WITH Swift-exception |
| `libFoundation.so` | [swiftlang/swift-corelibs-foundation](https://github.com/swiftlang/swift-corelibs-foundation) | Apache-2.0 WITH Swift-exception |
| `libFoundationEssentials.so`、`libFoundationInternationalization.so` | [swiftlang/swift-foundation](https://github.com/swiftlang/swift-foundation) | Apache-2.0 WITH Swift-exception；內含的第三方程式碼見 `swift-foundation-NOTICE.txt` |
| `lib_FoundationICU.so` | [swiftlang/swift-foundation-icu](https://github.com/swiftlang/swift-foundation-icu)，內容是 ICU4C | 包裝層 Apache-2.0 WITH Swift-exception；ICU 本身是 Unicode 授權，見 `ICU-LICENSE.txt` |

## 這個目錄裡的檔案

- `LICENSE.txt`（打包時由工具鏈複製進來，不在版本庫裡）：Apache-2.0 全文與 Swift 的執行期例外條款。
  上表各專案的授權檔內容都是這一份，逐一比對過。
- `swift-foundation-NOTICE.txt`：swift-foundation 的 `NOTICE.txt`，列出它內含的第三方程式碼與各自的授權。
  Apache-2.0 第 4(d) 條要求散布時一併附上。
- `ICU-LICENSE.txt`：ICU 的授權全文（Unicode 授權，以及 ICU 內含的第三方元件的授權）。

## 版本上的落差，照實記錄

- 上表各專案沒有 `swift-6.4-RELEASE` 這個 tag 可以對，`swift-foundation-NOTICE.txt` 取自
  `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-10-08-a`（swift-foundation commit `39ea278`），
  是離 6.4.0 最近的公開 tag，不保證跟 6.4.0 逐字相同。
- swift-foundation-icu 的 repo 裡沒有單獨的 ICU 授權檔。`ICU-LICENSE.txt` 取自 Arch Linux
  的 `icu` 76.1 套件（`/usr/share/licenses/icu/LICENSE`）。Swift 內含的 ICU 版本跟它不一定相同，
  授權條款是同一份，但著作權年份與第三方元件清單可能有出入。
