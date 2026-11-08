#!/usr/bin/env python3
"""
修正 MTK 头文件里多余的 "extern inline" 声明 (GCC 5+ 严格 C99 inline 语义)。

问题:
  MTK 为了 EXPORT_SYMBOL 导出, 头文件里写成:
    include/linux/keyslot-manager.h : extern inline void ksm_flock(...);
    block/keyslot-manager.c         : inline void ksm_flock(...) { ... }
  clang 容忍; GCC 5+ 会尝试内联但找不到函数体:
    error: inlining failed in call to 'always_inline' 'ksm_flock':
           function body not available

做法 (只删关键字, 不重排任何其他字符, 绝不动参数列表):
  1. 扫所有 .h, 找出 "extern inline <type> <name>(" 声明
  2. 在 .c 里定位该 name 的定义:
     - 定义是普通函数 (type name(...) {)  -> 头文件 "extern inline" -> "extern"
     - 定义是 inline 函数 (inline type name(...) {) -> 头文件改 "extern",
       同时 .c 的 "inline " 关键字删掉 (让 C99 语义下也生成符号)
  3. 找不到定义的 -> 不动 (可能是真正的 inline)

★ 安全约束: 所有替换都只删除 "extern inline " / "inline " 这几个词本身,
  其余字节原样保留, 绝不重建参数列表。

用法: python3 fix_extern_inline.py <内核树根目录>
"""
import os
import re
import sys


def walk(root):
    hdrs, srcs = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != '.git']
        rel = os.path.relpath(dirpath, root)
        if rel.split(os.sep)[0] in ('Documentation', 'tools/testing'):
            continue
        for f in filenames:
            p = os.path.join(dirpath, f)
            if f.endswith('.h'):
                hdrs.append(p)
            elif f.endswith('.c'):
                srcs.append(p)
    return hdrs, srcs


def main():
    if len(sys.argv) < 2:
        print("用法: fix_extern_inline.py <内核树根目录>", file=sys.stderr)
        return 2
    root = os.path.abspath(sys.argv[1])
    hdrs, srcs = walk(root)
    print(f"扫描 {len(hdrs)} 个头文件, {len(srcs)} 个源文件")

    # 1. 收集头文件里的 extern inline 声明
    decl = {}     # name -> [头文件]
    order = []
    for h in hdrs:
        try:
            txt = open(h, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        if 'extern inline' not in txt:
            continue
        for m in re.finditer(r'\bextern\s+inline\s+((?:[A-Za-z_][A-Za-z0-9_]*\s+)*?\*?\s*)([A-Za-z_][A-Za-z0-9_]*)\s*\(', txt):
            name = m.group(2)
            if name not in decl:
                decl[name] = []
                order.append(name)
            decl[name].append(h)
    if not decl:
        print("没有 extern inline 声明, 无需修正")
        return 0
    print(f"找到 {len(order)} 个 extern inline 声明的函数")

    # 2. 在 .c 里定位定义
    kind = {}     # name -> 'plain' | 'inline'
    where = {}    # name -> .c 路径
    for c in srcs:
        try:
            txt = open(c, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        for name in order:
            if name in kind:
                continue
            # inline 定义: 行首 inline 后接 type name(
            mi = re.search(r'(?m)^([ \t]*)inline\s+((?:[A-Za-z_][A-Za-z0-9_]*\s+)*?\*?\s*)'
                           + re.escape(name) + r'\s*\(', txt)
            if mi:
                kind[name] = 'inline'
                where[name] = c
                continue
            # 普通定义: 行首非 inline/extern 的 type name(
            mp = re.search(r'(?m)^[ \t]*((?:[A-Za-z_][A-Za-z0-9_]*\s+)+?\*?\s*)'
                           + re.escape(name) + r'\s*\([^;]*?\)\s*\{', txt)
            if mp:
                kind[name] = 'plain'
                where[name] = c

    plain = [n for n in order if kind.get(n) == 'plain']
    inl = [n for n in order if kind.get(n) == 'inline']
    unknown = [n for n in order if n not in kind]
    print(f"  普通函数定义 ({len(plain)}): {', '.join(plain[:6])}")
    print(f"  inline 定义     ({len(inl)}): {', '.join(inl[:6])}")
    print(f"  未找到定义     ({len(unknown)}): {', '.join(unknown[:6])}")

    # 3. 改头文件: "extern inline " -> "extern "  (只删 "inline " 这个词)
    fixed_h = 0
    for name in order:
        if kind.get(name) not in ('plain', 'inline'):
            continue
        for h in decl[name]:
            try:
                txt = open(h, encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            # 只在 "extern inline <type> name(" 这个具体形态上替换
            pat = re.compile(r'\bextern\s+inline\s+((?:[A-Za-z_][A-Za-z0-9_]*\s+)*?\*?\s*)'
                             + re.escape(name) + r'\s*\(')
            new, n = pat.subn(r'extern \1' + name + '(', txt)
            if n:
                open(h, 'w', encoding='utf-8', newline='').write(new)
                fixed_h += n
                print(f"  [头] {os.path.relpath(h, root)}: extern inline -> extern  ({name}) x{n}")

    # 4. 改 .c: inline 定义 -> 普通定义 (只删行首的 "inline " 词)
    fixed_c = 0
    for name in inl:
        c = where.get(name)
        if not c:
            continue
        try:
            txt = open(c, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        pat = re.compile(r'(?m)^([ \t]*)inline\s+((?:[A-Za-z_][A-Za-z0-9_]*\s+)*?\*?\s*)'
                        + re.escape(name) + r'(\s*\()')
        new, n = pat.subn(r'\1\2' + name + r'\3', txt)
        if n:
            open(c, 'w', encoding='utf-8', newline='').write(new)
            fixed_c += n
            print(f"  [源] {os.path.relpath(c, root)}: inline -> 普通定义  ({name}) x{n}")

    print(f"\n完成: 头文件 {fixed_h} 处, 源文件 {fixed_c} 处")
    return 0


if __name__ == "__main__":
    sys.exit(main())
