// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Homa
import LexiconAssembly
import LibVanguard
import Shared
import SwiftExtension

/// 辭庫與使用者資料的管理。上游把這一層留給宿主實作（macOS 版叫 LXMgr），
/// 這裡照它的行為做 Linux 版：檔名與檔案格式都跟 macOS 版相同，資料夾可以直接互通。
enum UserData {
  /// 使用者資料夾，由宿主在 vg_init 時指定。
  static var folder = URL(fileURLWithPath: "")

  static func dictURL(mode: Shared.InputMode, type: LXAssembly.ReplacableUserDataType) -> URL {
    let name = switch type {
    case .thePhrases: "userdata"
    case .theFilter: "exclude-phrases"
    case .theReplacements: "phrases-replacement"
    case .theAssociates: "associatedPhrases"
    case .theSymbols: "usersymbolphrases"
    }
    return folder.appendingPathComponent(name + (mode == .imeModeCHT ? "-cht.txt" : "-chs.txt"))
  }

  /// 使用者選字記憶（漸退模型）。
  static func pomURL(mode: Shared.InputMode) -> URL? {
    switch mode {
    case .imeModeCHS: folder.appendingPathComponent("override-model-data-chs.dat")
    case .imeModeCHT: folder.appendingPathComponent("override-model-data-cht.dat")
    case .imeModeNULL: nil
    }
  }

  /// 把引擎需要宿主提供的行為接上去。必須在第一次存取 `InputMode.lexicon` 之前呼叫：
  /// 語言模型建立時就會讀 `pomDataURL`。
  static func wireUp(folder newFolder: URL) -> Bool {
    folder = newFolder
    guard ensureFilesExist() else { return false }

    let host = SessionHost.shared
    host.isCoreDBConnected = { LXAssembly.LXFacade.isFactoryDictionaryLoaded }
    host.syncLMPrefs = { Shared.InputMode.validCases.forEach { $0.lexicon.syncPrefs() } }
    host.flushTrieCaches = { LXAssembly.LXFacade.flushTrieCaches() }
    host.userDictDataURL = { dictURL(mode: $0, type: $1) }
    host.pomDataURL = { pomURL(mode: $0) }
    host.savePerceptionOverrideModelData = { savePOM() }
    host.writeUserPhrasesAtOnce = { write($0, toFilter: $1) }
    host.checkIfPhrasePairExists = { value, mode, keyArray in
      mode.lexicon.lxQuerier.hasKeyValuePairFor(keyArray: keyArray, value: value, factoryDictionaryOnly: false)
    }
    host.checkIfPhrasePairIsFiltered = { value, mode, keyArray in
      mode.lexicon.lxQuerier.isPairFiltered(pair: .init(keyArray: keyArray, value: value))
    }
    host.isStateDataFilterableForMarked = { state in
      guard state.isMarkedLengthValid, state.markedTargetExists else { return false }
      guard state.markedReadings.count == 1 else { return true }
      return IMEApp.currentInputMode.lexicon.lxQuerier.countKeyValuePairs(
        keyArray: state.markedReadings, factoryDictionaryOnly: false
      ) > 1
    }
    host.bleachSpecifiedSuggestions = { targets, headReadings, mode in
      if let headReadings, !headReadings.isEmpty {
        mode.lexicon.bleachSpecifiedPOMSuggestions(headReadings: headReadings) { savePOM() }
      } else {
        mode.lexicon.bleachSpecifiedPOMSuggestions(targets: targets) { savePOM() }
      }
    }
    return true
  }

  /// 讀入使用者語彙、過濾清單、自訂符號與選字記憶。
  static func load() {
    for mode in Shared.InputMode.validCases {
      mode.lexicon.purgeUserData()
      mode.lexicon.loadUserPhrasesData(
        path: dictURL(mode: mode, type: .thePhrases).path,
        filterPath: dictURL(mode: mode, type: .theFilter).path
      )
      mode.lexicon.loadUserSymbolData(path: dictURL(mode: mode, type: .theSymbols).path)
      mode.lexicon.pomReducedLifetime = PrefMgr.sharedSansDidSetOps.reducePOMLifetimeToNoMoreThan12Hours
      mode.lexicon.loadPOMData()
    }
    if PrefMgr.sharedSansDidSetOps.phraseReplacementEnabled {
      for mode in Shared.InputMode.validCases {
        mode.lexicon.loadReplacementsData(path: dictURL(mode: mode, type: .theReplacements).path)
      }
    }
  }

  static func savePOM() {
    Shared.InputMode.validCases.forEach { $0.lexicon.savePOMData() }
  }

  // MARK: Private

  private static func ensureFilesExist() -> Bool {
    let manager = FileManager.default
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      return false
    }
    for mode in Shared.InputMode.validCases {
      for type in LXAssembly.ReplacableUserDataType.allCases {
        let path = dictURL(mode: mode, type: type).path
        if !manager.fileExists(atPath: path), !manager.createFile(atPath: path, contents: nil) { return false }
      }
    }
    return true
  }

  /// 把一筆語彙加到使用者語彙檔（或過濾清單）的尾端，然後重新載入。
  /// 一行的格式是「詞 讀音[ 權重][ 標記]」，跟 macOS 版相同。
  /// 跟 macOS 版的差別：這裡沒有繁簡轉換器，所以只寫目前模式那一份，不會同時寫另一種字體的檔案。
  private static func write(_ phrase: UserPhraseInsertable, toFilter: Bool) -> Bool {
    guard phrase.isValid else { return false }
    let lexicon = phrase.inputMode.lexicon
    let alreadyKnown = lexicon.lxQuerier.hasKeyValuePairFor(
      keyArray: phrase.keyArray, value: phrase.value, factoryDictionaryOnly: false
    )
    var cells = [phrase.value, phrase.joinedKey]
    if let weight = phrase.weight { cells.append(weight.description) }
    if alreadyKnown { cells.append("#𝙾𝚟𝚎𝚛𝚛𝚒𝚍𝚎") }
    let type: LXAssembly.ReplacableUserDataType = toFilter ? .theFilter : .thePhrases
    let url = dictURL(mode: phrase.inputMode, type: type)

    let written: Bool = LXAssembly.withFileHandleQueueSync {
      guard let handle = try? FileHandle(forUpdating: url) else { return false }
      defer { try? handle.close() }
      var line = Data((cells.joined(separator: " ") + "\n").utf8)
      // 原檔結尾沒有換行的話先補一個，免得黏在上一行後面。
      if let size = try? handle.seekToEnd(), size > 0 {
        try? handle.seek(toOffset: size - 1)
        if (try? handle.readToEnd())?.first != 0x0A { line.insert(0x0A, at: 0) }
      }
      _ = try? handle.seekToEnd()
      return (try? handle.write(contentsOf: line)) != nil
    }
    guard written else { return false }

    if toFilter {
      asyncOnMain { lexicon.reloadUserFilterDirectly(path: url.path) }
    } else {
      lexicon.loadUserPhrasesData(path: url.path, filterPath: nil, async: true)
    }
    return true
  }
}
