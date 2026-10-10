// 階段 2c 宿主：C 的 main()，自己的 epoll 迴圈，dlopen 載入 libVGShim.so，模擬 fcitx5。
//
// 用法：host <libVGShim.so> <辭庫 txtMap 路徑> <none|runloop|aftercall|fd>
//   none       不排空主佇列（對照組，預期失敗）
//   runloop    A'：迴圈每圈（10ms）呼叫 vg_pump()
//   aftercall  A'：不輪詢，只在每次呼叫引擎之後呼叫一次 vg_pump()
//   fd         A ：把 libdispatch 主佇列 eventfd 加進 epoll，可讀時呼叫
//              _dispatch_main_queue_callback_4CF
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <time.h>
#include <unistd.h>

enum { kNone, kRunLoop, kAfterCall, kFd };

static int g_mode, g_ep, g_qfd = -1, g_failed, g_checks;
static void (*g_queue_callback)(void *);

static int32_t (*vg_pending_unit_tests)(void);
static int32_t (*vg_init)(const char *);
static int32_t (*vg_is_activated)(void);
static int32_t (*vg_key)(uint32_t, uint32_t, int32_t);
static int32_t (*vg_keysym_known)(uint32_t);
static int32_t (*vg_copy_preedit)(char *, int32_t);
static int32_t (*vg_preedit_calls)(void);
static int32_t (*vg_copy_committed)(char *, int32_t);
static int32_t (*vg_commit_calls)(void);
static int32_t (*vg_copy_state_text)(char *, int32_t);
static void (*vg_hide_palettes)(void);
static int32_t (*vg_close_panels_count)(void);
static void (*vg_pump)(void);
static void (*vg_bg_main_sync)(void);
static int32_t (*vg_bg_done)(void);

static void *must_sym(void *lib, const char *name) {
  void *p = dlsym(lib, name);
  if (!p) {
    fprintf(stderr, "找不到符號 %s: %s\n", name, dlerror());
    exit(2);
  }
  return p;
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// 宿主自己的事件迴圈，跑 ms 毫秒。
static void spin(double ms) {
  double start = now_ms();
  do {
    struct epoll_event evs[4];
    int n = epoll_wait(g_ep, evs, 4, 10);
    for (int i = 0; i < n; i++) {
      if (evs[i].data.fd == g_qfd) {
        uint64_t v;
        if (read(g_qfd, &v, sizeof v) < 0 && errno != EAGAIN) perror("read eventfd");
        g_queue_callback(NULL);
      }
    }
    if (g_mode == kRunLoop) vg_pump();
  } while (now_ms() - start < ms);
}

// 模擬「外掛在每次呼叫引擎後收尾」的時機。
static void after_call(void) {
  if (g_mode == kAfterCall) vg_pump();
}

static void check(const char *what, int ok) {
  g_checks++;
  if (!ok) g_failed++;
  printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
}

static void check_str(const char *what, const char *got, const char *want) {
  char line[512];
  snprintf(line, sizeof line, "%s：得到「%s」，預期「%s」", what, got, want);
  check(line, strcmp(got, want) == 0);
}

// 依序送出按鍵（按下＋放開），每個鍵之間讓宿主迴圈轉一下。
static void type_keys(const char *keys) {
  for (const char *p = keys; *p; p++) {
    uint32_t sym = *p == '\n' ? 0xff0d : (uint32_t)(unsigned char)*p;
    int32_t down = vg_key(sym, 0, 1);
    after_call();
    int32_t up = vg_key(sym, 0, 0);
    after_call();
    spin(15);
    char pre[256], st[256];
    vg_copy_preedit(pre, sizeof pre);
    vg_copy_state_text(st, sizeof st);
    printf("    鍵 0x%04x down=%d up=%d  前端組字區=「%s」 引擎狀態=「%s」\n", sym, down, up, pre, st);
  }
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "用法：%s <libVGShim.so> <txtMap> <none|runloop|aftercall|fd>\n", argv[0]);
    return 2;
  }
  const char *m = argv[3];
  g_mode = !strcmp(m, "runloop") ? kRunLoop : !strcmp(m, "aftercall") ? kAfterCall : !strcmp(m, "fd") ? kFd : kNone;

  void *lib = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "dlopen 失敗: %s\n", dlerror());
    return 2;
  }
  vg_pending_unit_tests = must_sym(lib, "vg_pending_unit_tests");
  vg_init = must_sym(lib, "vg_init");
  vg_is_activated = must_sym(lib, "vg_is_activated");
  vg_key = must_sym(lib, "vg_key");
  vg_keysym_known = must_sym(lib, "vg_keysym_known");
  vg_copy_preedit = must_sym(lib, "vg_copy_preedit");
  vg_preedit_calls = must_sym(lib, "vg_preedit_calls");
  vg_copy_committed = must_sym(lib, "vg_copy_committed");
  vg_commit_calls = must_sym(lib, "vg_commit_calls");
  vg_copy_state_text = must_sym(lib, "vg_copy_state_text");
  vg_hide_palettes = must_sym(lib, "vg_hide_palettes");
  vg_close_panels_count = must_sym(lib, "vg_close_panels_count");
  vg_pump = must_sym(lib, "vg_pump");
  vg_bg_main_sync = must_sym(lib, "vg_bg_main_sync");
  vg_bg_done = must_sym(lib, "vg_bg_done");

  g_ep = epoll_create1(EPOLL_CLOEXEC);
  if (g_mode == kFd) {
    void *dispatch = dlopen("libdispatch.so", RTLD_LAZY | RTLD_NOLOAD);
    if (!dispatch) {
      fprintf(stderr, "libdispatch.so 沒有被載入: %s\n", dlerror());
      return 2;
    }
    int (*get_handle)(void) = must_sym(dispatch, "_dispatch_get_main_queue_handle_4CF");
    g_queue_callback = must_sym(dispatch, "_dispatch_main_queue_callback_4CF");
    g_qfd = get_handle();
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = g_qfd};
    if (epoll_ctl(g_ep, EPOLL_CTL_ADD, g_qfd, &ev) != 0) {
      perror("epoll_ctl");
      return 2;
    }
  }

  char buf[256];
  printf("mode=%s\n", m);

  printf("1. 正式模式與 session 建構\n");
  check("UserDefaults.pendingUnitTests == false", vg_pending_unit_tests() == 0);
  double t0 = now_ms();
  int32_t rc = vg_init(argv[2]);
  printf("    vg_init 回傳 %d，耗時 %.1fms\n", rc, now_ms() - t0);
  check("辭庫載入、session 建立", rc == 0);
  // 正式模式下 construct() 走 asyncOnMain，所以這裡還不該是啟用狀態。
  printf("    vg_init 剛返回時 isActivated=%d（正式模式預期為 0）\n", vg_is_activated());
  after_call();
  double t1 = now_ms();
  while (!vg_is_activated() && now_ms() - t1 < 1000) spin(10);
  printf("    等了 %.1fms\n", now_ms() - t1);
  check("construct() 完成、isActivated 為真", vg_is_activated() == 1);

  printf("2. 鍵碼對照\n");
  printf("    上游對照表認得小寫 keysym 0x73(s)=%d、大寫 0x53(S)=%d\n", vg_keysym_known(0x73), vg_keysym_known(0x53));

  // 測試辭庫裡「年終」(-4.33) 權重高於「年中」(-5.33)，所以首選是「年終」。
  printf("3. 打「ㄋㄧㄢˊ ㄓㄨㄥ」（大千鍵位 su06 5j/ 空白）\n");
  type_keys("su065j/ ");
  vg_copy_preedit(buf, sizeof buf);
  check_str("前端收到的組字區", buf, "年終");
  vg_copy_state_text(buf, sizeof buf);
  check_str("引擎狀態的組字區", buf, "年終");

  printf("4. 主佇列路徑（hidePalettes → asyncOnMain → postEventForClosingAllPanels）\n");
  int32_t before = vg_close_panels_count();
  vg_hide_palettes();
  after_call();
  spin(50);
  int32_t after = vg_close_panels_count();
  printf("    計數 %d → %d\n", before, after);
  check("hidePalettes 之後計數加一", after == before + 1);

  printf("5. 按 Enter 送字\n");
  type_keys("\n");
  vg_copy_committed(buf, sizeof buf);
  check_str("clientTextInsertion 收到的字", buf, "年終");
  check("clientTextInsertion 被呼叫 1 次", vg_commit_calls() == 1);
  vg_copy_preedit(buf, sizeof buf);
  check_str("送字後前端組字區清空", buf, "");

  printf("6. 再打「ㄉㄚˋ ㄕㄨˋ」（284 gj4）並送出\n");
  type_keys("284gj4");
  vg_copy_preedit(buf, sizeof buf);
  check_str("前端收到的組字區", buf, "大樹");
  type_keys("\n");
  vg_copy_committed(buf, sizeof buf);
  check_str("累計送出的字", buf, "年終大樹");

  // 引擎的辭庫非同步載入是「背景佇列 → mainSync」。這裡在引擎已載入的行程裡重現同樣的形狀：
  // 背景執行緒發起 mainSync，宿主這段時間沒有任何引擎呼叫，只跑自己的迴圈。
  printf("7. 背景執行緒的 mainSync（宿主閒置、沒有按鍵）\n");
  vg_bg_main_sync();
  spin(200);
  int32_t idle_done = vg_bg_done();
  if (g_mode == kAfterCall) {
    // 這個模式只在引擎呼叫之後才 pump，閒置時沒人排空，預期背景執行緒會等到下一次 pump。
    printf("    閒置 200ms 後背景執行緒返回=%d（此模式預期為 0）\n", idle_done);
    vg_pump();
    spin(20);
    check("補一次 vg_pump() 之後背景執行緒返回", vg_bg_done() == 1);
  } else {
    check("閒置 200ms 內背景執行緒返回", idle_done == 1);
  }

  printf("    clientMarkedTextSetup 共 %d 次、clientTextInsertion 共 %d 次\n", vg_preedit_calls(), vg_commit_calls());
  printf("結果：%s（%d 項檢查，%d 項失敗）\n", g_failed ? "FAIL" : "PASS", g_checks, g_failed);
  return g_failed ? 1 : 0;
}
