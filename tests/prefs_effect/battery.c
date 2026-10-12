// SPDX-License-Identifier: LGPL-3.0-or-later
// 偏好設定的「有沒有作用」比對用：跑一組固定的打字情境，把引擎每一步的反應印出來。
//   battery <辭庫> <使用者資料夾> set KEY VALUE   只寫一項設定就結束（讓只在啟動時讀取的設定也測得到）
//   battery <辭庫> <使用者資料夾> run             跑全部情境並印出軌跡
// 由 tests/prefs_effect/compare.py 驅動：同一組情境在預設值與改過的值之下各跑一次，比對軌跡。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "vanguard.h"

enum { SHIFT = 1, CTRL = 4, ALT = 8, SUPER = 64 };
enum { K_BS = 0xff08, K_TAB = 0xff09, K_ENTER = 0xff0d, K_ESC = 0xff1b, K_HOME = 0xff50, K_LEFT = 0xff51,
       K_UP = 0xff52, K_RIGHT = 0xff53, K_DOWN = 0xff54, K_PGUP = 0xff55, K_PGDN = 0xff56, K_END = 0xff57,
       K_DEL = 0xffff, K_KP1 = 0xffb1 };

static void on_commit(void *context, const char *text) { (void)context; printf("    commit「%s」\n", text); }
static void on_update(void *context) { (void)context; }

static void show(const char *label, int handled) {
  char *preedit = vg_preedit(), *hint = vg_hint_text();
  printf("  %-22s h=%d 組字區「%s」@%d", label, handled, preedit, vg_preedit_cursor());
  if (hint && *hint) printf(" 提示「%s」", hint);
  if (vg_candidates_visible()) {
    printf(" 候選[%d/%d]", vg_candidate_page_index(), vg_candidate_page_count());
    for (int i = 0; i < vg_candidate_count(); i++) {
      char *text = vg_candidate_text(i);
      printf(" %s", text);
      vg_free(text);
    }
    printf(" 反白%d", vg_candidate_highlighted());
  }
  puts("");
  vg_free(preedit);
  vg_free(hint);
}

static void key(const char *label, unsigned sym, unsigned state) {
  int handled = vg_key_down(sym, state);
  vg_pump();
  show(label, handled);
}

static void type(const char *keys) {
  int handled = 1;
  for (const char *p = keys; *p; p++) {
    handled &= vg_key_down((unsigned char)*p, 0);
    vg_pump();
  }
  show(keys, handled);
}

static void scene(const char *title) {
  // 每個情境從乾淨的狀態開始，免得前一個情境的殘留影響下一個。
  vg_reset(0);
  vg_pump();
  if (vg_is_ascii_mode()) vg_toggle_ascii(1);
  printf("== %s\n", title);
}

int main(int argc, char **argv) {
  if (argc < 4) return 2;
  if (vg_init(argv[1], argv[2], NULL, on_commit, on_update) != 0) return 3;
  for (int i = 0; i < 3000 && vg_lexicon_state() == 0; i++) {
    vg_pump();
    usleep(10000);
  }
  // 磁帶、關聯詞語等資料檔是啟動後才在背景載入的，多排空幾輪讓它們就緒。
  for (int i = 0; i < 40; i++) {
    vg_pump();
    usleep(10000);
  }
  if (strcmp(argv[3], "set") == 0 && argc >= 6) {
    int rc = vg_pref_set(argv[4], argv[5]);
    vg_shutdown();
    vg_pump();
    return rc == 0 ? 0 : 4;
  }

  scene("基本：打字、叫出候選字、選字、送出");
  type("su3cl3"); key("↓", K_DOWN, 0); key("2", '2', 0); key("Enter", K_ENTER, 0);
  show("送出之後", 0);

  scene("單字打完的當下");
  type("su3"); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("有組字內容時按 Esc");
  type("su3cl3"); type("su"); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("空白鍵");
  key("Shift+Space（空）", ' ', SHIFT); key("Space（空）", ' ', 0);
  type("su3cl3"); key("Space", ' ', 0); key("Space", ' ', 0); key("Shift+Space", ' ', SHIFT); key("Esc", K_ESC, 0); key("Enter", K_ENTER, 0);

  scene("全形與半形標點");
  type("su3"); key("Shift+,", '<', SHIFT); key("Shift+.", '>', SHIFT); key("Enter", K_ENTER, 0);

  scene("聲調鍵：先打聲調、空的時候打聲調、覆寫聲調");
  type("3su"); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("su3"); key("4（覆寫聲調）", '4', 0); key("3", '3', 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("不成立的讀音");
  type("su"); type("s"); type("3"); key("BackSpace", K_BS, 0); key("BackSpace", K_BS, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("2u/3"); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("Shift+BackSpace、Shift+Delete");
  type("su3cl3"); key("Shift+BackSpace", K_BS, SHIFT); key("Shift+BackSpace", K_BS, SHIFT); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("Tab 與 Shift+Tab");
  type("su065j/ "); key("Tab", K_TAB, 0); key("Tab", K_TAB, 0); key("Shift+Tab", K_TAB, SHIFT);
  key("↓", K_DOWN, 0); key("Tab（候選）", K_TAB, 0); key("Shift+Tab（候選）", K_TAB, SHIFT);
  key("Space（候選）", ' ', 0); key("Shift+Space（候選）", ' ', SHIFT); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("游標位置與選字");
  type("rup wu0 wu0 fu4"); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0);
  key("←", K_LEFT, 0); key("↓", K_DOWN, 0); key("2", '2', 0); show("選字後", 0); key("↓", K_DOWN, 0);
  key("Esc", K_ESC, 0); key("Home", K_HOME, 0); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0);
  key("End", K_END, 0); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("候選字視窗裡的按鍵");
  type("su3"); key("↓", K_DOWN, 0); key("j", 'j', 0); key("k", 'k', 0); key("h", 'h', 0); key("l", 'l', 0);
  key("Shift+?", '?', SHIFT); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("候選字的內容：繪文字、長詞、罕用字");
  type("284gj4"); key("↓", K_DOWN, 0); key("PageDown", K_PGDN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("ji3"); key("↓", K_DOWN, 0);
  for (int i = 0; i < 12 && vg_candidate_page_index() + 1 < vg_candidate_page_count(); i++) { vg_key_down(K_PGDN, 0); vg_pump(); }
  show("最後一頁", 0); printf("  共 %d 頁\n", vg_candidate_page_count()); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("5j/ jp6ek7x93"); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("Shift+字母、數字小鍵盤");
  type("su3"); key("Shift+A", 'A', SHIFT); key("KP_1", K_KP1, 0); key("Enter", K_ENTER, 0);
  key("KP_1（空）", K_KP1, 0); key("Shift+A（空）", 'A', SHIFT); key("Esc", K_ESC, 0);

  scene("特殊的送出方式");
  type("su3cl3"); key("Ctrl+Enter", K_ENTER, CTRL); key("Esc", K_ESC, 0);
  type("su3cl3"); key("Ctrl+Alt+Enter", K_ENTER, CTRL | ALT); key("Esc", K_ESC, 0);
  type("su3cl3"); key("Ctrl+Alt+Super+Enter", K_ENTER, CTRL | ALT | SUPER); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("Shift+Enter 送出（關聯詞語的觸發鍵）");
  type("su3cl3"); key("Shift+Enter", K_ENTER, SHIFT); show("之後", 0); key("1", '1', 0); show("選了之後", 0);
  key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("su3"); key("↓", K_DOWN, 0); key("Shift+Enter（候選）", K_ENTER, SHIFT); show("之後", 0); key("Enter", K_ENTER, 0);
  key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("數字小鍵盤的其他鍵");
  key("KP_0（空）", 0xffb0, 0); key("KP_+（空）", 0xffab, 0);
  type("su3"); key("KP_5", 0xffb5, 0); key("KP_.", 0xffae, 0); key("Enter", K_ENTER, 0); key("Esc", K_ESC, 0);

  scene("磁帶模式會用到的按鍵（字根）");
  type("ggll"); key("Space", ' ', 0); key("Enter", K_ENTER, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("wq"); key("Space", ' ', 0); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0); key("Enter", K_ENTER, 0); key("Esc", K_ESC, 0);

  scene("沒打完就送出");
  type("su3cl"); key("Enter", K_ENTER, 0); key("Esc", K_ESC, 0);

  scene("送出之後有沒有關聯詞語");
  type("su3"); key("Enter", K_ENTER, 0); show("之後", 0); key("Esc", K_ESC, 0);

  scene("符號相關的鍵");
  key("`", '`', 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  key("Alt+`", '`', ALT); key("1", '1', 0); key("2", '2', 0); key("Enter", K_ENTER, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  key("\\", '\\', 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  key("Ctrl+Alt+,", ',', CTRL | ALT); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("數字與日期（貨幣數字、紀年）");
  type("u 284"); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("rup wu0 "); key("↓", K_DOWN, 0); key("PageDown", K_PGDN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("rup su06"); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("當成拼音打");
  type("ni3hao3"); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("連續打不加聲調");
  type("sucl"); key("Space", ' ', 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);

  scene("選字記憶：選過非首選的字之後再打一次");
  type("g4"); key("↓", K_DOWN, 0); key("3", '3', 0); key("Enter", K_ENTER, 0);
  type("g4"); key("↓", K_DOWN, 0); key("Esc", K_ESC, 0); key("Esc", K_ESC, 0);
  type("su3g4"); key("Enter", K_ENTER, 0);

  scene("英數模式是否跨次保留");
  printf("  toggle → %d\n", vg_toggle_ascii(1)); vg_focus_in(); vg_pump(); printf("  focus_in 之後 ascii=%d\n", vg_is_ascii_mode());

  vg_shutdown();
  vg_pump();
  return 0;
}
