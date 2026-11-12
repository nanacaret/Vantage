#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# -*- coding: utf-8 -*-
"""正确的 Swift 字符串字面量扫描器。

与正则 `"(?:\\.|[^"\\])*"` 的关键区别：能处理
    "前缀 \\(expr ?? "默认") 后缀"
这类**插值表达式里嵌套双引号**的情况 —— 上一轮正是用正则在这里截断，
把源码改成了语法错误。

scan(text) 返回 [(start, end, raw)]，raw 含首尾引号；同时报告未闭合错误。
"""
from dataclasses import dataclass

@dataclass
class Lit:
    start: int
    end: int          # 不含结束引号的位置（end 指向结束引号）
    raw: str
    def body(self) -> str:
        return self.raw[1:-1]


def scan(text: str):
    """返回 (literals, errors)。errors 里是 (pos, msg)。"""
    lits, errors = [], []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i+1] == '/':
            j = text.find('\n', i)
            i = n if j < 0 else j + 1
            continue
        if c == '/' and i + 1 < n and text[i+1] == '*':
            j = text.find('*/', i+2)
            i = n if j < 0 else j + 2
            continue
        if c == '"':
            # 多行字符串 """ 不在本项目里出现，保险起见也跳过
            if text.startswith('"""', i):
                j = text.find('"""', i+3)
                if j < 0:
                    errors.append((i, '未闭合的多行字符串')); break
                lits.append(Lit(i, j+2, text[i:j+3])); i = j+3; continue
            start = i
            i += 1
            interp_depth = 0     # 当前是不是在 \(...) 里
            paren_stack = []     # 插值内的括号深度
            while i < n:
                ch = text[i]
                if ch == '\\':
                    if i + 1 >= n: break
                    nxt = text[i+1]
                    if nxt == '(' and interp_depth == 0:
                        interp_depth = 1
                        paren_stack = [1]
                        i += 2
                        continue
                    if nxt == '(' and interp_depth:
                        paren_stack.append(1)
                        i += 2
                        continue
                    i += 2
                    continue
                if interp_depth:
                    # 插值表达式内部：可以出现新的字符串字面量，递归扫描
                    if ch == '"':
                        sub_start = i
                        j = i + 1
                        while j < n:
                            if text[j] == '\\': j += 2; continue
                            if text[j] == '"': break
                            if text[j] == '(' and j > 0 and text[j-1] == '\\':
                                # 嵌套插值，交给外层粗略跳过
                                pass
                            j += 1
                        # 子字符串里的 \( 也会带引号，简单起见按上面循环处理
                        i = j + 1
                        continue
                    if ch == '(':
                        paren_stack.append(1)
                    elif ch == ')':
                        if paren_stack: paren_stack.pop()
                        if not paren_stack:
                            interp_depth = 0
                    i += 1
                    continue
                if ch == '"':
                    lits.append(Lit(start, i, text[start:i+1]))
                    i += 1
                    break
                i += 1
            else:
                errors.append((start, '未闭合的字符串字面量'))
            continue
        i += 1
    return lits, errors


def find_L_args(text: str):
    """找出所有 L("...") 调用，返回 (lit, arg_start, arg_end) 列表。

    用扫描器拿到字符串字面量，再看它前面是不是 L(，后面是不是 )。
    """
    lits, errors = scan(text)
    out = []
    for lit in lits:
        # 向前找 L(，允许空白
        j = lit.start - 1
        while j >= 0 and text[j] in ' \t\n': j -= 1
        if j >= 1 and text[j] == '(' and text[j-1] == 'L':
            # 确认 L 前面不是标识符字符（避免匹配 fooL）
            if j-2 >= 0 and (text[j-2].isalnum() or text[j-2] == '_'):
                continue
            k = lit.end + 1
            while k < len(text) and text[k] in ' \t\n': k += 1
            if k < len(text) and text[k] == ')':
                out.append((lit, lit.start, lit.end + 1, k))
    return out, errors


if __name__ == '__main__':
    import sys, pathlib
    for p in sorted(pathlib.Path(sys.argv[1]).glob('*.swift')):
        t = p.read_text()
        lits, errs = scan(t)
        args, _ = find_L_args(t)
        print(f'{p.name:40s} 字符串 {len(lits):4d}  L() {len(args):3d}  错误 {len(errs)}')
        for e in errs[:5]: print('    !!', e)
