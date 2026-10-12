// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import LibVanguard
import Shared

// MARK: - 客體 proxy

/// 引擎眼中的「客體應用程式」。把引擎輸出轉交給宿主（fcitx5 外掛）。
final class ClientProxy: NSObject, SessionClientProxy {
  var markedText = ""
  /// 游標位置，UTF-16 偏移（引擎給的單位）。
  var markedCursorU16 = 0
  var onCommit: (String) -> () = { _ in }
  var onUpdate: () -> () = {}

  func hasClient() -> Bool { true }

  func clientTextInsertion(with text: String, replacementRange _: NSRange) {
    onCommit(text)
  }

  func clientMarkedTextSetup(
    with text: NSAttributedString,
    selectionRange: NSRange,
    replacementRange _: NSRange
  ) {
    markedText = text.string
    markedCursorU16 = selectionRange.location == NSNotFound ? markedText.utf16.count : selectionRange.location
    onUpdate()
  }

  func clientBundleIdentifier() -> String? { "org.fcitx.Fcitx5" }
  func clientSelectMode(withModeIdentifier _: String) {}
  func clientOverrideKeyboard(withName _: String) {}

  func clientAttributesForCharacterIndex(
    atU16Pos _: UInt,
    lineHeightRectangle _: UnsafeMutablePointer<CGRect>
  )
    -> [AnyHashable: Any]? { nil }

  // 候選字視窗的位置由 fcitx5 決定，引擎不需要知道座標。
  func clientLineHeightRect(forU16CursorPos _: UInt) -> CGRect { .zero }
}

// MARK: - 候選字控制器

/// 引擎的候選字「視窗」。實際畫面由 fcitx5 畫，這裡只管分頁與反白位置。
/// 一頁的大小等於選字鍵的數量；一頁就是一列。
final class CandidateController: CtlCandidateProtocol {
  var onUpdate: () -> () = {}

  weak var delegate: (any CtlCandidateDelegate)? {
    didSet {
      highlightedIndex = 0
      onUpdate()
    }
  }

  var visible = false {
    didSet { if visible != oldValue { onUpdate() } }
  }

  var highlightedIndex = 0 {
    didSet {
      guard highlightedIndex != oldValue else { return }
      delegate?.candidatePairHighlightChanged(at: highlightedIndex)
      onUpdate()
    }
  }

  let expanded = false
  var currentLayout: UILayoutOrientation = .horizontal

  var candidates: [CandidateInState] { delegate?.candidatePairs(conv: true) ?? [] }
  var selectionKeys: [Character] { Array(delegate?.selectionKeys ?? "123456789") }
  var pageSize: Int { max(1, selectionKeys.count) }
  var pageIndex: Int { highlightedIndex / pageSize }

  /// 目前這一頁在整份候選字清單裡的範圍。
  var pageRange: Range<Int> {
    let count = candidates.count
    let start = min(pageIndex * pageSize, count)
    return start ..< min(start + pageSize, count)
  }

  func showNextPage() -> Bool { jump(to: (pageIndex + 1) * pageSize) }
  func showPreviousPage() -> Bool { jump(to: (pageIndex - 1) * pageSize) }
  func showNextLine() -> Bool { showNextPage() }
  func showPreviousLine() -> Bool { showPreviousPage() }
  func highlightNextCandidate() -> Bool { jump(to: highlightedIndex + 1) }
  func highlightPreviousCandidate() -> Bool { jump(to: highlightedIndex - 1) }

  func candidateIndexAtKeyLabelIndex(_ index: Int) -> Int? {
    let target = pageRange.lowerBound + index
    return pageRange.contains(target) ? target : nil
  }

  func set(
    windowTopLeftPoint _: CGPoint,
    bottomOutOfScreenAdjustmentHeight _: Double,
    useGCD _: Bool,
    animated _: Bool
  ) {}

  private func jump(to index: Int) -> Bool {
    guard candidates.indices.contains(index) else { return false }
    highlightedIndex = index
    return true
  }
}

// MARK: - SessionUI

/// 引擎的 tooltip 在這裡只留下文字，交給宿主畫在輸入面板的輔助文字列。
final class TextTooltip: TooltipUIProtocol {
  private(set) var text = ""
  private var expiry: Date?
  var onUpdate: () -> () = {}

  var isShown: Bool { !text.isEmpty }

  func show(
    tooltip: String, at _: CGPoint,
    bottomOutOfScreenAdjustmentHeight _: Double,
    direction _: UILayoutOrientation, duration: Double
  ) {
    show(tooltip, seconds: duration)
  }

  func show(_ tooltip: String, seconds: Double) {
    // 引擎的介面文字靠 NSLocalizedString 翻譯，翻譯表在 macOS 版的 app 裡，這裡沒有，
    // 拿到的會是「i18n:…」這種原始 key。與其把 key 秀給使用者看，不如不顯示。
    let shown = tooltip.contains("i18n:") ? "" : tooltip
    guard shown != text else { return }
    text = shown
    expiry = (seconds > 0 && !shown.isEmpty) ? Date().addingTimeInterval(seconds) : nil
    onUpdate()
  }

  func hide() {
    guard !text.isEmpty else { return }
    text = ""
    expiry = nil
    onUpdate()
  }

  /// 宿主定時呼叫：時間到了就收起來。
  func tick() {
    if let expiry, expiry <= Date() { hide() }
  }

  func setColor(state _: TooltipColorState) {}
  func sync(accent _: HSBA?, locale _: String) {}
}

/// 候選字、tooltip、狀態提示有接；浮動組字窗不做。
/// Shift 切換英數由宿主偵測後呼叫 `vg_toggle_ascii()`，不走引擎的 shiftKeyUpChecker。
final class SessionUI: SessionUIProtocol {
  var currentSessionID = UUID()
  let candidateController = CandidateController()
  let tooltip = TextTooltip()
  /// 模式切換之類的一過性提示；跟 tooltip 分開，免得互相蓋掉。
  let status = TextTooltip()

  var shiftKeyUpChecker: (any ShiftKeyUpCheckerProtocol)? { nil }
  var capsLockHitChecker: (any HitCheckerProtocol)? { nil }
  var capsLockToggler: (any CapsLockTogglerProtocol)? { nil }
  var pcb: (any PCBProtocol)? { nil }
  var tooltipUI: (any TooltipUIProtocol)? { tooltip }
  var statusUI: (any TooltipUIProtocol)? { status }
  var candidateUI: (any CtlCandidateProtocol)? { candidateController }
}
