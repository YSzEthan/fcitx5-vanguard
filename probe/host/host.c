// 階段 2a/2b 宿主：模擬 fcitx5 的處境。
// C 的 main()，主執行緒跑自己的 epoll 迴圈，不呼叫 dispatch_main()、不跑 RunLoop；
// 探針函式庫用 dlopen 載入（fcitx5 也是這樣載外掛）。
//
// 用法：host <libVGProbe.so 路徑> <none|runloop|fd>
//   none     不排空主佇列（2a）
//   runloop  每圈呼叫 Swift 端的 vgp_pump()（2b 的 A'）
//   fd       把 libdispatch 主佇列的 eventfd 加進 epoll，可讀時呼叫
//            _dispatch_main_queue_callback_4CF（2b 的 A）
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <time.h>
#include <unistd.h>

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

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "用法：%s <libVGProbe.so> <none|runloop|fd>\n", argv[0]);
    return 2;
  }
  const char *mode = argv[2];
  void *lib = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "dlopen 失敗: %s\n", dlerror());
    return 2;
  }
  void (*async_on_main)(void) = must_sym(lib, "vgp_async_on_main");
  void (*main_sync_from_bg)(void) = must_sym(lib, "vgp_main_sync_from_bg");
  int32_t (*async_count)(void) = must_sym(lib, "vgp_async_count");
  int32_t (*sync_count)(void) = must_sym(lib, "vgp_sync_count");
  int32_t (*bg_done)(void) = must_sym(lib, "vgp_bg_done");
  int32_t (*is_main_thread)(void) = must_sym(lib, "vgp_is_main_thread");
  void (*pump)(void) = must_sym(lib, "vgp_pump");

  int ep = epoll_create1(EPOLL_CLOEXEC);
  int qfd = -1;
  void (*queue_callback)(void *) = NULL;
  if (strcmp(mode, "fd") == 0) {
    void *dispatch = dlopen("libdispatch.so", RTLD_LAZY | RTLD_NOLOAD);
    if (!dispatch) {
      fprintf(stderr, "libdispatch.so 沒有被載入: %s\n", dlerror());
      return 2;
    }
    int (*get_handle)(void) = must_sym(dispatch, "_dispatch_get_main_queue_handle_4CF");
    queue_callback = must_sym(dispatch, "_dispatch_main_queue_callback_4CF");
    qfd = get_handle();
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = qfd};
    if (epoll_ctl(ep, EPOLL_CTL_ADD, qfd, &ev) != 0) {
      perror("epoll_ctl");
      return 2;
    }
    printf("主佇列 fd=%d flags=0x%x\n", qfd, fcntl(qfd, F_GETFL));
  }

  printf("mode=%s is_main_thread=%d\n", mode, is_main_thread());

  const int kAsyncCalls = 3;
  for (int i = 0; i < kAsyncCalls; i++) async_on_main();
  main_sync_from_bg();

  double start = now_ms(), first_done = -1;
  int wakeups = 0;
  while (now_ms() - start < 1500.0) {
    struct epoll_event evs[4];
    int n = epoll_wait(ep, evs, 4, 10);
    if (n < 0 && errno != EINTR) {
      perror("epoll_wait");
      return 2;
    }
    for (int i = 0; i < n; i++) {
      if (evs[i].data.fd == qfd) {
        wakeups++;
        uint64_t v;
        if (read(qfd, &v, sizeof v) < 0 && errno != EAGAIN) perror("read eventfd");
        queue_callback(NULL);
      }
    }
    if (strcmp(mode, "runloop") == 0) pump();
    if (first_done < 0 && async_count() == kAsyncCalls && bg_done()) first_done = now_ms() - start;
  }

  int a = async_count(), s = sync_count(), d = bg_done();
  printf("asyncOnMain 執行次數=%d/%d  mainSync 執行次數=%d/1  背景執行緒返回=%d", a, kAsyncCalls, s, d);
  if (qfd >= 0) printf("  eventfd 喚醒=%d", wakeups);
  if (first_done >= 0) printf("  全部完成於 %.1fms", first_done);
  printf("\n");
  int ok = (a == kAsyncCalls && s == 1 && d == 1);
  printf("結果：%s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
