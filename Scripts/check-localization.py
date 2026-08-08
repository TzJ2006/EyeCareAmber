#!/usr/bin/env python3
"""校验本地化完整性。

三件事：
  1. 四种语言的 key 集合完全一致（漏一条就会在 UI 上显示原始 key）
  2. 代码里 tr(...) 引用的 key 都有定义
  3. 定义了却没人用的 key（只警告，不算失败）

CI 和发版前都应该跑。key 不一致是本地化最常见的回归，
而且只在切到那个语言时才看得见 —— 靠人工点是发现不了的。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "Sources/Amber/Resources"
SRC = ROOT / "Sources/Amber"

KEY_LINE = re.compile(r'^\s*"([^"]+)"\s*=')
# tr("x")、tr("x", args)、language.text("x")、.format("x", ...)
CALL = re.compile(r'(?:\btr|\.text|\.format)\(\s*"([^"]+)"')

def load(lproj):
    keys = set()
    for line in (RES / lproj / "Localizable.strings").read_text(encoding="utf-8").splitlines():
        m = KEY_LINE.match(line)
        if m:
            keys.add(m.group(1))
    return keys

def main():
    langs = sorted(p.name for p in RES.iterdir() if p.name.endswith(".lproj"))
    if not langs:
        print("✗ 找不到任何 .lproj"); return 1
    tables = {l: load(l) for l in langs}
    base = "en.lproj" if "en.lproj" in tables else langs[0]
    failed = False

    print(f"语言：{', '.join(langs)}    基准：{base}（{len(tables[base])} 条）\n")

    for lang, keys in tables.items():
        missing = tables[base] - keys
        extra = keys - tables[base]
        if missing or extra:
            failed = True
            print(f"✗ {lang}")
            for k in sorted(missing): print(f"    缺少: {k}")
            for k in sorted(extra):   print(f"    多余: {k}")
        else:
            print(f"✓ {lang}  {len(keys)} 条，与基准一致")

    used = set()
    for swift in SRC.rglob("*.swift"):
        for m in CALL.finditer(swift.read_text(encoding="utf-8")):
            key = m.group(1)
            if "\\(" not in key:          # 跳过字符串插值构造的动态 key
                used.add(key)

    undefined = used - tables[base]
    print(f"\n代码引用 {len(used)} 条")
    if undefined:
        failed = True
        print("✗ 引用了但没有定义：")
        for k in sorted(undefined): print(f"    {k}")
    else:
        print("✓ 引用的 key 全部有定义")

    # Localization.swift 里的语言码必须匹配**构建产物**里的 lproj 目录名。
    #
    # 这条检查有真实来由：源码目录是 `zh-Hans.lproj`，但 SwiftPM 打包时会转成
    # 小写 `zh-hans.lproj`。`Bundle.path(forResource:ofType:)` 按精确字符串匹配
    # 资源表，大小写对不上就返回 nil，界面静默退化成原始 key —— 编译不报错、
    # 本机也不一定复现。所以必须对着产物核对，而不是对着源码目录。
    swift_src = (SRC / "Localization.swift").read_text(encoding="utf-8")
    codes = set(re.findall(r'return\s+(?:self == \.\w+\s*\?\s*)?"([a-zA-Z-]+)"', swift_src))
    codes |= set(re.findall(r'hasPrefix\("[a-z]+"\)\s*\{\s*return\s+"([a-zA-Z-]+)"', swift_src))
    codes &= {c for c in codes if c.lower() in {l[:-len(".lproj")].lower() for l in langs}}

    built = sorted(ROOT.glob(".build/*/Amber_Amber.bundle")) + \
            sorted(ROOT.glob(".build/*/*/Amber_Amber.bundle"))
    if not built:
        print("\n· 未找到构建产物，跳过语言码核对（先跑一次 swift build）")
    else:
        names = {p.name[:-len(".lproj")] for p in built[0].iterdir() if p.name.endswith(".lproj")}
        bad = {c for c in codes if c not in names}
        if bad:
            failed = True
            print(f"\n✗ 语言码与构建产物中的 lproj 名不符（{built[0].name}）：")
            for c in sorted(bad):
                near = [n for n in names if n.lower() == c.lower()]
                print(f"    代码用 \"{c}\"，产物里是 " +
                      (f"\"{near[0]}.lproj\"" if near else "（不存在）"))
        else:
            print(f"✓ 语言码与构建产物中的 lproj 名一致（{sorted(codes)}）")

    unused = tables[base] - used
    if unused:
        print(f"\n· 定义了但代码里没直接引用 {len(unused)} 条"
              "（可能由字符串插值动态拼出，属正常）：")
        print("    " + ", ".join(sorted(unused)))

    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
