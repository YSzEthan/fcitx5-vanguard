# 介面文字的翻譯表

`zh-Hant.strings` 取自 <https://github.com/vChewing/vChewing-macOS>，
路徑 `Sources/vChewingIME_macOS/Resources/zh-Hant.lproj/Localizable.strings`，
commit `029323785234a4b7076a4d2980b65c4be3343f38`，內容未經修改。

授權：MulanPSL-2.0，© 2021 and onwards The vChewing Project。全文見同目錄的 `LICENSE.txt`。

用途：引擎（LibVanguard）每一項偏好設定的標題、說明與選項名稱，在引擎裡只有翻譯表的 key
（`i18n:UserDef.…`），實際的文字在 macOS 版的這個檔案裡。設定程式讀這個檔案，
所以選項的用詞跟 macOS 版一致。

設定程式顯示時會把文字裡提到原產品名稱的地方換成「本輸入法」：本專案不使用原專案的名稱。
檔案本身不動。

這份翻譯表的版本比 `vendor/` 鎖定的引擎版本新或舊都有可能；引擎要的 key 目前全部找得到
（`settings/fcitx5-vanguard-settings --check` 會檢查）。
