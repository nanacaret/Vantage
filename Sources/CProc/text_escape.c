// SPDX-License-Identifier: MIT
//
// 「Tab 分列、换行分行」这种传输格式的字段值转义（proc_detail.c / ioreg.c 共用）
//
// 背景：文件名、argv、环境变量、窗口标题、驱动属性值里都可能出现 Tab / 换行
// （APFS 除 NUL 与 '/' 之外几乎所有字节都合法），直接透传会让一行多切一列、
// 或让一行变成两行。所以要把**字段值**里的控制字符换成可见字形，而格式串里
// 的字面 '\t' 必须原样保留。
//
// 难点：整行已经 vsnprintf 出来，数据里的 Tab 与分隔 Tab 早已混在一起。
//
// 解法（利用前缀的重合性）：格式串里「到第 k 个 tab 为止」这段前缀单独格式化
// 一次量出长度 L，前缀的输出必定也是整行输出的前缀，所以该分隔符在整行里的
// 下标就是 L-1 —— 字段值里夹带的 Tab 一并算进了长度，定位依然准确。
//
// 字形用 Unicode Control Pictures（0x09→U+2409 ␉，0x0A→U+240A ␊，0x7F→U+2421），
// 不用 ls -b 那种 `\t` 文本：后者在真实文件名里并不罕见，会和真 Tab 混淆。

#include "cproc_internal.h"

#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* 控制字符 → Control Pictures 的 UTF-8 字节。
 * U+2400..U+241F = E2 90 80..9F，U+2421（DEL）= E2 90 A1 */
static void put_picture(unsigned char c, char *out, size_t *o, size_t cap)
{
    if (*o + 3 >= cap) return;
    unsigned int third = (c == 0x7f) ? 0xA1 : (0x80u + c);
    out[*o]     = (char)0xE2;
    out[*o + 1] = (char)0x90;
    out[*o + 2] = (char)third;
    *o += 3;
}

/* 返回分隔符个数；-1 表示无法可靠定位（超长行），调用方应放弃转义 */
static int sep_offsets(const char *fmt, va_list ap, int *seps, int max)
{
    char pre[1024];
    char tmp[CPROC_ESC_MAX];
    int n = 0;
    for (const char *p = fmt; *p; p++) {
        if (*p != '\t') continue;
        size_t plen = (size_t)(p - fmt) + 1;      /* 含这个 tab */
        if (plen >= sizeof(pre) || n >= max) return -1;
        memcpy(pre, fmt, plen);
        pre[plen] = '\0';

        va_list cp;
        va_copy(cp, ap);
        int k = vsnprintf(tmp, sizeof(tmp), pre, cp);
        va_end(cp);
        if (k < 0 || (size_t)k >= sizeof(tmp) || k == 0) return -1;
        seps[n++] = k - 1;
    }
    return n;
}

/* 已知哪些下标是真分隔符时的转义 */
static void escape_fields(const char *s, const int *seps, int nsep,
                          char *out, size_t cap)
{
    size_t o = 0;
    int si = 0;
    for (size_t i = 0; s[i]; i++) {
        if (si < nsep && (int)i == seps[si]) {   /* 真分隔符：原样 */
            if (o + 1 >= cap) break;
            out[o++] = '\t';
            si++;
            continue;
        }
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c == 0x7f) {   /* 数据里夹的 Tab 也在这里变成 ␉ */
            put_picture(c, out, &o, cap);
            continue;
        }
        if (o + 1 >= cap) break;
        out[o++] = (char)c;
    }
    out[o] = '\0';
}

/* 所有 Tab 都是分隔符（数据里没夹 Tab）时的转义：只处理控制字符 */
static void escape_keep_tabs(const char *s, char *out, size_t cap)
{
    size_t o = 0;
    for (size_t i = 0; s[i]; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '\t') { if (o + 1 >= cap) break; out[o++] = '\t'; continue; }
        if (c < 0x20 || c == 0x7f) { put_picture(c, out, &o, cap); continue; }
        if (o + 1 >= cap) break;
        out[o++] = (char)c;
    }
    out[o] = '\0';
}

const char *cproc_escape_line(const char *fmt, const char *src, va_list ap,
                              char *out, size_t cap)
{
    int fmt_tabs = 0;
    for (const char *p = fmt; *p; p++)
        if (*p == '\t') fmt_tabs++;

    int tabs = 0, ctls = 0;
    for (const char *p = src; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '\t') tabs++;
        else if (c < 0x20 || c == 0x7f) ctls++;
    }

    if (!ctls && tabs == fmt_tabs) return src;        /* ① 干净行：零拷贝 */

    if (tabs == fmt_tabs) {                            /* ② 直接转义 */
        escape_keep_tabs(src, out, cap);
        return out;
    }

    int seps[CPROC_ESC_FIELD_MAX];                     /* ③ 需要定位 */
    int n = sep_offsets(fmt, ap, seps, CPROC_ESC_FIELD_MAX);
    if (n < 0) { snprintf(out, cap, "%s", src); return out; }
    escape_fields(src, seps, n, out, cap);
    return out;
}

void cproc_verify_line(const char *s)
{
#if defined(NDEBUG)
    (void)s;
#else
    /* 允许的原始控制字节只有三种：字段分隔的 Tab、双语标记的 RS / US。
     * 其它任何 C0 或 DEL 出现在成品行里，说明有数据绕过了转义 —— 那会让
     * 界面错列 / 断行，而且只有用户的怪文件名才会触发，线上极难发现。
     * 所以 Debug 下一律当场炸出来。 */
    for (const char *p = s; p && *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '\t' || c == 0x1e || c == 0x1f) continue;
        if (c < 0x20 || c == 0x7f) {
            fprintf(stderr, "CProc: 原始控制字节 0x%02X 漏进了成品行（应走 cproc_escape_line）：%s\n",
                    c, s);
            assert(0 && "raw control byte leaked into a line");
            return;
        }
    }
#endif
}
