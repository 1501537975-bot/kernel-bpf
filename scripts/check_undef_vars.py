#!/usr/bin/env python3
"""
静态检查 shell 脚本里的 set -u 隐患: 引用了可能未定义的变量。

背景 (第 32 轮教训):
    fetch_erofs.sh 用了 "set -euo pipefail", 其中:
      - 走"仓库预置"分支时 TMP 从未被赋值 -> "$TMP/mt/..." 触发 unbound variable
      - 变量名拼错 (EROFS_SRC vs ERDFS_SRC) -> 同样 unbound variable
    结果脚本在中途退出, 后面的 fs/Makefile / fs/Kconfig 注册**没执行**,
    而 build.sh 只 warn 一句就继续 -> CONFIG_EROFS_FS 被 syncconfig 丢掉,
    白跑一整轮编译。

检测方法:
    1. 收集所有 "VAR=" 形式的赋值 (含 export/local/declare)
    2. 收集所有 "$VAR" / "${VAR}" 的引用
    3. 引用了但从未赋值、且不是内置特殊变量(且没有同名的 set -u 保护) -> 报告

用法:
  python3 check_undef_vars.py <script.sh> [...]
"""
import re
import sys

# shell 内置/环境变量, 不算隐患
BUILTIN = {
    "HOME", "PATH", "PWD", "OLDPWD", "USER", "SHELL", "LANG", "TERM",
    "TMPDIR", "TMP", "TEMP", "IFS", "PS1", "PS2", "PS3", "PS4",
    "BASH", "BASH_SOURCE", "BASH_VERSION", "RANDOM", "SECONDS", "LINENO",
    "PIPESTATUS", "REPLY", "OPTARG", "OPTIND", "HOSTNAME", "OSTYPE",
    "MACHTYPE", "HOSTTYPE", "UID", "EUID", "PPID", "SHLVL", "COLUMNS",
    "LINES", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "_", "FUNCNAME", "SRCDIR", "MAKEFLAGS", "MAKELEVEL", "CURDIR",
    "GOPATH", "GOMODCACHE", "http_proxy", "https_proxy", "HTTP_PROXY",
    "HTTPS_PROXY", "no_proxy", "NO_PROXY", "LANG", "LC_ALL",
}


def check(path):
    issues = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = text.splitlines()

    # 收集赋值: VAR=  /  export VAR=  /  local VAR=  /  declare VAR=
    assigned = set()
    for ln in lines:
        s = ln.strip()
        # 去掉行首的 export/local/readonly/declare/typeset
        s2 = re.sub(r"^(export|local|readonly|declare|typeset)\s+", "", s)
        # 匹配  VAR= 或 VAR+= 等
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*(\+?=|=[^=])", s2)
        if m:
            assigned.add(m.group(1))
        # for VAR in ...
        m2 = re.match(r"for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b", s)
        if m2:
            assigned.add(m2.group(1))
        # read VAR
        m3 = re.search(r"\bread\s+(?:-[a-zA-Z]+\s+)*([A-Za-z_][A-Za-z0-9_]*)", s)
        if m3:
            assigned.add(m3.group(1))
        # 数组声明: VAR=(...)
        m4 = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\(", s2)
        if m4:
            assigned.add(m4.group(1))
        # while read VAR
        m5 = re.search(r"\bread\s+(?:-[a-zA-Z]+\s+)*([A-Za-z_][A-Za-z0-9_]*)", s)
        if m5:
            assigned.add(m5.group(1))

    # 收集引用
    seen = set()
    for i, ln in enumerate(lines, 1):
        s = ln.strip()
        if s.startswith("#"):
            continue
        # ${VAR} 和 $VAR
        for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)([:}][^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)", s):
            var = m.group(1) or m.group(3)
            if var in BUILTIN or var in assigned:
                continue
            # ${VAR:+...} / ${VAR:-...} 有默认值 -> 安全
            if m.group(2) and m.group(2).startswith((":", "+", "-")):
                continue
            # 已经有 ? : 保护的行
            if re.search(r"\$\{%s[?:]" % re.escape(var), s):
                continue
            key = (i, var)
            if key in seen:
                continue
            seen.add(key)
            issues.append((i, var, s[:100]))

    return issues


def main():
    total = 0
    for path in sys.argv[1:]:
        issues = check(path)
        if not issues:
            print("OK  %s — 未发现未定义变量引用" % path)
            continue
        print("!!  %s — %d 处可能未定义" % (path, len(issues)))
        for ln, var, text in issues:
            print("     行 %-5d $%-18s %s" % (ln, var, text))
        total += len(issues)
    print()
    print("合计 %d 处" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
