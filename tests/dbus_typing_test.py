#!/usr/bin/env python3
"""啟動真的 fcitx5 行程，扮演一個 DBus 客體應用程式，送按鍵並檢查引擎的輸出。

由 tests/run.sh 在隔離的環境裡執行，不要直接跑。
"""
import os
import subprocess
import sys
import time

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

SERVICE = "org.fcitx.Fcitx5"
CAP_PREEDIT = 1 << 1
CAP_FORMATTED_PREEDIT = 1 << 4
CAP_CLIENT_SIDE_INPUT_PANEL = 1 << 39

KEY_RETURN = 0xFF0D
KEY_ESCAPE = 0xFF1B
KEY_DOWN = 0xFF54
STATE_NUM_LOCK = 1 << 4


class Client:
    """收集 fcitx5 送給客體的訊號。"""

    def __init__(self, bus):
        self.commits = []
        self.preedit = ""
        self.candidates = []
        self.candidate_cursor = -1
        self.context = GLib.MainContext.default()

        portal = bus.get_object(SERVICE, "/org/freedesktop/portal/inputmethod")
        path, _uuid = portal.CreateInputContext(
            [("program", "vanguard-dbus-test")], dbus_interface="org.fcitx.Fcitx.InputMethod1"
        )
        self.ic = dbus.Interface(bus.get_object(SERVICE, path), "org.fcitx.Fcitx.InputContext1")
        self.ic.connect_to_signal("CommitString", self.on_commit)
        self.ic.connect_to_signal("UpdateFormattedPreedit", self.on_preedit)
        self.ic.connect_to_signal("UpdateClientSideUI", self.on_client_side_ui)
        self.ic.SetCapability(dbus.UInt64(CAP_PREEDIT | CAP_FORMATTED_PREEDIT | CAP_CLIENT_SIDE_INPUT_PANEL))
        self.ic.FocusIn()

    def on_commit(self, text):
        self.commits.append(str(text))

    def on_preedit(self, segments, _cursor):
        self.preedit = "".join(str(text) for text, _flags in segments)

    def on_client_side_ui(self, _preedit, _cursor, _aux_up, _aux_down, candidates, cursor, *_rest):
        self.candidates = [(str(label), str(text)) for label, text in candidates]
        self.candidate_cursor = int(cursor)

    def settle(self, seconds=0.08):
        """讓 DBus 訊號進來。fcitx5 的回覆是非同步送達的。"""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while self.context.iteration(False):
                pass
            time.sleep(0.005)

    def key(self, sym, state=0):
        handled = bool(self.ic.ProcessKeyEvent(dbus.UInt32(sym), dbus.UInt32(0), dbus.UInt32(state), False, dbus.UInt32(0)))
        self.ic.ProcessKeyEvent(dbus.UInt32(sym), dbus.UInt32(0), dbus.UInt32(state), True, dbus.UInt32(0))
        self.settle()
        return handled

    def type(self, text, state=0):
        return [self.key(ord(ch), state) for ch in text]


class Report:
    def __init__(self):
        self.total = 0
        self.failed = 0

    def check(self, what, ok, detail=""):
        self.total += 1
        self.failed += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] {what}{('：' + detail) if detail else ''}", flush=True)

    def equal(self, what, got, want):
        self.check(what, got == want, f"得到 {got!r}，預期 {want!r}")


def wait_for_name(bus, name, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if bus.name_has_owner(name):
            return True
        time.sleep(0.05)
    return False


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    log_path = os.environ["FCITX5_LOG"]
    report = Report()

    with open(log_path, "w") as log:
        fcitx5 = subprocess.Popen(
            ["fcitx5", "--disable=all", "--enable=dbus,dbusfrontend,keyboard,vanguard", "--verbose=vanguard=5"],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    try:
        print("1. 啟動 fcitx5 並切到 vanguard")
        report.check("fcitx5 在私有 DBus 上註冊", wait_for_name(bus, SERVICE))
        client = Client(bus)
        controller = dbus.Interface(bus.get_object(SERVICE, "/controller"), "org.fcitx.Fcitx.Controller1")
        controller.Activate()
        controller.SetCurrentIM("vanguard")
        client.settle(0.3)
        report.equal("目前輸入法", str(controller.CurrentInputMethod()), "vanguard")

        print("2. 打「ㄋㄧㄢˊ ㄓㄨㄥ」（su06 5j/ 空白）")
        handled = client.type("su065j/ ")
        report.check("每個鍵都被引擎攔下", all(handled), str(handled))
        report.equal("客體收到的組字區", client.preedit, "年終")
        report.equal("還沒有送字", client.commits, [])

        print("3. 按 ↓ 叫出候選字")
        client.key(KEY_DOWN)
        print(f"    候選字：{client.candidates}，反白第 {client.candidate_cursor} 個")
        report.equal("前兩個候選字", [text for _label, text in client.candidates[:2]], ["年終", "年中"])
        report.equal("選字鍵標籤", [label for label, _text in client.candidates[:2]], ["1. ", "2. "])

        print("4. 按 2 選「年中」")
        client.key(ord("2"))
        report.equal("組字區變成", client.preedit, "年中")
        report.equal("候選字收起來", client.candidates, [])

        print("5. 按 Enter 送字")
        client.key(KEY_RETURN)
        report.equal("客體收到的送字", client.commits, ["年中"])
        report.equal("組字區清空", client.preedit, "")

        print("6. 組字區是空的時候，Enter 要放行給應用程式")
        report.equal("Enter 是否被攔下", client.key(KEY_RETURN), False)

        print("7. 開著 Num Lock 打字（一般桌面的常態）")
        client.type("284", STATE_NUM_LOCK)
        report.equal("組字區", client.preedit, "大")
        client.type("gj4", STATE_NUM_LOCK)
        report.equal("組字區", client.preedit, "大樹")
        client.key(KEY_RETURN, STATE_NUM_LOCK)
        report.equal("累計送字", client.commits, ["年中", "大樹"])

        print("8. 打到一半按 Esc")
        client.type("su0")
        report.equal("組字區", client.preedit, "ㄋㄧㄢ")
        client.key(KEY_ESCAPE)
        report.equal("Esc 之後組字區", client.preedit, "")

        print("9. 打到一半焦點離開，組字區的字要送出去，而且只送一次")
        client.type("284")
        report.equal("組字區", client.preedit, "大")
        client.ic.FocusOut()
        client.settle(0.3)
        report.equal("累計送字", client.commits, ["年中", "大樹", "大"])
        client.ic.FocusIn()
        client.settle(0.2)
        client.type("28")
        report.equal("回到焦點後組字區從頭開始", client.preedit, "ㄉㄚ")
        client.key(KEY_ESCAPE)

        print("10. 用滑鼠點選候選字（客體呼叫 SelectCandidate）")
        client.type("su065j/ ")
        before = client.preedit
        client.key(KEY_DOWN)
        texts = [text for _label, text in client.candidates]
        # 第 4 步選過「年中」，引擎會記住使用者的選擇，所以這裡的首選與順序可能跟第 3 步不同。
        print(f"    組字區 {before!r}，候選字 {texts}")
        target = "年終" if before == "年中" else "年中"
        report.check("另一個同音詞在候選字裡", target in texts)
        client.ic.SelectCandidate(texts.index(target) if target in texts else 0)
        client.settle()
        report.equal("點選之後組字區", client.preedit, target)
        report.equal("候選字收起來", client.candidates, [])

        print("11. 打到一半切換輸入法，組字區的字要送出去，而且只送一次")
        controller.SetCurrentIM("keyboard-us")
        client.settle(0.3)
        report.equal("累計送字", client.commits, ["年中", "大樹", "大", target])
        controller.SetCurrentIM("vanguard")
        client.settle(0.3)
        report.equal("切回來", str(controller.CurrentInputMethod()), "vanguard")

        print("12. 閒置 1 秒後 fcitx5 仍然正常")
        client.settle(1.0)
        report.check("fcitx5 行程還活著", fcitx5.poll() is None)
        client.type("284")
        report.equal("閒置後還能打字，組字區", client.preedit, "大")
        client.key(KEY_ESCAPE)
    finally:
        fcitx5.terminate()
        try:
            fcitx5.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fcitx5.kill()
        print(f"    fcitx5 結束碼 {fcitx5.returncode}")

    print("--- fcitx5 紀錄裡跟 vanguard 有關的行：")
    with open(log_path) as log:
        for line in log:
            if "anguard" in line or "rror" in line:
                print("    " + line.rstrip())
    print(f"結果：{'FAIL' if report.failed else 'PASS'}（{report.total} 項檢查，{report.failed} 項失敗）")
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
