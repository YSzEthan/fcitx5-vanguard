// SPDX-License-Identifier: LGPL-3.0-or-later
import LibVanguard
import Shared

/// 符號選單（預設按 ` 叫出）的內容。
///
/// 引擎只提供選單的機制，`CandidateNode.factoryRoot` 預設是空的；macOS 版的內容在它的 app 裡，
/// 這裡沒有。選單是空的時候按 ` 會進入一個沒有候選字、所有按鍵都被吃掉的狀態，
/// 所以一定要填。下面的分類與符號是本專案自己整理的，不是從 macOS 版搬來的。
enum SymbolMenu {
  private static let categories: [(String, String)] = [
    ("常用標點", "，、。．？！；：‧…—～·"),
    ("引號括號", "「」『』（）［］｛｝〈〉《》【】〔〕“”‘’"),
    ("全形英數符號", "＃＄％＆＊＋－／＜＝＞＠＼＾＿｀｜"),
    ("數學", "±×÷≠≒≡≦≧＜＞∞∴∵√∑∏∫∠⊥∥°′″"),
    ("箭頭", "←↑→↓↖↗↘↙↔↕⇐⇒⇔"),
    ("圖形", "○●◎△▲▽▼□■◇◆☆★♀♂♠♥♦♣♪※§"),
    ("單位貨幣", "℃℉㎜㎝㎞㎎㎏㏄￥＄€£¢％‰"),
    ("數字", "①②③④⑤⑥⑦⑧⑨⑩ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ"),
    ("希臘字母", "αβγδεζηθικλμνξοπρστυφχψωΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"),
    ("注音符號", "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˊˇˋ˙"),
    ("日文假名", "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"),
    ("框線", "─│┌┐└┘├┤┬┴┼═║╔╗╚╝"),
  ]

  static func install() {
    CandidateNode.factoryRoot = CandidateNode(
      name: "/",
      members: categories.map { name, symbols in
        CandidateNode(name: name, symbols: symbols.map(String.init))
      }
    )
  }
}
