// 偏好設定的儲存測試：直接載入 libVGEngine.so（不經 fcitx5），分兩個行程執行。
//   prefs_host <libVGEngine.so> <辭庫> <使用者資料夾> set     改設定、確認立刻生效
//   prefs_host <libVGEngine.so> <辭庫> <使用者資料夾> check   新行程裡確認設定還在
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "vanguard.h"

static int g_failed, g_checks;

static void check_str(const char *what, char *got, const char *want) {
  int ok = got && strcmp(got, want) == 0;
  g_checks++;
  g_failed += !ok;
  printf("  [%s] %s：得到「%s」，預期「%s」\n", ok ? "PASS" : "FAIL", what, got ? got : "(NULL)", want);
  vg_free(got);
}

static void check_int(const char *what, int got, int want) {
  g_checks++;
  g_failed += got != want;
  printf("  [%s] %s：得到 %d，預期 %d\n", got == want ? "PASS" : "FAIL", what, got, want);
}

static void on_commit(void *context, const char *text) { (void)context, (void)text; }
static void on_update(void *context) { (void)context; }

static void type_keys(const char *keys) {
  for (const char *p = keys; *p; p++) {
    vg_key_down((unsigned char)*p, 0);
    vg_pump();
  }
}

int main(int argc, char **argv) {
  if (argc < 5) return 2;
  int setting = strcmp(argv[4], "set") == 0;
  check_int("vg_init", vg_init(argv[2], argv[3], NULL, on_commit, on_update), 0);
  for (int i = 0; i < 3000 && vg_lexicon_state() == 0; i++) {
    vg_pump();
    usleep(10000);
  }
  check_int("辭庫載入", vg_lexicon_state(), 1);
  check_int("注音變體資料表載入（跟辭庫同目錄）", vg_bpmfvs_table_loaded(), 1);

  if (setting) {
    check_str("選字鍵的預設值", vg_pref_get("CandidateKeys"), "123456");
    check_int("改選字鍵", vg_pref_set("CandidateKeys", "asdfgh"), 0);
    check_int("不認得的 key 被拒絕", vg_pref_set("NoSuchPreference", "1"), 1);
    check_int("型別不合被拒絕", vg_pref_set("UseSCPCTypingMode", "maybe"), 2);
    check_str("被拒絕後原值不變（布林值讀成字串）", vg_pref_get("UseSCPCTypingMode"), "false");
  }
  check_str("選字鍵", vg_pref_get("CandidateKeys"), "asdfgh");

  // 設定要真的影響引擎：叫出候選字，標籤應該是新的選字鍵。
  type_keys("su065j/ ");
  vg_key_down(0xff54, 0); // ↓
  vg_pump();
  check_int("候選字有出來", vg_candidates_visible(), 1);
  check_str("第 1 個候選字的標籤", vg_candidate_label(0), "a");
  check_str("第 2 個候選字的標籤", vg_candidate_label(1), "s");

  vg_shutdown();
  vg_pump();
  printf("結果：%s（%d 項檢查，%d 項失敗）\n", g_failed ? "FAIL" : "PASS", g_checks, g_failed);
  return g_failed ? 1 : 0;
}
