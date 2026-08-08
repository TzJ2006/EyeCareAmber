#!/usr/bin/env python3
"""校验 README.md 与 README.zh-Hans.md 保持同步。

翻译文档最典型的失效方式不是「翻错」，而是**只改了一边**：
命令改了、参数改了、实测数字重新量过了，另一份还停在旧值。
读者按过期的那份操作，得到的是错的结果。

语言不同，正文没法逐句比。但下面这些是语言无关的：

  1. 标题层级序列   —— 结构一样，小节没有多出或漏掉
  2. shell 命令     —— 去掉注释后必须逐字相同（注释本来就该翻译）
  3. 表格形状       —— 每张表的行数、列数
  4. 表格里的数字   —— 参数表是最容易只改一边的地方
  5. 正文里的多位数 —— 色温、实测值、百分比、年份
  6. 链接 URL       —— 引用的是同一批来源

正文里的**个位数**刻意不比：英文习惯把小数字写成单词
（"one hour" / "two hours"），中文写 "1 小时" / "2 小时"，
两边语义相同却比不出来。参数密集的表格里没有这个问题，所以表格全比。
"""
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EN, ZH = "README.md", "README.zh-Hans.md"

FENCE = re.compile(r"^```(\w*)")
HEADING = re.compile(r"^(#{1,6})\s")
URL = re.compile(r"https?://[^\s)\]]+")
NUMBER = re.compile(r"(?<![\w.])\d[\d,]*(?:\.\d+)?(?![\w])")


def normalize_command(line):
    """去掉行尾注释和多余空白 —— 注释是给人读的，本来就该翻译。"""
    line = re.sub(r"\s+#.*$", "", line)
    return " ".join(line.split())


def parse(path):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    headings, commands, tables = [], [], []
    table_numbers, prose_numbers = [], []
    current_table, fence_lang = None, None
    in_code = False

    for line in lines:
        if m := FENCE.match(line):
            if in_code:
                in_code, fence_lang = False, None
            else:
                in_code, fence_lang = True, m.group(1)
            continue

        if in_code:
            # 只比 shell 命令。无语言标记的块是目录树之类的散文，逐字比没意义。
            if fence_lang == "bash":
                cmd = normalize_command(line)
                if cmd:
                    commands.append(cmd)
            continue

        if m := HEADING.match(line):
            headings.append(len(m.group(1)))

        stripped = line.lstrip()
        is_table_row = stripped.startswith("|")
        found = [n.replace(",", "") for n in NUMBER.findall(URL.sub(" ", line))]

        if is_table_row:
            if current_table is None:
                current_table = []
            current_table.append(line.count("|"))
            table_numbers.extend(found)          # 表格里连个位数一起比
        else:
            if current_table is not None:
                tables.append(tuple(current_table))
                current_table = None
            # 正文只比多位数 / 小数，避开 "one hour" vs "1 小时" 的假阳性
            prose_numbers.extend(n for n in found if len(n) > 1 or "." in n)

    if current_table is not None:
        tables.append(tuple(current_table))
    if in_code:
        commands.append("<未闭合的代码围栏>")

    return {
        "headings": headings,
        "commands": commands,
        "tables": tables,
        "table_numbers": sorted(table_numbers),
        "prose_numbers": sorted(prose_numbers),
        "urls": sorted(URL.findall(text)),
    }


def diff_multiset(label, a, b):
    """按多重集比较，只打印真正的差集。"""
    ca, cb = Counter(a), Counter(b)
    only_a, only_b = ca - cb, cb - ca
    if not only_a and not only_b:
        print(f"✓ {label}")
        return False
    print(f"✗ {label}")
    if only_a:
        print(f"    只在 {EN}: " + ", ".join(f"{k}×{v}" for k, v in sorted(only_a.items())))
    if only_b:
        print(f"    只在 {ZH}: " + ", ".join(f"{k}×{v}" for k, v in sorted(only_b.items())))
    return True


def diff_sequence(label, a, b, render=str):
    if a == b:
        print(f"✓ {label}")
        return False
    print(f"✗ {label}")
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            print(f"    第 {i + 1} 处起分歧：{EN} = {render(x)}，{ZH} = {render(y)}")
            break
    if len(a) != len(b):
        print(f"    数量不同：{EN} {len(a)} 个，{ZH} {len(b)} 个")
    return True


def main():
    paths = [ROOT / EN, ROOT / ZH]
    for p in paths:
        if not p.exists():
            print(f"✗ 找不到 {p.name}")
            return 1

    en, zh = (parse(p) for p in paths)
    print(f"{EN} ↔ {ZH}\n")

    failed = False
    failed |= diff_sequence("标题层级序列一致", en["headings"], zh["headings"],
                            render=lambda n: "#" * n)
    failed |= diff_sequence("shell 命令一致（已忽略注释）", en["commands"], zh["commands"],
                            render=repr)
    failed |= diff_sequence("表格形状一致", en["tables"], zh["tables"])
    failed |= diff_multiset("表格数字一致", en["table_numbers"], zh["table_numbers"])
    failed |= diff_multiset("正文多位数一致", en["prose_numbers"], zh["prose_numbers"])
    failed |= diff_multiset("引用链接一致", en["urls"], zh["urls"])

    if failed:
        print(f"\n两份 README 已经不同步。改了一份就要同步另一份 —— "
              f"尤其是命令、参数和实测数字。")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
