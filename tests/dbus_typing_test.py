#!/usr/bin/env python3
"""啟動真的 fcitx5 行程，扮演一個 DBus 客體應用程式，送按鍵並檢查引擎的輸出。

由 tests/run.sh 在隔離的環境裡執行，不要直接跑。
"""
import os
import re
import shlex
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
KEY_LEFT = 0xFF51
KEY_DOWN = 0xFF54
KEY_PAGE_UP = 0xFF55
KEY_PAGE_DOWN = 0xFF56
KEY_SHIFT_R = 0xFFE2
STATE_SHIFT = 1 << 0
STATE_NUM_LOCK = 1 << 4


class Client:
    """收集 fcitx5 送給客體的訊號。"""

    def __init__(self, bus):
        self.commits = []
        self.preedit = ""
        self.candidates = []
        self.candidate_cursor = -1
        self.aux_up = ""
        self.aux_down = ""
        self.has_prev = False
        self.has_next = False
        self.layout = 0
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

    def on_client_side_ui(self, _preedit, _cursor, aux_up, aux_down, candidates, cursor, _layout, has_prev, has_next):
        self.candidates = [(str(label), str(text)) for label, text in candidates]
        self.candidate_cursor = int(cursor)
        self.aux_up = "".join(str(text) for text, _flags in aux_up)
        self.aux_down = "".join(str(text) for text, _flags in aux_down)
        self.has_prev = bool(has_prev)
        self.has_next = bool(has_next)
        self.layout = int(_layout)

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

    def raw_key(self, sym, state, is_release):
        self.ic.ProcessKeyEvent(dbus.UInt32(sym), dbus.UInt32(0), dbus.UInt32(state), is_release, dbus.UInt32(0))
        self.settle()

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


def start_fcitx5(bus, log_path):
    log = open(log_path, "a")
    process = subprocess.Popen(
        # 預設直接執行 fcitx5；測 flatpak 版時由 VANGUARD_FCITX5_CMD 換成 `flatpak run …`。
        shlex.split(os.environ.get("VANGUARD_FCITX5_CMD", "fcitx5")) + ["--disable=all", "--enable=dbus,dbusfrontend,keyboard,vanguard", "--verbose=vanguard=5"],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    if not wait_for_name(bus, SERVICE):
        raise RuntimeError("fcitx5 沒有在私有 DBus 上註冊")
    client = Client(bus)
    controller = dbus.Interface(bus.get_object(SERVICE, "/controller"), "org.fcitx.Fcitx.Controller1")
    controller.Activate()
    controller.SetCurrentIM("vanguard")
    client.settle(0.3)
    return process, client, controller


def stop_fcitx5(process):
    if os.environ.get("VANGUARD_FCITX5_CMD"):
        # 經 flatpak 啟動時，我們手上的行程是 flatpak／bwrap，對它送 SIGTERM 會讓沙盒裡的
        # fcitx5 直接被砍掉、來不及存檔。改走使用者實際會用的路：請 fcitx5 自己結束。
        try:
            bus = dbus.SessionBus()
            dbus.Interface(bus.get_object(SERVICE, "/controller"), "org.fcitx.Fcitx.Controller1").Exit()
        except dbus.DBusException:
            pass
    else:
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
    time.sleep(0.3)  # 等名稱從 bus 上消失
    return process.returncode


def wait_for_lexicon(client, timeout=30.0):
    """辭庫是非同步載入的。載入前引擎會擋下按鍵，所以一直試到注音出現為止。"""
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        client.key(ord("s"))
        if client.preedit == "ㄋ":
            client.key(KEY_ESCAPE)
            return time.monotonic() - start
        client.settle(0.1)
    return None


def candidate_texts(client):
    return [text for _label, text in client.candidates]


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    log_path = os.environ["FCITX5_LOG"]
    user_data = os.path.join(os.environ["XDG_DATA_HOME"], "fcitx5", "vanguard")
    report = Report()
    open(log_path, "w").close()

    print("=== 第一次啟動 ===")
    fcitx5, client, controller = start_fcitx5(bus, log_path)
    try:
        print("1. 啟動、切到 vanguard、等完整辭庫載入")
        report.equal("目前輸入法", str(controller.CurrentInputMethod()), "vanguard")
        waited = wait_for_lexicon(client)
        report.check("辭庫載入完成、可以打字", waited is not None, f"等了 {waited:.2f} 秒" if waited is not None else "逾時")

        print("2. 打「ㄋㄧˇ ㄏㄠˇ」（su3 cl3）——測試辭庫沒有、完整辭庫才有的詞")
        handled = client.type("su3cl3")
        report.check("每個鍵都被引擎攔下", all(handled), str(handled))
        report.equal("組字區", client.preedit, "你好")
        client.key(KEY_RETURN)
        report.equal("送字", client.commits, ["你好"])

        print("3. 同音詞選字：打「ㄋㄧㄢˊ ㄓㄨㄥ」，按 ↓，選不是首選的那個")
        client.type("su065j/ ")
        first_choice = client.preedit
        client.key(KEY_DOWN)
        texts = candidate_texts(client)
        print(f"    首選 {first_choice!r}，候選字 {texts[:6]}")
        report.check("年終與年中都在候選字裡", "年終" in texts and "年中" in texts)
        chosen = "年中" if first_choice == "年終" else "年終"
        label = client.candidates[texts.index(chosen)][0] if chosen in texts else "1. "
        report.check("選字鍵標籤是數字", label[:1].isdigit(), repr(label))
        client.key(ord(label[0]))
        report.equal("按選字鍵之後組字區", client.preedit, chosen)
        report.equal("候選字收起來", client.candidates, [])
        client.key(KEY_RETURN)
        report.equal("累計送字", client.commits, ["你好", chosen])

        print("4. 組字區是空的時候，Enter 要放行給應用程式")
        report.equal("Enter 是否被攔下", client.key(KEY_RETURN), False)

        print("5. 開著 Num Lock 打字（一般桌面的常態）")
        client.type("284gj4", STATE_NUM_LOCK)
        report.equal("組字區", client.preedit, "大樹")
        client.key(KEY_RETURN, STATE_NUM_LOCK)
        report.equal("累計送字", client.commits, ["你好", chosen, "大樹"])

        print("6. 打到一半按 Esc")
        client.type("su0")
        report.equal("組字區", client.preedit, "ㄋㄧㄢ")
        client.key(KEY_ESCAPE)
        report.equal("Esc 之後組字區", client.preedit, "")

        print("7. 打到一半焦點離開，組字區的字要送出去，而且只送一次")
        client.type("284")
        report.equal("組字區", client.preedit, "大")
        client.ic.FocusOut()
        client.settle(0.3)
        report.equal("累計送字", client.commits, ["你好", chosen, "大樹", "大"])
        client.ic.FocusIn()
        client.settle(0.2)
        client.type("28")
        report.equal("回到焦點後組字區從頭開始", client.preedit, "ㄉㄚ")
        client.key(KEY_ESCAPE)

        print("8. 用滑鼠點選候選字（客體呼叫 SelectCandidate）")
        client.type("284gj4")
        client.key(KEY_DOWN)
        texts = candidate_texts(client)
        print(f"    候選字 {texts[:6]}（共 {len(texts)} 個）")
        report.check("有兩個以上的候選字", len(texts) >= 2)
        clicked = texts[1] if len(texts) >= 2 else ""
        client.ic.SelectCandidate(1)
        client.settle()
        report.check("點選的字進了組字區", clicked != "" and clicked in client.preedit, f"點了 {clicked!r}，組字區 {client.preedit!r}")
        report.equal("候選字收起來", client.candidates, [])

        print("9. 打到一半切換輸入法，組字區的字要送出去，而且只送一次")
        pending = client.preedit
        controller.SetCurrentIM("keyboard-us")
        client.settle(0.3)
        report.equal("累計送字", client.commits, ["你好", chosen, "大樹", "大", pending])
        controller.SetCurrentIM("vanguard")
        client.settle(0.3)
        report.equal("切回來", str(controller.CurrentInputMethod()), "vanguard")

        print("10. 加入使用者語彙：打兩個不成詞的字，Shift+← 兩次選取，按 Enter")
        # 完整辭庫裡什麼詞都可能有，所以多準備幾組，用第一組「還不是詞」的。
        attempts = [("5j/ gj4", "ㄓㄨㄥ-ㄕㄨˋ"), ("gj4284", "ㄕㄨˋ-ㄉㄚˋ"), ("gj4su06", "ㄕㄨˋ-ㄋㄧㄢˊ")]
        phrase, phrase_keys, reading, before = "", "", "", []
        for phrase_keys, reading in attempts:
            client.type(phrase_keys)
            phrase = client.preedit
            client.key(KEY_DOWN)
            before = candidate_texts(client)
            client.key(KEY_ESCAPE)
            if phrase not in before:
                break
            client.key(KEY_ESCAPE)
        print(f"    讀音 {reading}，組字區 {phrase!r}，加入前的候選字 {before[:6]}")
        report.check("加入前，這兩個字不是一個詞", phrase not in before)
        client.key(KEY_LEFT, STATE_SHIFT)
        client.key(KEY_LEFT, STATE_SHIFT)
        client.key(KEY_RETURN)
        client.settle(0.6)
        phrases_path = os.path.join(user_data, "userdata-cht.txt")
        with open(phrases_path) as phrases_file:
            lines = [line.strip() for line in phrases_file if line.strip()]
        print(f"    {phrases_path} 的內容：{lines}")
        report.check("語彙檔多了一行", any(line.startswith(f"{phrase} {reading}") for line in lines))
        client.key(KEY_DOWN)
        after = candidate_texts(client)
        print(f"    加入後的候選字 {after[:6]}")
        report.check("加入後，候選字裡有這個詞", phrase in after)
        client.key(KEY_ESCAPE)
        client.key(KEY_ESCAPE)

        print("11. 按著 Shift 打全形標點（fcitx5 送來的是換檔後的符號，例如 Shift+, 是「<」）")
        before = len(client.commits)
        client.type("su3")
        handled = [client.key(ord(ch), STATE_SHIFT) for ch in "<>!?"]
        report.equal("每個鍵都被引擎攔下", handled, [True, True, True, True])
        report.equal("組字區", client.preedit, "你，。！？")
        client.key(KEY_RETURN)
        report.equal("送字", client.commits[before:], ["你，。！？"])

        print("12. 單獨按一下右 Shift 切換英數模式")
        before = len(client.commits)
        client.type("su3")
        client.key(KEY_SHIFT_R)
        report.equal("組字到一半的字先送出去", client.commits[before:], ["你"])
        report.equal("提示文字", client.aux_up, "英數模式")
        report.equal("英數模式下按鍵放行給應用程式", client.type("ab1"), [False, False, False])
        report.equal("組字區是空的", client.preedit, "")
        # 按著 Shift 打了別的字再放開，不算「單獨按一下」，模式不能變。
        client.raw_key(KEY_SHIFT_R, 0, False)
        client.key(ord("A"), STATE_SHIFT)
        client.raw_key(KEY_SHIFT_R, STATE_SHIFT, True)
        report.equal("按著 Shift 打字不會切換模式", client.type("a"), [False])
        client.key(KEY_SHIFT_R)
        report.equal("再按一下切回中文，提示文字", client.aux_up, "中文模式")
        client.type("su3")
        report.equal("切回來之後可以打注音", client.preedit, "你")
        report.equal("打字後提示收起來", client.aux_up, "")
        client.key(KEY_ESCAPE)

        print("13. 候選字翻頁：選字視窗要知道有沒有上一頁、下一頁")
        client.type("su3")
        client.key(KEY_DOWN)
        first_page = candidate_texts(client)
        report.check("選字視窗附註是頁碼與反白字的碼位", re.fullmatch(r"1/\d+  U\+4F60", client.aux_down) is not None,
                     repr(client.aux_down))
        report.check("第一頁：沒有上一頁、有下一頁", (client.has_prev, client.has_next) == (False, True),
                     f"has_prev={client.has_prev} has_next={client.has_next}")
        client.key(KEY_PAGE_DOWN)
        report.check("PageDown 之後內容換了、有上一頁", candidate_texts(client) != first_page and client.has_prev,
                     f"{candidate_texts(client)[:6]}")
        client.ic.NextPage()  # 滑鼠點選字視窗的「下一頁」箭頭
        client.settle(0.3)
        third_page = candidate_texts(client)
        client.ic.PrevPage()
        client.settle(0.3)
        report.check("滑鼠點翻頁箭頭也會翻", third_page != candidate_texts(client) and third_page != first_page,
                     f"點下一頁 {third_page[:3]}，再點上一頁 {candidate_texts(client)[:3]}")
        client.key(KEY_ESCAPE)
        client.key(KEY_ESCAPE)

        print("14. 符號選單（` 鍵）：進得去、選得到、Esc 出得來")
        before = len(client.commits)
        client.key(ord("`"))
        menu = candidate_texts(client)
        print(f"    選單第一頁 {menu}")
        report.check("選單有內容", "常用標點" in menu)
        client.key(ord("1"))
        report.check("進到子選單", "，" in candidate_texts(client), f"{candidate_texts(client)}")
        client.key(KEY_ESCAPE)
        report.check("Esc 回上一層", "常用標點" in candidate_texts(client))
        client.key(KEY_ESCAPE)
        report.equal("再按 Esc 離開選單", candidate_texts(client), [])
        client.type("su3")
        report.equal("離開後可以正常打字", client.preedit, "你")
        client.key(KEY_ESCAPE)
        report.equal("整個過程沒有多送字", client.commits[before:], [])

        print("15. fcitx5 設定介面：讀得到目前的值，改了立刻生效")
        uri = "fcitx://config/addon/vanguard"
        values, _description = controller.GetConfig(uri)
        report.equal("讀到的預設值", (str(values["HorizontalCandidateList"]), str(values["CandidateKeys"])), ("False", "123456789"))

        def set_config(horizontal, keys):
            controller.SetConfig(uri, dbus.Dictionary(
                {"HorizontalCandidateList": horizontal, "CandidateKeys": keys}, signature="sv", variant_level=1))
            client.settle(0.3)

        client.type("su3")
        client.key(KEY_DOWN)
        report.equal("預設一頁 9 個", len(client.candidates), 9)
        report.equal("第 9 個的標籤", client.candidates[8][0] if len(client.candidates) == 9 else None, "9. ")
        report.equal("預設直排（1 直排、2 橫排）", client.layout, 1)
        client.key(KEY_ESCAPE)
        client.key(KEY_ESCAPE)
        set_config("True", "123456")
        client.type("su3")
        client.key(KEY_DOWN)
        report.equal("改成橫排、一頁 6 個", (len(client.candidates), client.layout), (6, 2))
        client.key(KEY_ESCAPE)
        client.key(KEY_ESCAPE)
        set_config("False", "123456789")
        client.type("su3")
        client.key(KEY_DOWN)
        report.equal("改回來", (len(client.candidates), client.layout), (9, 1))
        client.key(KEY_ESCAPE)
        client.key(KEY_ESCAPE)

        print("16. 閒置 1 秒後 fcitx5 仍然正常")
        client.settle(1.0)
        report.check("fcitx5 行程還活著", fcitx5.poll() is None)
    finally:
        print(f"    fcitx5 結束碼 {stop_fcitx5(fcitx5)}")

    print("=== 重新啟動 fcitx5（同一個家目錄）===")
    fcitx5, client, controller = start_fcitx5(bus, log_path)
    try:
        waited = wait_for_lexicon(client)
        report.check("辭庫載入完成", waited is not None, f"等了 {waited:.2f} 秒" if waited is not None else "逾時")

        print("17. 選字記憶還在：第 3 步選過的詞變成首選")
        client.type("su065j/ ")
        report.equal("組字區", client.preedit, chosen)
        client.key(KEY_ESCAPE)

        print("18. 使用者語彙還在")
        client.type(phrase_keys)
        client.key(KEY_DOWN)
        report.check("候選字裡有第 10 步加的詞", phrase in candidate_texts(client), f"{candidate_texts(client)[:6]}")
        client.key(KEY_ESCAPE)
        client.key(KEY_ESCAPE)

        print("19. 偏好設定與使用者資料落地的位置")
        # 檔名取自行程名稱：一般安裝是 fcitx5，flatpak 版的執行檔叫 fcitx5-bin。
        found = [name for name in ("fcitx5.plist", "fcitx5-bin.plist")
                 if os.path.exists(os.path.join(os.environ["XDG_CONFIG_HOME"], name))]
        report.check("偏好設定檔存在", len(found) == 1, f"{os.environ['XDG_CONFIG_HOME']}：{found}")
        print(f"    使用者資料夾 {user_data}：{sorted(os.listdir(user_data))}")
    finally:
        print(f"    fcitx5 結束碼 {stop_fcitx5(fcitx5)}")

    print("--- fcitx5 紀錄裡跟 vanguard 有關的行：")
    with open(log_path) as log:
        for line in log:
            if ("vanguard.cpp" in line and "commit" not in line and "activate" not in line) or "rror" in line:
                print("    " + line.rstrip()[:200])
    print(f"結果：{'FAIL' if report.failed else 'PASS'}（{report.total} 項檢查，{report.failed} 項失敗）")
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
