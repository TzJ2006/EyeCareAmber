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

    # 代码里的每个语言码，在**每一种**构建产物里都必须能找到对应的 .lproj。
    #
    # 为什么不能只比字符串相等：两条构建路径产出的东西根本不一样 ——
    #
    #   swift build（原生）          扁平布局，目录名转小写：  zh-hans.lproj
    #   --arch a --arch b（xcbuild） 嵌套 Contents/Resources/，保留规范写法：zh-Hans.lproj
    #
    # 所以 Localization.swift 改成了不区分大小写地查找。这里要验的相应地
    # 变成「每种布局下都能找到」，而不是「大小写完全一致」。
    swift_src = (SRC / "Localization.swift").read_text(encoding="utf-8")
    codes = set(re.findall(r'return\s+(?:self == \.\w+\s*\?\s*)?"([a-zA-Z-]+)"', swift_src))
    codes |= set(re.findall(r'hasPrefix\("[a-z]+"\)\s*\{\s*return\s+"([a-zA-Z-]+)"', swift_src))
    src_langs = {l[: -len(".lproj")].lower() for l in langs}
    codes = {c for c in codes if c.lower() in src_langs}

    bundles = sorted(ROOT.glob(".build/**/Amber_Amber.bundle"))
    if not bundles:
        print("\n· 未找到构建产物，跳过语言码核对（先跑一次 swift build）")
    elif not codes:
        print("\n· 未从 Localization.swift 解析出语言码，跳过核对")
    else:
        print()
        for bundle in bundles:
            # 两种布局：扁平，或嵌套在 Contents/Resources 下
            roots = [bundle, bundle / "Contents" / "Resources"]
            found = {}
            for r in roots:
                if not r.is_dir():
                    continue
                for p in r.iterdir():
                    if p.name.endswith(".lproj"):
                        found[p.name[: -len(".lproj")].lower()] = p.name
            if not found:
                continue
            rel = bundle.relative_to(ROOT)
            missing = {c for c in codes if c.lower() not in found}
            if missing:
                failed = True
                print(f"✗ {rel}：找不到 {', '.join(sorted(missing))} 对应的 .lproj")
                print(f"    产物里只有：{', '.join(sorted(found.values()))}")
            else:
                shown = ", ".join(f"{c}→{found[c.lower()]}" for c in sorted(codes))
                print(f"✓ {rel}：{shown}")

    unused = tables[base] - used
    if unused:
        print(f"\n· 定义了但代码里没直接引用 {len(unused)} 条"
              "（可能由字符串插值动态拼出，属正常）：")
        print("    " + ", ".join(sorted(unused)))

    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
