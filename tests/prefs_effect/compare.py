#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-3.0-or-later
"""找出哪些偏好設定「改了之後行為真的不一樣」。

對每一項設定的每一個非預設值：在全新的家目錄寫入那個值，再啟動一次引擎跑 battery 的全部情境，
跟預設值的軌跡比對。有差異＝這一項在這個前端有可觀察到的作用；沒差異只代表這組情境測不出來，
不代表一定沒作用。

在 mint-dev 容器內執行：tests/prefs_effect/compare.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "dist", "engine")
LEXICON = os.path.join(ENGINE, "share", "vanguardTextMap.txtMap")


def build(work):
    binary = os.path.join(work, "battery")
    describe = os.path.join(work, "describe")
    subprocess.run(["cc", "-O1", "-o", binary, os.path.join(ROOT, "tests", "prefs_effect", "battery.c"),
                    f"-I{ENGINE}/include", f"-L{ENGINE}/lib", "-lVGEngine", f"-Wl,-rpath-link,{ENGINE}/lib"], check=True)
    source = os.path.join(work, "describe.c")
    with open(source, "w") as handle:
        handle.write('#include <stdio.h>\n#include <unistd.h>\n#include "vanguard.h"\n'
                     'static void c(void *x, const char *t) {(void)x;(void)t;}\nstatic void u(void *x) {(void)x;}\n'
                     'int main(int n, char **a) { (void)n; vg_init(a[1], a[2], NULL, c, u); puts(vg_pref_describe()); return 0; }\n')
    subprocess.run(["cc", "-o", describe, source, f"-I{ENGINE}/include", f"-L{ENGINE}/lib", "-lVGEngine",
                    f"-Wl,-rpath-link,{ENGINE}/lib"], check=True)
    return binary, describe


def run(binary, home, *arguments):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
           "LD_LIBRARY_PATH": os.path.join(ENGINE, "lib")}
    result = subprocess.run([binary, LEXICON, os.path.join(home, "userdata"), *arguments],
                            env=env, capture_output=True, text=True, timeout=120)
    return result.returncode, [line for line in result.stdout.splitlines() if "vChewingDebug" not in line]


CASSETTE = os.path.join(ROOT, "vendor", "vChewing-LibVanguard", "Sources", "LXAssemblyMaterials4Tests", "Resources", "wubi.cin")

# 有些設定要另一項先打開才看得出作用。這種的基準也要帶著同樣的前提，才是公平的比對。
PREREQUISITES = {
    "KeyboardParser4Pinyin": [("PinyinTypingEnabled", "true")],
    "FuriousTypingEnabled4Pinyin": [("PinyinTypingEnabled", "true")],
    "MixedAlnumJudgeReadingsBySequentialRawKeyOrder": [("MixedAlphanumericalEnabled", "true")],
    "EnableLatchedAlnumStateInMixedAlnumMode": [("MixedAlphanumericalEnabled", "true")],
    "SuppressFactoryUnigramsOfKanaSyllables": [("MixedAlphanumericalEnabled", "true")],
    "UseSpaceToCommitHighlightedCandidate4SCPC": [("UseSCPCTypingMode", "true")],
    "ReflectBPMFVSInCompositionBuffer": [("SpecifyCmdOptCtrlEnterBehavior", "4")],
    "FilterNonCNSReadingsForCHTInput": [("CNS11643Enabled", "true")],
    "AlsoConfirmAssociatedCandidatesByEnter": [("AssociatedPhrasesEnabled", "true")],
    # 磁帶模式要有磁帶檔才打得出字；用上游測試附的五筆表格。
    "CassetteEnabled": [("CassettePath", CASSETTE)],
    "ShowTranslatedStrokesInCompositionBuffer": [("CassettePath", CASSETTE), ("CassetteEnabled", "true")],
    "ForceCassetteChineseConversion": [("CassettePath", CASSETTE), ("CassetteEnabled", "true")],
    "AutoCompositeWithLongestPossibleCassetteKey": [("CassettePath", CASSETTE), ("CassetteEnabled", "true")],
}


def trace(binary, work, name, key=None, value=None, before=()):
    home = os.path.join(work, name)
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home)
    for other_key, other_value in before:
        run(binary, home, "set", other_key, other_value)
    if key is not None:
        code, _ = run(binary, home, "set", key, value)
        if code != 0:
            return None
    code, lines = run(binary, home, "run")
    return lines if code == 0 else lines + [f"（結束碼 {code}）"]


def alternatives(item):
    if item["type"] == "bool":
        return ["false" if item["default"] else "true"]
    if item["type"] == "int":
        if item.get("options"):
            values = [option["value"] for option in item["options"]]
        elif "min" in item:
            values = list(range(item["min"], item["max"] + 1))
        else:
            values = [item["default"] + 1, item["default"] * 2 or 3, 1, 0]
        return [str(value) for value in dict.fromkeys(values) if value != item["default"]][:6]
    return []


def main():
    only = set(sys.argv[1:])
    work = tempfile.mkdtemp(prefix="vg-prefs-effect-")
    binary, describe = build(work)
    _code, described = run(describe, os.path.join(work, "describe-home"))
    items = json.loads(next(line for line in described if line.startswith("[")))
    baseline = trace(binary, work, "baseline")
    again = trace(binary, work, "baseline2")
    if baseline != again:
        print("基準軌跡兩次不一致，比對結果不可信", file=sys.stderr)
        return 2
    print(f"基準軌跡 {len(baseline)} 行")
    results = {}
    for item in items:
        if only and item["key"] not in only:
            continue
        values = alternatives(item)
        if not values:
            results[item["key"]] = {"status": "skipped", "reason": f"型別 {item['type']} 不自動測"}
            continue
        differing = {}
        before = PREREQUISITES.get(item["key"], ())
        reference = trace(binary, work, "reference", before=before) if before else baseline
        for value in values:
            lines = trace(binary, work, "variant", item["key"], value, before=before)
            if lines is None:
                continue
            changed = [(a, b) for a, b in zip(reference, lines) if a != b]
            if changed or len(lines) != len(reference):
                differing[value] = {"lines": len(changed) + abs(len(lines) - len(reference)),
                                    "first": list(changed[0]) if changed else ["（行數不同）", ""]}
        results[item["key"]] = {"status": "effect" if differing else "no-difference", "values": values,
                                "differing": differing, "prerequisites": [list(pair) for pair in before]}
        mark = "有差異" if differing else "無差異"
        detail = ""
        if differing:
            value, info = next(iter(differing.items()))
            detail = f"  值 {value}：{info['lines']} 行不同，例如\n      預設 {info['first'][0].strip()}\n      改後 {info['first'][1].strip()}"
        print(f"{mark}\t{item['key']}{detail}", flush=True)
    path = os.path.join(ROOT, "tests", "prefs_effect", "results.json")
    if only and os.path.exists(path):
        # 只重測指定的幾項時，其餘沿用上次的結果。
        with open(path, encoding="utf-8") as handle:
            results = {**json.load(handle), **results}
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(results, handle, ensure_ascii=False, indent=1, sort_keys=True)
    shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
