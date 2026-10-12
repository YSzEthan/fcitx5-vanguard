// SPDX-License-Identifier: LGPL-3.0-or-later
// fcitx5-vanguard 引擎的 C 介面。
//
// 所有函式都必須在宿主的主執行緒呼叫。引擎有一部分工作排在 libdispatch 主佇列上，
// 宿主不跑 dispatch 主迴圈，所以要自己排空：每次呼叫引擎之後呼叫 vg_pump()，
// 閒置時也要用定時器定期呼叫（背景執行緒可能在等主佇列）。
#ifndef FCITX5_VANGUARD_H
#define FCITX5_VANGUARD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 引擎送字。text 是 UTF-8，只在回呼期間有效。
typedef void (*vg_commit_fn)(void *context, const char *text);
// 組字區或候選字有變動，宿主應重新讀取並更新畫面。
typedef void (*vg_update_fn)(void *context);

// 建立引擎。textmap_path 是原廠辭庫檔，user_data_dir 是放使用者語彙與選字記憶的資料夾（不存在會建立）。
// 回傳 0 成功；1 讀不到辭庫檔；2 使用者資料夾無法建立或寫入；3 已經初始化過。
// 辭庫是非同步載入的：返回時還沒好，要 vg_pump() 過，載入完成時會呼叫 on_update。
int32_t vg_init(const char *textmap_path, const char *user_data_dir, void *context,
                vg_commit_fn on_commit, vg_update_fn on_update);

// 原廠辭庫的狀態：0 還在載入、1 已可用、-1 載入失敗。
int32_t vg_lexicon_state(void);

// 注音變體選字符的資料表（跟辭庫同目錄的 phonic_table_Z.txt）有沒有載入：1 有、0 沒有。
// 沒有時只是該項輸出功能退回不轉換，不影響打字。
int32_t vg_bpmfvs_table_loaded(void);

// 宿主結束前呼叫：把選字記憶與偏好設定寫回磁碟。
void vg_shutdown(void);

// 排空主佇列一次，不等待。
void vg_pump(void);

// session 是否已啟用（vg_init 之後要 pump 過才會變成 1）。
int32_t vg_is_activated(void);

// 送一個按下的按鍵。key_sym 是 fcitx5 的 KeySym，key_states 是 fcitx5 的 KeyStates 原始位元。
// 回傳 1 引擎已處理、0 放行給應用程式。
int32_t vg_key_down(uint32_t key_sym, uint32_t key_states);

// 輸入焦點進入。
// 切換英數模式。宿主偵測到「單獨按一下 Shift」時呼叫；right_shift：0 左、1 右。
// 回傳切換後的狀態：1 英數、0 中文、-1 沒有切換（偏好設定關掉了這一側的 Shift）。
// 英數模式下 vg_key_down 一律回傳 0，按鍵交給應用程式。
int32_t vg_toggle_ascii(int32_t right_shift);
int32_t vg_is_ascii_mode(void);

// 要顯示在輸入面板輔助列的提示文字（模式切換提示等）；沒有時是空字串。會自己過期，
// 過期時呼叫 on_update。回傳的字串要用 vg_free() 釋放。
char *vg_hint_text(void);

void vg_focus_in(void);
// 清掉未完成的輸入。commit_existing 非 0 時先把組字區內容送出。
void vg_reset(int32_t commit_existing);

// 組字區字串。回傳值要用 vg_free() 釋放。
char *vg_preedit(void);
// 游標在組字區裡的位置（UTF-8 位元組偏移）。
int32_t vg_preedit_cursor(void);

// 候選字。引擎自己分頁，下列函式描述的是「目前這一頁」。
int32_t vg_candidates_visible(void);
int32_t vg_candidate_count(void);           // 這一頁的候選字數
char *vg_candidate_text(int32_t index);     // 要用 vg_free() 釋放
char *vg_candidate_label(int32_t index);    // 選字鍵標籤；要用 vg_free() 釋放
int32_t vg_candidate_highlighted(void);     // 這一頁裡反白的那一個，沒有則 -1
int32_t vg_candidate_has_prev_page(void);
int32_t vg_candidate_has_next_page(void);
// 直接選定這一頁的第 index 個候選字（滑鼠點選用）。
// 頁數與目前頁次（從 0 起算）；排列方向取自偏好設定 UseHorizontalCandidateList（1 橫排、0 直排）。
int32_t vg_candidate_page_count(void);
int32_t vg_candidate_page_index(void);
int32_t vg_candidate_layout_horizontal(void);

void vg_candidate_select(int32_t index);

// 偏好設定。key 是上游 UserDef 的名稱（例如 "CandidateKeys"、"KeyboardParser4Zhuyin"）。
// 讀：轉成字串回傳（布林值是 "true"／"false"），不認得的 key 回傳 NULL；要用 vg_free() 釋放。
char *vg_pref_get(const char *key);
// 寫：value 依這一項在引擎裡宣告的型別解讀（字串陣列與字典用 JSON），並立刻存檔。
// 回傳 0 成功；1 不認得的 key；2 格式不合；3 整數超出允許的範圍。
int32_t vg_pref_set(const char *key, const char *value);
// 列出全部偏好設定：JSON 陣列，每一項有 key、type（bool／int／double／string／array／dict）、
// default、value，整數另有 min、max、options（有的話）。要用 vg_free() 釋放。
char *vg_pref_describe(void);

void vg_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
