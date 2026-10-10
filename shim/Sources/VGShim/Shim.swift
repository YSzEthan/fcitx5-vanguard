import Foundation
import LexiconAssembly
import LibVanguard
import Shared
import SwiftExtension
import Synchronization

// MARK: - 前端替身

/// 代替 fcitx5 前端接收引擎輸出。只記錄，不做任何 UI。
final class ShimClientProxy: NSObject, SessionClientProxy {
  var committedText = ""
  var commitCalls: Int32 = 0
  var markedText = ""
  var markedCalls: Int32 = 0

  func hasClient() -> Bool { true }

  func clientTextInsertion(with text: String, replacementRange _: NSRange) {
    committedText += text
    commitCalls += 1
  }

  func clientMarkedTextSetup(
    with text: NSAttributedString,
    selectionRange _: NSRange,
    replacementRange _: NSRange
  ) {
    markedText = text.string
    markedCalls += 1
  }

  func clientBundleIdentifier() -> String? { "org.fcitx5-vanguard.shim-host" }
  func clientSelectMode(withModeIdentifier _: String) {}
  func clientOverrideKeyboard(withName _: String) {}

  func clientAttributesForCharacterIndex(
    atU16Pos _: UInt,
    lineHeightRectangle _: UnsafeMutablePointer<CGRect>
  )
    -> [AnyHashable: Any]? { nil }

  func clientLineHeightRect(forU16CursorPos _: UInt) -> CGRect { .zero }
}

var proxy: ShimClientProxy?
var session: InputSession?
var closePanelsCount: Int32 = 0

nonisolated func copyOut(_ string: String, _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
  let utf8 = Array(string.utf8)
  guard let buffer, capacity > 0 else { return Int32(utf8.count) }
  let count = min(utf8.count, Int(capacity) - 1)
  for i in 0 ..< count { buffer[i] = CChar(bitPattern: utf8[i]) }
  buffer[count] = 0
  return Int32(utf8.count)
}

// MARK: - C API（一律在宿主的主執行緒呼叫）

/// 引擎是否處於單元測試模式。驗證時必須是 0，否則主佇列路徑會被繞過。
@_cdecl("vg_pending_unit_tests")
nonisolated public func vgPendingUnitTests() -> Int32 {
  UserDefaults.pendingUnitTests ? 1 : 0
}

/// 載入辭庫並建立 session。回傳 0 成功；1 讀檔失敗；2 辭庫載入失敗。
@_cdecl("vg_init")
nonisolated public func vgInit(_ textMapPath: UnsafePointer<CChar>) -> Int32 {
  let path = String(cString: textMapPath)
  return mainSync {
    guard let textMap = try? String(contentsOfFile: path, encoding: .utf8) else { return 1 }
    guard LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap) else { return 2 }

    let newProxy = ShimClientProxy()
    let proxyAddr = UInt(bitPattern: Unmanaged.passUnretained(newProxy).toOpaque())
    proxy = newProxy

    SessionHost.shared.isCoreDBConnected = { true }
    // 預設是 { _ in false }，不改的話 session.clientProxy 永遠是 nil。
    SessionHost.shared.isControllerAddressAlive = { $0 == proxyAddr }
    SessionHost.shared.postEventForClosingAllPanels = { closePanelsCount += 1 }

    PrefMgr.sharedSansDidSetOps.mostRecentInputMode = Shared.InputMode.imeModeCHT.rawValue
    session = InputSession(preallocated: (), manuallyAssignedClientProxy: newProxy)
    return 0
  }
}

@_cdecl("vg_is_activated")
nonisolated public func vgIsActivated() -> Int32 {
  mainSync { (session?.isActivated ?? false) ? 1 : 0 }
}

/// 送一個 fcitx5 按鍵（keysym 與 KeyState 位元）。
/// 回傳 1 引擎已處理、0 放行、-1 無法轉成 KBEvent、-2 尚未 vg_init。
@_cdecl("vg_key")
nonisolated public func vgKey(_ keySym: UInt32, _ modifiers: UInt32, _ isDown: Int32) -> Int32 {
  mainSync {
    guard let session else { return -2 }
    // 上游對照表只收大寫字母的 keysym（0x41–0x5A），fcitx5 沒按 Shift 時給的是小寫，這裡先轉。
    let normalized = (0x61 ... 0x7A).contains(keySym) ? keySym - 0x20 : keySym
    guard let event = KBEvent(
      fcitxKeyCode: normalized, fcitxModifierFlags: modifiers, isKeyDown: isDown != 0
    ) else { return -1 }
    return session.handleEvent(event) ? 1 : 0
  }
}

/// 上游對照表是否直接認得這個 keysym（不經上面的大小寫轉換）。
@_cdecl("vg_keysym_known")
nonisolated public func vgKeysymKnown(_ keySym: UInt32) -> Int32 {
  mainSync { KBEvent(fcitxKeyCode: keySym, fcitxModifierFlags: 0) != nil ? 1 : 0 }
}

/// 前端最後一次收到的組字區字串（clientMarkedTextSetup）。回傳 UTF-8 位元組數。
@_cdecl("vg_copy_preedit")
nonisolated public func vgCopyPreedit(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
  copyOut(mainSync { proxy?.markedText ?? "" }, buffer, capacity)
}

@_cdecl("vg_preedit_calls")
nonisolated public func vgPreeditCalls() -> Int32 { mainSync { proxy?.markedCalls ?? 0 } }

/// 前端累計收到的送出文字（clientTextInsertion）。
@_cdecl("vg_copy_committed")
nonisolated public func vgCopyCommitted(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
  copyOut(mainSync { proxy?.committedText ?? "" }, buffer, capacity)
}

@_cdecl("vg_commit_calls")
nonisolated public func vgCommitCalls() -> Int32 { mainSync { proxy?.commitCalls ?? 0 } }

/// 引擎內部狀態的組字區字串（不經前端）。
@_cdecl("vg_copy_state_text")
nonisolated public func vgCopyStateText(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
  copyOut(mainSync { session?.state.displayedText ?? "" }, buffer, capacity)
}

/// 無條件走 asyncOnMain 的路徑，用來確認主佇列真的有在跑。
@_cdecl("vg_hide_palettes")
nonisolated public func vgHidePalettes() { mainSync { session?.hidePalettes() } }

@_cdecl("vg_close_panels_count")
nonisolated public func vgClosePanelsCount() -> Int32 { mainSync { closePanelsCount } }

/// A' 做法：讓 RunLoop 轉一圈、不等待，排空主佇列。
@_cdecl("vg_pump")
nonisolated public func vgPump() {
  _ = RunLoop.main.run(mode: .default, before: Date())
}

// MARK: - 背景執行緒 mainSync（重現辭庫非同步載入的形狀）

nonisolated let bgDone = Atomic<Int32>(0)

@_cdecl("vg_bg_main_sync")
nonisolated public func vgBackgroundMainSync() {
  Thread.detachNewThread {
    mainSync { _ = session?.isActivated }
    bgDone.store(1, ordering: .sequentiallyConsistent)
  }
}

@_cdecl("vg_bg_done")
nonisolated public func vgBackgroundDone() -> Int32 { bgDone.load(ordering: .sequentiallyConsistent) }
