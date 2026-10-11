import Foundation
import LexiconAssembly
import LibVanguard
import Shared
import SwiftExtension

/// 一個行程只有一組引擎狀態：上游的 `SessionHost.shared`、`InputSession.current` 本來就是全域的。
/// 第一版所有輸入情境共用同一個 session。
final class Engine {
  let proxy = ClientProxy()
  let ui = SessionUI()
  var session: InputSession?
  var factoryLoadFailed = false

  static var shared: Engine?
}

/// 宿主給的回呼與它的 context 指標。C 指標不是 Sendable，這裡只是原封不動交還給宿主。
nonisolated struct HostCallbacks: @unchecked Sendable {
  let context: UnsafeMutableRawPointer?
  let onCommit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> ()
  let onUpdate: @convention(c) (UnsafeMutableRawPointer?) -> ()

  func commit(_ text: String) { text.withCString { onCommit(context, $0) } }
  func update() { onUpdate(context) }
}

nonisolated func duplicate(_ string: String) -> UnsafeMutablePointer<CChar>? {
  strdup(string)
}

@_cdecl("vg_init")
nonisolated public func vgInit(
  _ textMapPath: UnsafePointer<CChar>,
  _ userDataFolder: UnsafePointer<CChar>,
  _ context: UnsafeMutableRawPointer?,
  _ onCommit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> (),
  _ onUpdate: @convention(c) (UnsafeMutableRawPointer?) -> ()
)
  -> Int32 {
  let path = String(cString: textMapPath)
  let folder = URL(fileURLWithPath: String(cString: userDataFolder), isDirectory: true)
  let host = HostCallbacks(context: context, onCommit: onCommit, onUpdate: onUpdate)
  return mainSync {
    guard Engine.shared == nil else { return 3 }
    guard FileManager.default.isReadableFile(atPath: path) else { return 1 }
    guard UserData.wireUp(folder: folder) else { return 2 }

    // 注音變體選字符的資料表跟辭庫裝在同一個目錄。引擎預設是從宿主執行檔旁邊找，
    // 在 fcitx5 裡那是 /usr/bin，找不到；所以這裡明確指定。沒有這個檔時引擎會原樣輸出、不轉換。
    let table = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("phonic_table_Z.txt")
    if FileManager.default.isReadableFile(atPath: table.path) {
      ResourceProvision.specifyBPMFVSTable(table)
    }

    let engine = Engine()
    engine.proxy.onCommit = { host.commit($0) }
    engine.proxy.onUpdate = { host.update() }
    engine.ui.candidateController.onUpdate = { host.update() }

    let proxyAddr = UInt(bitPattern: Unmanaged.passUnretained(engine.proxy).toOpaque())
    // 預設是 { _ in false }，不改的話 session.clientProxy 永遠是 nil。
    SessionHost.shared.isControllerAddressAlive = { $0 == proxyAddr }
    SessionHost.shared.ui = { engine.ui }
    SessionHost.shared.postEventForClosingAllPanels = { engine.ui.candidateController.visible = false }

    // 原廠辭庫走引擎的正式載入路徑：背景佇列讀檔，回到主佇列掛上。
    // 所以這個函式返回時辭庫還沒好，要等宿主 pump 過；期間按鍵會被引擎擋下並提示辭庫未載入。
    LXAssembly.LXFacade.connectFactoryDictionary(textMapPath: path) { loaded in
      asyncOnMain {
        Engine.shared?.factoryLoadFailed = !loaded
        host.update()
      }
    }

    if Shared.InputMode(rawValue: PrefMgr.sharedSansDidSetOps.mostRecentInputMode) ?? .imeModeNULL == .imeModeNULL {
      PrefMgr.sharedSansDidSetOps.mostRecentInputMode = Shared.InputMode.imeModeCHT.rawValue
    }
    UserData.load()
    engine.session = InputSession(preallocated: (), manuallyAssignedClientProxy: engine.proxy)
    Engine.shared = engine
    return 0
  }
}

/// 原廠辭庫的狀態：0 還在載入、1 已可用、-1 載入失敗。
@_cdecl("vg_lexicon_state")
nonisolated public func vgLexiconState() -> Int32 {
  mainSync {
    if LXAssembly.LXFacade.isFactoryDictionaryLoaded { return 1 }
    return (Engine.shared?.factoryLoadFailed ?? false) ? -1 : 0
  }
}

/// 注音變體選字符的資料表有沒有載入：1 有、0 沒有（功能會退回不轉換）。
@_cdecl("vg_bpmfvs_table_loaded")
nonisolated public func vgBPMFVSTableLoaded() -> Int32 {
  mainSync { (ResourceProvision.availabilityReport()["BPMFVS.phonic_table_Z"] ?? false) ? 1 : 0 }
}

/// 宿主要結束前呼叫：把選字記憶與偏好設定寫回磁碟。
@_cdecl("vg_shutdown")
nonisolated public func vgShutdown() {
  mainSync {
    guard Engine.shared != nil else { return }
    UserData.savePOM()
    UserDefaults.standard.synchronize()
  }
}

@_cdecl("vg_pump")
nonisolated public func vgPump() {
  _ = RunLoop.main.run(mode: .default, before: Date())
}

@_cdecl("vg_is_activated")
nonisolated public func vgIsActivated() -> Int32 {
  mainSync { (Engine.shared?.session?.isActivated ?? false) ? 1 : 0 }
}

@_cdecl("vg_key_down")
nonisolated public func vgKeyDown(_ keySym: UInt32, _ keyStates: UInt32) -> Int32 {
  mainSync {
    guard let session = Engine.shared?.session else { return 0 }
    // 上游對照表只收大寫字母的 keysym（0x41–0x5A），fcitx5 沒按 Shift 時給的是小寫。
    let normalized = (0x61 ... 0x7A).contains(keySym) ? keySym - 0x20 : keySym
    guard let event = KBEvent(fcitxKeyCode: normalized, fcitxModifierFlags: keyStates, isKeyDown: true)
    else { return 0 }
    return session.handleEvent(event) ? 1 : 0
  }
}

@_cdecl("vg_focus_in")
nonisolated public func vgFocusIn() {
  mainSync { Engine.shared?.session?.performServerActivation() }
}

@_cdecl("vg_reset")
nonisolated public func vgReset(_ commitExisting: Int32) {
  mainSync {
    guard let session = Engine.shared?.session else { return }
    if commitExisting != 0 {
      session.resetInputHandler(forceComposerCleanup: true, commitExisting: true)
    } else {
      // 引擎的 `.ofEmpty` 會把組字區的字送出去；要丟棄得走 `.ofAbortion`。
      session.switchState(.ofAbortion())
    }
  }
}

@_cdecl("vg_preedit")
nonisolated public func vgPreedit() -> UnsafeMutablePointer<CChar>? {
  duplicate(mainSync { Engine.shared?.proxy.markedText ?? "" })
}

@_cdecl("vg_preedit_cursor")
nonisolated public func vgPreeditCursor() -> Int32 {
  mainSync {
    guard let proxy = Engine.shared?.proxy else { return 0 }
    let utf16 = proxy.markedText.utf16
    let offset = min(max(0, proxy.markedCursorU16), utf16.count)
    let index = utf16.index(utf16.startIndex, offsetBy: offset)
    return Int32(proxy.markedText.utf8.distance(from: proxy.markedText.startIndex, to: index))
  }
}

// MARK: - 候選字

/// 目前這一頁的快照：(標籤, 文字) 與反白位置。
private func currentPage() -> (items: [(label: String, text: String)], highlighted: Int, range: Range<Int>, total: Int) {
  guard let controller = Engine.shared?.ui.candidateController, controller.visible else { return ([], -1, 0 ..< 0, 0) }
  let all = controller.candidates
  let range = controller.pageRange
  let keys = controller.selectionKeys
  let items = range.enumerated().map { offset, index in
    (label: offset < keys.count ? String(keys[offset]) : "", text: all[index].value)
  }
  let highlighted = range.contains(controller.highlightedIndex) ? controller.highlightedIndex - range.lowerBound : -1
  return (items, highlighted, range, all.count)
}

@_cdecl("vg_candidates_visible")
nonisolated public func vgCandidatesVisible() -> Int32 {
  mainSync { currentPage().items.isEmpty ? 0 : 1 }
}

@_cdecl("vg_candidate_count")
nonisolated public func vgCandidateCount() -> Int32 {
  mainSync { Int32(currentPage().items.count) }
}

@_cdecl("vg_candidate_text")
nonisolated public func vgCandidateText(_ index: Int32) -> UnsafeMutablePointer<CChar>? {
  duplicate(mainSync {
    let items = currentPage().items
    return items.indices.contains(Int(index)) ? items[Int(index)].text : ""
  })
}

@_cdecl("vg_candidate_label")
nonisolated public func vgCandidateLabel(_ index: Int32) -> UnsafeMutablePointer<CChar>? {
  duplicate(mainSync {
    let items = currentPage().items
    return items.indices.contains(Int(index)) ? items[Int(index)].label : ""
  })
}

@_cdecl("vg_candidate_highlighted")
nonisolated public func vgCandidateHighlighted() -> Int32 {
  mainSync { Int32(currentPage().highlighted) }
}

@_cdecl("vg_candidate_has_prev_page")
nonisolated public func vgCandidateHasPrevPage() -> Int32 {
  mainSync { currentPage().range.lowerBound > 0 ? 1 : 0 }
}

@_cdecl("vg_candidate_has_next_page")
nonisolated public func vgCandidateHasNextPage() -> Int32 {
  mainSync {
    let page = currentPage()
    return page.range.upperBound < page.total ? 1 : 0
  }
}

@_cdecl("vg_candidate_select")
nonisolated public func vgCandidateSelect(_ index: Int32) {
  mainSync {
    guard let engine = Engine.shared, let session = engine.session else { return }
    guard let target = engine.ui.candidateController.candidateIndexAtKeyLabelIndex(Int(index)) else { return }
    session.candidatePairSelectionConfirmed(at: target)
  }
}

@_cdecl("vg_free")
nonisolated public func vgFree(_ string: UnsafeMutablePointer<CChar>?) {
  free(string)
}

// MARK: - 偏好設定

/// 讀一項偏好設定，轉成字串（布林值是 "true"／"false"）。key 是上游 `UserDef` 的名稱。
/// 不認得的 key 回傳 NULL。回傳值要用 vg_free() 釋放。
@_cdecl("vg_pref_get")
nonisolated public func vgPrefGet(_ key: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
  let key = String(cString: key)
  let text: String? = mainSync {
    guard UserDef(rawValue: key) != nil, let value = UserDefaults.standard.object(forKey: key) else { return nil }
    return switch value {
    case let value as Bool: value ? "true" : "false"
    case let value as String: value
    default: "\(value)"
    }
  }
  return text.flatMap(duplicate)
}

/// 寫一項偏好設定並立刻存檔。value 會依照這一項目前的型別解讀。
/// 回傳 0 成功；1 不認得的 key；2 value 的格式跟這一項的型別不合。
@_cdecl("vg_pref_set")
nonisolated public func vgPrefSet(_ key: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32 {
  let key = String(cString: key)
  let text = String(cString: value)
  return mainSync {
    let defaults = UserDefaults.standard
    guard UserDef(rawValue: key) != nil, let current = defaults.object(forKey: key) else { return 1 }
    switch current {
    case is Bool:
      guard let parsed = Bool(text) else { return 2 }
      defaults.set(parsed, forKey: key)
    case is Int:
      guard let parsed = Int(text) else { return 2 }
      defaults.set(parsed, forKey: key)
    case is Double:
      guard let parsed = Double(text) else { return 2 }
      defaults.set(parsed, forKey: key)
    case is String:
      defaults.set(text, forKey: key)
    default:
      return 2
    }
    defaults.synchronize()
    // 讓語言模型與鍵盤排列跟上新的設定，並丟掉打到一半的內容。
    SessionHost.shared.syncLMPrefs()
    Engine.shared?.session?.switchState(.ofAbortion())
    Engine.shared?.session?.inputHandler?.ensureKeyboardParser()
    return 0
  }
}
