#!/usr/bin/env python3
"""
扫描 shell 脚本里的 "set -e 静默退出" 隐患。

原理:
  在 `set -euo pipefail` 下, 任何返回非 0 的简单命令都会终止脚本。
  grep 找不到匹配时返回 1 —— 这是最常见的"本该无害"却致命的操作。

检测规则:
  1. 独立一行 (或以 ; 分隔) 的 grep / test 命令, 没有 || true / || 兜底
  2. 命令替换 $(...) 内含 grep, 且外层没有 || true
  3. 管道 grep ... | head/cut, 管道末端没有 || true

用法:
  python3 scan_sete.py <script.sh> [...]
"""
import re
import sys


def scan(path):
    issues = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    # 任何 `|| <cmd>` 形式都是兜底 (|| true / || echo 0 / || warn ...)
    FALLBACK = r"\|\|\s*\S"

    in_heredoc = False
    heredoc_end = None

    for i, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        stripped = line.strip()

        # ── heredoc 区段跳过 ──
        # cat > xxx << 'EOF'  ... EOF
        # 这里面是写到别的文件的内容, 不是当前脚本的代码
        if in_heredoc:
            if stripped == heredoc_end:
                in_heredoc = False
                heredoc_end = None
            continue

        hm = re.search(r"<<\s*'?([A-Za-z_][A-Za-z0-9_]*)'?", stripped)
        if hm:
            in_heredoc = True
            heredoc_end = hm.group(1)
            continue

        if not stripped or stripped.startswith("#"):
            continue

        # if / elif / while / until 条件行自带容错
        cond = re.match(r"^(if|elif|while|until)\b", stripped)
        if cond:
            continue

        # 已经带兜底 -> 跳过整行
        if re.search(FALLBACK, stripped):
            continue

        # 规则 1: 独立 grep 行
        if re.match(r"^grep\b", stripped):
            issues.append((i, "独立 grep 无兜底", stripped[:110]))

        # 规则 2: 命令替换内含 grep 且内部无兜底
        for cm in re.finditer(r"\$\(([^)]*)\)", stripped):
            inner = cm.group(1)
            if re.search(r"\bgrep\b", inner) and not re.search(FALLBACK, inner):
                issues.append((i, "命令替换内 grep 无兜底", stripped[:110]))

        # 规则 3: grep 管道 (整行无兜底)
        if re.search(r"\bgrep\b[^|]*\|", stripped):
            issues.append((i, "grep 管道无兜底", stripped[:110]))

        # 规则 4: 独立 test/[ 行 —— test 失败同样会杀掉脚本
        # ★ 特别注意 `[ -z "$x" ] && y="z"` 这种:
        #   当条件为假 (x 非空) 时 test 返回 1 -> 整行失败 -> set -e 退出
        if re.match(r"^\[\s", stripped):
            issues.append((i, "独立 test 无兜底", stripped[:110]))

        # 规则 5: A && B 形式 (B 是最后一条命令)
        #   A 失败时整行返回 1 -> 同样致命
        m = re.match(r"^(\w+=\S+|\w+)\s*&&\s*\S", stripped)
        if m and not re.match(r"^(if|while|until)\b", stripped):
            issues.append((i, "A && B 形式 (A 失败即致命)", stripped[:110]))

    return issues


def main():
    total = 0
    for path in sys.argv[1:]:
        issues = scan(path)
        if not issues:
            print("OK  %s — 未发现 set -e 隐患" % path)
            continue
        print("!!  %s — %d 处隐患" % (path, len(issues)))
        for ln, kind, text in issues:
            print("     行 %-5d %-22s %s" % (ln, kind, text))
        total += len(issues)
    print()
    print("合计 %d 处" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
