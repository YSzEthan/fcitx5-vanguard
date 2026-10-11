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

/// 第一版只提供候選字；tooltip、浮動組字窗、Shift／Caps Lock 切換都不做。
final class SessionUI: SessionUIProtocol {
  var currentSessionID = UUID()
  let candidateController = CandidateController()

  var shiftKeyUpChecker: (any ShiftKeyUpCheckerProtocol)? { nil }
  var capsLockHitChecker: (any HitCheckerProtocol)? { nil }
  var capsLockToggler: (any CapsLockTogglerProtocol)? { nil }
  var pcb: (any PCBProtocol)? { nil }
  var tooltipUI: (any TooltipUIProtocol)? { nil }
  var statusUI: (any TooltipUIProtocol)? { nil }
  var candidateUI: (any CtlCandidateProtocol)? { candidateController }
}
