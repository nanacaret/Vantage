#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# -*- coding: utf-8 -*-
"""生成 C 层的双语查找表（Sources/CProc/cproc_l10n_data.c / .h）。

思路（关键：中文不再是 key，C 源码里的中文只是"中文 value 模板"）：
  1. 扫描 proc_detail.c / perf.c 的所有字符串字面量（合并相邻的拼接）；
  2. 每个含中文的**字段**（按 \t 拆）查 CFIELD 得到英文字段；
     CFIELD 来自 l10n_master.py 的精确匹配 + c_en_override.py 的手工译文；
  3. 由此把每个含中文的**整行格式串**自动合成英文格式串 CFMT
     （printf 占位符数量/顺序必须一致，否则报错）；
  4. 输出到 C 表，运行时 lb_add/lb_addf/diag_add/APPEND 查表。

C 层最终输出的每个含中文字段形如：
    \x1eL:<key>\x1f<zh-field>\x1f<en-field>
Swift 侧只按当前语言取其中一份，零文本猜测、零短语残留。
"""
import re, sys, json, hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from l10n_master import MASTER, PHRASES          # noqa: E402
from c_en_override import C_EN_OVERRIDE          # noqa: E402

ROOT = HERE.parents[0]
CSRC = ROOT / 'Sources' / 'CProc'
ZH = re.compile(r'[\u4e00-\u9fff]')
PRINTF = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+|\.\*)?(?:hh|h|ll|l|L|q|j|z|t)?[diouxXeEfFgGaAcspn%]')

# ---------------------------------------------------------------- 扫描 C 源码
def strip_comments(src: str) -> str:
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)

def c_literals(src: str):
    """返回 (合并后的文本, [原始片段]) —— 保留片段便于逐段翻译拼接长提示。"""
    src = strip_comments(src)
    lits = [(m.start(), m.end(), m.group(1))
            for m in re.finditer(r'"((?:\\.|[^"\\])*)"', src)]
    out = []
    i = 0
    while i < len(lits):
        s, e, text = lits[i]
        parts = [text]
        j = i + 1
        while j < len(lits) and re.fullmatch(r'\s*', src[e:lits[j][0]], flags=re.S):
            parts.append(lits[j][2])
            text += lits[j][2]
            e = lits[j][1]
            j += 1
        out.append((text, parts))
        i = j
    return out

# 未拼接的原始字面量（用于字段级：C 源码里长提示常拆成多段拼接，
# override 里按段翻译更自然）；拼接后的整行（用于整行格式串）。
def c_raw_literals(src: str):
    src = strip_comments(src)
    return [m.group(1) for m in re.finditer(r'"((?:\\.|[^"\\])*)"', src)]

all_zh_lines = set()          # 合并后的整行格式串
all_zh_raw = set()            # 未拼接的原始片段
merged_parts = {}             # 合并文本 -> 片段列表
for name in ('proc_detail.c', 'perf.c'):
    src = (CSRC / name).read_text()
    for lit, parts in c_literals(src):
        if ZH.search(lit):
            all_zh_lines.add(lit)
            merged_parts[lit] = parts
    for lit in c_raw_literals(src):
        if ZH.search(lit):
            all_zh_raw.add(lit)

# ---------------------------------------------------------------- CFIELD
# 精确匹配的中文 → 英文：先短语表，再 Swift 主表（后者优先）
auto = dict(PHRASES)
auto.update({v[0]: v[1] for v in MASTER.values()})
# 手工译文覆盖自动结果
field_map = dict(auto)
field_map.update(C_EN_OVERRIDE)

# 拼接长提示（如 lb_hint 的 msg）按片段逐段翻译后合成整句英文；
# 同时把合成结果按 \t 拆回，回填那些「由多段拼成的新字段」。
for line, parts in merged_parts.items():
    if len(parts) <= 1 or not ZH.search(line):
        continue
    en_parts = ['\\t'.join(field_map.get(f, f) for f in p.split('\\t'))
                for p in parts]
    en = ''.join(en_parts)
    if ZH.search(en):
        continue
    if line not in field_map:
        field_map[line] = en
    zf, ef = line.split('\\t'), en.split('\\t')
    if len(zf) == len(ef):
        for z, e in zip(zf, ef):
            if ZH.search(z) and z not in field_map:
                field_map[z] = e

# 带 \t 列前缀的拼接片段（如 lb_hint 多列提示的第一段）也按字段合成英文，
# 保证「C 源码里每个含中文字面量都在表里」这一校验 100% 通过。
for lit in all_zh_raw:
    en_line = '\\t'.join(field_map.get(f, f) for f in lit.split('\\t'))
    if not ZH.search(en_line) and lit not in field_map:
        field_map[lit] = en_line

fields = set()
for line in (all_zh_lines | all_zh_raw):
    for f in line.split('\\t'):
        if ZH.search(f):
            fields.add(f)
    # 整句本身也作为一个可精确命中的条目（提示 / 诊断段落 / 拼接片段）
    if ZH.search(line):
        fields.add(line)

missing = [f for f in sorted(fields) if f not in field_map or ZH.search(field_map[f])]
if missing:
    print('!! 以下 C 字段缺英文或英文仍含中文:')
    for f in missing[:40]:
        print('   ', repr(f[:95]), '->', repr(field_map.get(f, '<缺失>')[:60]))
    raise SystemExit(1)

# 校验 printf 占位符（字段级）
fmt_bad = []
for f, e in field_map.items():
    if ZH.search(f) and PRINTF.findall(f) != PRINTF.findall(e):
        fmt_bad.append((f, PRINTF.findall(f), PRINTF.findall(e)))
if fmt_bad:
    print('!! 字段级 printf 占位符不一致:')
    for f, a, b in fmt_bad[:30]:
        print('   ', repr(f[:70]), a, b)
    raise SystemExit(1)

# ---------------------------------------------------------------- CFMT（整行）
def line_en(line: str) -> str:
    out = []
    for f in line.split('\\t'):
        out.append(field_map.get(f, f))
    return '\\t'.join(out)

fmt_map = {}
for line in sorted(all_zh_lines):
    en = line_en(line)
    a, b = PRINTF.findall(line), PRINTF.findall(en)
    if a != b:
        print('!! 整行 printf 占位符不一致:')
        print('   ZH', repr(line[:100]), a)
        print('   EN', repr(en[:100]), b)
        raise SystemExit(1)
    fmt_map[line] = en

# ---------------------------------------------------------------- key
def slug(en: str) -> str:
    words = re.findall(r'[A-Za-z][A-Za-z0-9]*', en)
    if not words: return 'item'
    s = words[0][0].lower() + words[0][1:]
    s += ''.join(w[0].upper() + w[1:].lower() for w in words[1:4])
    return re.sub(r'[^A-Za-z0-9]', '', s)[:36] or 'item'

used = set()
def make_key(scope: str, en: str) -> str:
    base = f'c.{scope}.{slug(en)}'
    k, i = base, 2
    while k in used:
        k = f'{base}{i}'; i += 1
    used.add(k)
    return k

field_keys = {f: make_key('f', field_map[f]) for f in sorted(fields)}
fmt_keys = {f: make_key('r', fmt_map[f]) for f in sorted(fmt_map)}

# ---------------------------------------------------------------- 输出 C
def c_str(s: str) -> str:
    """s 是源码文本（\t / \n 为两字符转义），写成 C 字符串字面量内容"""
    return s.replace('"', '\\"')

def c_line(a: str, b: str, k: str) -> str:
    return f'    {{ "{c_str(a)}", "{c_str(b)}", "{k}" }},\n'

hdr = '''/* SPDX-License-Identifier: MIT */
#ifndef CPROC_L10N_DATA_H
#define CPROC_L10N_DATA_H
#include <stddef.h>
/* 由 Tools/build_c_l10n.py 生成，请勿手工编辑。
 * C 层运行时文本的语义 key + 双语值。中文是 value，不是 key。 */
#ifdef __cplusplus
extern "C" {
#endif
/* 整行格式串（含 printf 占位符）→ 英文格式串；未命中返回 NULL */
const char *cproc_l10n_en_fmt(const char *zh_fmt);
/* 单个字段的中文文本 → 英文；未命中返回 NULL */
const char *cproc_l10n_en_field(const char *zh_field);
/* 字段 / 格式串对应的稳定语义 key；未命中返回 NULL */
const char *cproc_l10n_key_fmt(const char *zh_fmt);
const char *cproc_l10n_key_field(const char *zh_field);
/* 对一段已格式化文本里的中文短词（作为 %s 参数传入的）做精确替换。
 * 用于整段诊断文本：格式串已翻译，但参数本身是中文固定短词。 */
void cproc_l10n_inline_en(char *buf, size_t cap);
#ifdef __cplusplus
}
#endif
#endif
'''
# 头文件放在 C target 的**私有目录**（Sources/CProc/ 根），不放 include/。
# CProc 的 publicHeadersPath = "include"，放在那里会被 SwiftPM 当公开头，
# 而 CProc.h 作为 umbrella 没包含它 → "umbrella header ... does not include
# header 'cproc_l10n_data.h'" 警告。这张表只给 C 内部用，Swift 侧只解析
# 字符串标记，不需要导出。
#
# 同时清理历史版本留在 include/ 下的旧文件：用户解压覆盖时旧文件不会
# 自动消失，不清就还会触发同一条警告。
(CSRC / 'cproc_l10n_data.h').write_text(hdr)
legacy = CSRC / 'include' / 'cproc_l10n_data.h'
if legacy.exists():
    legacy.unlink()

body = ['/* SPDX-License-Identifier: MIT */\n',
        '/* Generated by Tools/build_c_l10n.py — edit Tools/c_en_override.py instead. */\n',
        '#include "cproc_l10n_data.h"\n', '#include <string.h>\n\n',
        'typedef struct { const char *zh; const char *en; const char *key; } c_l10n_ent_t;\n\n',
        'static const c_l10n_ent_t kFmt[] = {\n']
for f in sorted(fmt_map):
    body.append(c_line(f, fmt_map[f], fmt_keys[f]))
body += ['};\n\n', 'static const c_l10n_ent_t kField[] = {\n']
for f in sorted(fields):
    body.append(c_line(f, field_map[f], field_keys[f]))
body += ['};\n\n']

# 短词内联表：无 printf 占位、无 \t / \n、长度短的中文短语。
# 按长度降序，先替换长词再替换短词，避免「不可用」被「不可」截断。
# 次级键用字符串本身：Python 的 set 迭代顺序受 hash 随机化影响，
# 只按长度排序会让同长度短语每次生成顺序不同，导致 `git diff` 凭空出现。
# 加上次级键后，重复运行 Tools/build_l10n.py 的输出完全确定（可复现构建）。
inline = sorted((f for f in fields
                 if '%' not in f and '\\t' not in f and '\\n' not in f
                 and len(f) <= 12 and field_map[f] != f),
                key=lambda x: (-len(x), x))
body.append('static const c_l10n_ent_t kInline[] = {\n')
for f in inline:
    body.append(c_line(f, field_map[f], field_keys[f]))
body.append('};\n\n')
for fn, arr in (('fmt', 'kFmt'), ('field', 'kField')):
    body.append(f'''static const c_l10n_ent_t *find_{fn}(const char *zh) {{
    if (!zh || !*zh) return NULL;
    for (size_t i = 0; i < sizeof({arr}) / sizeof({arr}[0]); i++)
        if (strcmp({arr}[i].zh, zh) == 0) return &{arr}[i];
    return NULL;
}}

''')
body += ['''const char *cproc_l10n_en_fmt(const char *zh_fmt) {
    const c_l10n_ent_t *e = find_fmt(zh_fmt);
    return e ? e->en : NULL;
}
const char *cproc_l10n_en_field(const char *zh_field) {
    const c_l10n_ent_t *e = find_field(zh_field);
    return e ? e->en : NULL;
}
const char *cproc_l10n_key_fmt(const char *zh_fmt) {
    const c_l10n_ent_t *e = find_fmt(zh_fmt);
    return e ? e->key : NULL;
}
const char *cproc_l10n_key_field(const char *zh_field) {
    const c_l10n_ent_t *e = find_field(zh_field);
    return e ? e->key : NULL;
}

/* 对 buf 做一次短词精确替换（只替换 kInline 里的完整短语）。
 * buf 是 NUL 结尾的普通文本，cap 是缓冲区总容量。 */
void cproc_l10n_inline_en(char *buf, size_t cap) {
    if (!buf || !cap) return;
    size_t len = strlen(buf);
    for (size_t i = 0; i < sizeof(kInline) / sizeof(kInline[0]); i++) {
        const char *zh = kInline[i].zh, *en = kInline[i].en;
        size_t zl = strlen(zh), el = strlen(en);
        if (!zl || strcmp(zh, en) == 0) continue;
        char *p = buf;
        while ((p = strstr(p, zh)) != NULL) {
            if (el <= zl) {
                memcpy(p, en, el);
                if (el < zl) memmove(p + el, p + zl, strlen(p + zl) + 1);
                len -= zl - el;
                p += el;
            } else {
                /* 英文更长：只在容量足够时替换 */
                size_t tail = strlen(p + zl) + 1;
                if (len + (el - zl) + 1 >= cap) break;
                memmove(p + el, p + zl, tail);
                memcpy(p, en, el);
                len += el - zl;
                p += el;
            }
        }
    }
    buf[len < cap ? len : cap - 1] = '\\0';
}
''']
(CSRC / 'cproc_l10n_data.c').write_text(''.join(body))

# ---------------------------------------------------------------- 写回主表（集中管理）
# C 文案以 c.* key 进 MASTER，便于统一校验「所有 key 都有中英值」
extra = {}
for f in sorted(fields):
    extra[field_keys[f]] = (f, field_map[f])
# 这个 JSON 只是调试用的副产物（生成器不读它），已列入 .gitignore。
# sort_keys 保证即使保留在本地，重复运行也不会出现无意义的 diff。
(HERE / 'c_l10n_generated.json').write_text(
    json.dumps({'fmt': {fmt_keys[k]: [k, v] for k, v in fmt_map.items()},
                'field': {field_keys[k]: [k, field_map[k]] for k in fields},
                'extra_master': extra},
               ensure_ascii=False, indent=1, sort_keys=True) + '\n')

print(f'✓ C 双语表：整行格式串 {len(fmt_map)} 条 / 字段 {len(fields)} 条 / '
      f'手工译文 {len(C_EN_OVERRIDE)} 条 / printf 校验通过')
