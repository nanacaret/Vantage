/* SPDX-License-Identifier: MIT */
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
