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
void vg_candidate_select(int32_t index);

// 偏好設定。key 是上游 UserDef 的名稱（例如 "CandidateKeys"、"KeyboardParser4Zhuyin"）。
// 讀：轉成字串回傳（布林值是 "true"／"false"），不認得的 key 回傳 NULL；要用 vg_free() 釋放。
char *vg_pref_get(const char *key);
// 寫：value 依這一項目前的型別解讀，並立刻存檔。回傳 0 成功；1 不認得的 key；2 格式不合。
int32_t vg_pref_set(const char *key, const char *value);

void vg_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
