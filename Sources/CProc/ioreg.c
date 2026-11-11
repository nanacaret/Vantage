/* SPDX-License-Identifier: MIT */
#include "CProc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>
#include <dlfcn.h>
#include <mach/mach.h>

#include <IOKit/IOKitLib.h>
#include <IOKit/IOKitKeys.h>
#include <CoreFoundation/CoreFoundation.h>

/*
 * IORegistry 设备树采集（纯公开 IOKit API，不需要 root、不需要 task port）
 *
 * 输出约定：所有行都是 ASCII 结构化数据，字段用 '\t' 分隔，Swift 侧按列
 * 渲染并用 L() 生成所有 UI 文案。这里刻意**不写任何中文**，避免与
 * cproc_l10n_data 的「中文是 value」机制耦合：设备名 / 属性值本身可能含
 * 中文，那是数据，不是界面文案。
 *
 *   META\t<nodeCount>\t<truncated 0|1>\t<plane>
 *   NODE\t<index>\t<parentIndex>\t<depth>\t<entryID(hex)>\t<name>\t<class>\t
 *         <bundleID>\t<personalityBundleID>\t<ioClass>\t<providerClass>\t
 *         <clientPID|->\t<clientName>\t<clientSource>\t<path>
 *   PROP\t<key>\t<type>\t<value>      (cproc_ioreg_properties 的输出)
 *   PMETA\t<total>\t<truncated 0|1>
 *
 * client PID 来源：kIOUserClientCreatorKey ("IOUserClientCreator")。
 *  xnu 的 IOService::newUserClient 会把创建者写进该属性，历史上有多种形态：
 *   CFString "pid 123, WindowServer" / CFNumber / CFArray /
 *   CFData（audit_token_t，val[0] 就是 pid）。逐类型解析，拿不到就留 '-'，
 *   绝不猜。没有该属性的设备（绝大多数）本来就没有 user client。
 *
 * driver bundle 来源：节点属性里的 CFBundleIdentifier（kIOBundleIdentifierKey）
 * 或 IOPersonality 字典里的 CFBundleIdentifier / IOClass；再不济至少给出
 * IOClass / IOProviderClass，Swift 侧用「扩展列表」的 IOKitPersonalities
 * 索引反查 bundle 路径、版本与签名。这里不做私有 IOCatalogue 调用。
 */

/* kIOMainPortDefault 是 macOS 12 引入的 `const mach_port_t` **变量**，不是宏，
 * 用 #ifndef 探测会恒成立、错误退回已弃用的 kIOMasterPortDefault，触发
 * -Wdeprecated-declarations。改用 SDK 版本宏判断。部署目标是 macOS 12，
 * SDK 必然 >= 12，默认就走新符号；只有明确检测到 < 12 SDK 才回退。 */
#if defined(__has_include)
# if __has_include(<Availability.h>)
#  include <Availability.h>
# endif
#else
# include <Availability.h>
#endif

#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && \
    (__MAC_OS_X_VERSION_MAX_ALLOWED < 120000)
#define CPROC_IO_MAIN_PORT  kIOMasterPortDefault
#else
#define CPROC_IO_MAIN_PORT  kIOMainPortDefault
#endif

/* 注意：IORegistryEntryCopyFromPath 的 path 形参自 macOS 10.11 引入起就是
 * CFStringRef，和上面 12.0 的 main port 变化是两件独立的事，不能绑在同一个
 * 版本阈值上。接受 char* 的老函数叫 IORegistryEntryFromPath（没有 Copy，
 * 返回值同样需要 IOObjectRelease），两者不要混用。所有 12+ SDK 都走
 * CFStringRef，因此下面不再保留 io_string_t 分支。 */

/* 节点上限由偏好下发（默认 30000），避免超大 IORegistry 把 UI 拖死 */
static uint32_t g_max_nodes = 30000;

void cproc_ioreg_set_max_nodes(uint32_t n)
{
    if (n < 1000) n = 1000;
    if (n > 200000) n = 200000;
    g_max_nodes = n;
}

/* ------------------------------------------------------------------ */
/* 极简行容器（与 proc_detail.c 的 line_builder 独立，避免跨文件耦合）  */
/* ------------------------------------------------------------------ */

typedef struct {
    char **v;
    int    n;
    int    cap;
} ioreg_lines_t;

static int il_init(ioreg_lines_t *b)
{
    b->cap = 256;
    b->n = 0;
    b->v = calloc((size_t)b->cap, sizeof(char *));
    return b->v ? 0 : -1;
}

/* strdup 不是 ISO C，-std=c11 严格模式下可能不声明；自己实现一份 */
static char *il_strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static void il_add(ioreg_lines_t *b, const char *s)
{
    if (!s) s = "";
    if (b->n >= b->cap) {
        int nc = b->cap * 2;
        char **nv = realloc(b->v, (size_t)nc * sizeof(char *));
        if (!nv) return;
        b->v = nv;
        b->cap = nc;
    }
    b->v[b->n++] = il_strdup(s);
}

static void il_addf(ioreg_lines_t *b, const char *fmt, ...)
{
    char buf[16384];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    il_add(b, buf);
}

static int il_finish(ioreg_lines_t *b, cproc_lines_t *out)
{
    out->lines = b->v;
    out->count = b->n;
    b->v = NULL;
    b->n = b->cap = 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* 字符串清洗 / CF 类型转换                                            */
/* ------------------------------------------------------------------ */

/* tab / 换行会破坏字段分隔，全部换成空格；同时控制输出长度 */
static void sanitize(char *dst, size_t cap, const char *src)
{
    size_t o = 0;
    if (!src) src = "";
    for (const unsigned char *p = (const unsigned char *)src; *p && o + 1 < cap; p++) {
        unsigned char c = *p;
        if (c == '\t' || c == '\n' || c == '\r' || c < 0x20) c = ' ';
        dst[o++] = (char)c;
    }
    dst[o] = '\0';
}

static void cfstring_to_buf(CFStringRef s, char *buf, size_t cap)
{
    if (!s || CFGetTypeID(s) != CFStringGetTypeID()) { buf[0] = '\0'; return; }
    char tmp[16384];
    if (!CFStringGetCString(s, tmp, (CFIndex)sizeof(tmp), kCFStringEncodingUTF8))
        tmp[0] = '\0';
    sanitize(buf, cap, tmp);
}

/* 任意 CFType → 单行 UTF-8 文本（用于属性表与数组元素） */
static void cftype_to_buf(CFTypeRef v, char *buf, size_t cap,
                          const char **typeName)
{
    if (!v) { buf[0] = '\0'; if (typeName) *typeName = "null"; return; }
    CFTypeID t = CFGetTypeID(v);

    if (t == CFStringGetTypeID()) {
        if (typeName) *typeName = "string";
        cfstring_to_buf((CFStringRef)v, buf, cap);
    } else if (t == CFNumberGetTypeID()) {
        if (typeName) *typeName = "number";
        if (CFNumberIsFloatType((CFNumberRef)v)) {
            double d = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d);
            snprintf(buf, cap, "%.6g", d);
        } else {
            long long n = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n);
            snprintf(buf, cap, "0x%llx (%lld)", (unsigned long long)n, n);
        }
    } else if (t == CFBooleanGetTypeID()) {
        if (typeName) *typeName = "bool";
        snprintf(buf, cap, "%s", CFBooleanGetValue((CFBooleanRef)v) ? "true" : "false");
    } else if (t == CFDataGetTypeID()) {
        if (typeName) *typeName = "data";
        CFIndex len = CFDataGetLength((CFDataRef)v);
        const UInt8 *p = CFDataGetBytePtr((CFDataRef)v);
        size_t o = 0;
        int show = (int)(len > 24 ? 24 : len);
        o += (size_t)snprintf(buf + o, cap - o, "<%ld bytes> ", (long)len);
        for (int i = 0; i < show && o + 3 < cap; i++)
            o += (size_t)snprintf(buf + o, cap - o, "%02x", p[i]);
        if (len > 24 && o + 4 < cap) snprintf(buf + o, cap - o, "…");
    } else if (t == CFArrayGetTypeID() || t == CFDictionaryGetTypeID()) {
        if (typeName) *typeName = t == CFArrayGetTypeID() ? "array" : "dict";
        CFStringRef desc = CFCopyDescription(v);
        char tmp[16384]; tmp[0] = '\0';
        if (desc) {
            CFStringGetCString(desc, tmp, (CFIndex)sizeof(tmp), kCFStringEncodingUTF8);
            CFRelease(desc);
        }
        sanitize(buf, cap, tmp);
    } else {
        if (typeName) *typeName = "cf";
        CFStringRef desc = CFCopyDescription(v);
        char tmp[8192]; tmp[0] = '\0';
        if (desc) {
            CFStringGetCString(desc, tmp, (CFIndex)sizeof(tmp), kCFStringEncodingUTF8);
            CFRelease(desc);
        }
        sanitize(buf, cap, tmp);
    }
    buf[cap - 1] = '\0';
}

/* ------------------------------------------------------------------ */
/* 属性读取辅助                                                        */
/* ------------------------------------------------------------------ */

static CFTypeRef prop_copy(io_registry_entry_t e, const char *key)
{
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key,
                                              kCFStringEncodingUTF8);
    if (!k) return NULL;
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    return v;
}

static void prop_string(io_registry_entry_t e, const char *key,
                        char *buf, size_t cap)
{
    buf[0] = '\0';
    CFTypeRef v = prop_copy(e, key);
    if (!v) return;
    cftype_to_buf(v, buf, cap, NULL);
    CFRelease(v);
}

/* 从字典里取字符串（用于 IOPersonality） */
static void dict_string(CFDictionaryRef d, const char *key,
                        char *buf, size_t cap)
{
    buf[0] = '\0';
    if (!d) return;
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key,
                                              kCFStringEncodingUTF8);
    if (!k) return;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    if (!v) return;
    cftype_to_buf(v, buf, cap, NULL);
}

/* ------------------------------------------------------------------ */
/* IOUserClientCreator → (pid, name, source)                           */
/* ------------------------------------------------------------------ */

typedef struct {
    int32_t pid;
    char    name[256];
    char    source[32];
} client_info_t;

/* 解析 "pid 123, WindowServer" / "pid 123" / "123, name" */
static void parse_creator_string(const char *s, client_info_t *ci)
{
    if (!s || !*s) return;
    const char *p = strstr(s, "pid");
    long v = 0;
    const char *digits = NULL;
    if (p) {
        p += 3;
        while (*p == ' ' || *p == '=' || *p == ':') p++;
        if (isdigit((unsigned char)*p)) digits = p;
    }
    if (!digits) {
        /* 有些版本直接写 "123, WindowServer" */
        const char *q = s;
        while (*q == ' ') q++;
        if (isdigit((unsigned char)*q)) digits = q;
    }
    if (digits) {
        char *end = NULL;
        v = strtol(digits, &end, 10);
        if (v <= 0 || v > 999999) v = 0;
    }
    if (v > 0) {
        ci->pid = (int32_t)v;
        /* 名字取最后一个逗号 / 括号后的片段 */
        const char *comma = strrchr(s, ',');
        const char *name = comma ? comma + 1 : NULL;
        if (name) {
            while (*name == ' ' || *name == '\t') name++;
            if (*name) {
                sanitize(ci->name, sizeof(ci->name), name);
                /* 去掉可能的 ")" / " task" 尾巴 */
                char *paren = strchr(ci->name, ')');
                if (paren) *paren = '\0';
            }
        }
        if (!ci->name[0]) snprintf(ci->name, sizeof(ci->name), "pid %ld", v);
        snprintf(ci->source, sizeof(ci->source), "string");
    }
}

static void creator_from_cftype(CFTypeRef v, client_info_t *ci, int depth)
{
    if (!v || depth > 3) return;
    CFTypeID t = CFGetTypeID(v);

    if (t == CFStringGetTypeID()) {
        char s[1024]; cfstring_to_buf((CFStringRef)v, s, sizeof(s));
        parse_creator_string(s, ci);
    } else if (t == CFNumberGetTypeID()) {
        long long n = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n)
            && n > 0 && n < 1000000) {
            ci->pid = (int32_t)n;
            snprintf(ci->source, sizeof(ci->source), "number");
        }
    } else if (t == CFDataGetTypeID()) {
        /* audit_token_t: val[0] = pid（uint32） */
        CFIndex len = CFDataGetLength((CFDataRef)v);
        if (len >= 4) {
            const UInt8 *p = CFDataGetBytePtr((CFDataRef)v);
            uint32_t pid;
            memcpy(&pid, p, 4);
            if (pid > 0 && pid < 1000000) {
                ci->pid = (int32_t)pid;
                snprintf(ci->source, sizeof(ci->source), "audit");
                /* token 里没有进程名，UI 会用 PID 反查快照 */
                ci->name[0] = '\0';
            }
        }
    } else if (t == CFArrayGetTypeID()) {
        CFIndex n = CFArrayGetCount((CFArrayRef)v);
        for (CFIndex i = 0; i < n && ci->pid <= 0 && i < 16; i++)
            creator_from_cftype(CFArrayGetValueAtIndex((CFArrayRef)v, i), ci, depth + 1);
    } else if (t == CFDictionaryGetTypeID()) {
        CFStringRef pk = CFStringCreateWithCString(kCFAllocatorDefault, "pid",
                                                   kCFStringEncodingUTF8);
        if (pk) {
            CFTypeRef pv = CFDictionaryGetValue((CFDictionaryRef)v, pk);
            CFRelease(pk);
            if (pv) creator_from_cftype(pv, ci, depth + 1);
        }
        CFStringRef nk = CFStringCreateWithCString(kCFAllocatorDefault, "name",
                                                   kCFStringEncodingUTF8);
        if (nk) {
            CFTypeRef nv = CFDictionaryGetValue((CFDictionaryRef)v, nk);
            CFRelease(nk);
            if (nv && CFGetTypeID(nv) == CFStringGetTypeID() && !ci->name[0])
                cfstring_to_buf((CFStringRef)nv, ci->name, sizeof(ci->name));
        }
    }
}

static void read_client(io_registry_entry_t e, client_info_t *ci)
{
    memset(ci, 0, sizeof(*ci));
    /* kIOUserClientCreatorKey = "IOUserClientCreator" */
    CFTypeRef v = prop_copy(e, "IOUserClientCreator");
    if (!v) v = prop_copy(e, "IOUserClientCreatorPID");
    if (!v) return;
    creator_from_cftype(v, ci, 0);
    CFRelease(v);
}

/* ------------------------------------------------------------------ */
/* 节点字段                                                            */
/* ------------------------------------------------------------------ */

typedef struct {
    int      index;
    int      parent;
    int      depth;
    uint64_t entryID;
    char     name[256];
    char     cls[256];
    char     bundleID[512];
    char     persBundleID[512];
    char     ioClass[256];
    char     providerClass[256];
    int32_t  clientPID;
    char     clientName[256];
    char     clientSource[32];
    char     path[1024];
} node_t;

static void fill_node(io_registry_entry_t e, const char *plane,
                      int index, int parent, int depth, node_t *n)
{
    memset(n, 0, sizeof(*n));
    n->index = index; n->parent = parent; n->depth = depth;

    io_name_t iname; iname[0] = '\0';
    IORegistryEntryGetName(e, iname);
    sanitize(n->name, sizeof(n->name), iname);

    /* 内核 C++ 类名（如 IOService / IOUSBHostDevice / AppleSmartBattery） */
    io_name_t cname; cname[0] = '\0';
    if (IOObjectGetClass(e, cname) != KERN_SUCCESS || !cname[0])
        prop_string(e, "IOClass", cname, sizeof(cname));
    sanitize(n->cls, sizeof(n->cls), cname);

    uint64_t eid = 0;
    IORegistryEntryGetRegistryEntryID(e, &eid);
    n->entryID = eid;

    io_string_t ipath; ipath[0] = '\0';
    if (IORegistryEntryGetPath(e, plane, ipath) != KERN_SUCCESS)
        ipath[0] = '\0';
    sanitize(n->path, sizeof(n->path), ipath);

    /* driver bundle：优先节点属性，再退 IOPersonality */
    prop_string(e, "CFBundleIdentifier", n->bundleID, sizeof(n->bundleID));
    if (!n->bundleID[0])
        prop_string(e, "IOBundleIdentifier", n->bundleID, sizeof(n->bundleID));

    CFTypeRef pers = prop_copy(e, "IOPersonality");
    if (pers && CFGetTypeID(pers) == CFDictionaryGetTypeID()) {
        dict_string((CFDictionaryRef)pers, "CFBundleIdentifier",
                    n->persBundleID, sizeof(n->persBundleID));
        if (!n->ioClass[0])
            dict_string((CFDictionaryRef)pers, "IOClass",
                        n->ioClass, sizeof(n->ioClass));
        if (!n->bundleID[0] && n->persBundleID[0])
            snprintf(n->bundleID, sizeof(n->bundleID), "%s", n->persBundleID);
    }
    if (pers) CFRelease(pers);

    if (!n->ioClass[0])
        prop_string(e, "IOClass", n->ioClass, sizeof(n->ioClass));
    prop_string(e, "IOProviderClass", n->providerClass,
                sizeof(n->providerClass));

    client_info_t ci;
    read_client(e, &ci);
    n->clientPID = ci.pid;
    snprintf(n->clientName, sizeof(n->clientName), "%s", ci.name);
    snprintf(n->clientSource, sizeof(n->clientSource), "%s", ci.source);
}

/* ------------------------------------------------------------------ */
/* 树枚举：显式栈 DFS，父节点必然先于子节点输出                        */
/* ------------------------------------------------------------------ */

typedef struct {
    io_registry_entry_t entry;
    int parent;
    int depth;
} stack_item_t;

int cproc_ioreg_tree(const char *plane, cproc_lines_t *out)
{
    out->lines = NULL; out->count = 0;
    ioreg_lines_t b;
    if (il_init(&b) != 0) return -1;

    char pl[128];
    snprintf(pl, sizeof(pl), "%s", (plane && *plane) ? plane : "IOService");

    io_registry_entry_t root = IORegistryGetRootEntry(CPROC_IO_MAIN_PORT);
    if (!root) {
        il_addf(&b, "META\t0\t0\t%s", pl);
        il_add(&b, "ERROR\tIORegistryGetRootEntry failed");
        return il_finish(&b, out);
    }

    /* 栈里先放 root；用动态数组，避免 ACPIPlane 深层节点递归爆栈 */
    size_t cap = 512, n = 0;
    stack_item_t *st = calloc(cap, sizeof(stack_item_t));
    if (!st) { IOObjectRelease(root); il_addf(&b, "META\t0\t0\t%s", pl);
               return il_finish(&b, out); }
    st[n++] = (stack_item_t){ root, -1, 0 };

    node_t *nodes = NULL;
    size_t ncap = 0, nn = 0;
    uint32_t limit = g_max_nodes;
    int truncated = 0;
    /* 深度用固定 64 保护（ACPI / USB 树最多十几层），不再读进程层 limits */

    while (n > 0) {
        stack_item_t it = st[--n];
        io_registry_entry_t e = it.entry;

        if (nn >= limit) { truncated = 1; IOObjectRelease(e); break; }
        /* 详情采集的 epoch 取消标记，切换 plane / 刷新时立刻退出 */
        if ((nn & 63) == 0 && cproc_detail_aborted()) {
            truncated = 1; IOObjectRelease(e); break;
        }

        if (nn >= ncap) {
            size_t nc = ncap ? ncap * 2 : 1024;
            node_t *nv = realloc(nodes, nc * sizeof(node_t));
            if (!nv) { truncated = 1; IOObjectRelease(e); break; }
            nodes = nv; ncap = nc;
        }

        int idx = (int)nn;
        fill_node(e, pl, idx, it.parent, it.depth, &nodes[nn]);
        nn++;

        /* 子节点压栈（倒序入栈，出栈即原顺序） */
        io_iterator_t child = 0;
        if (it.depth < 64 &&
            IORegistryEntryGetChildIterator(e, pl, &child) == KERN_SUCCESS) {
            io_registry_entry_t kids[256];
            int k = 0;
            io_object_t o;
            while ((o = IOIteratorNext(child)) && k < 256) kids[k++] = o;
            IOObjectRelease(child);
            if (n + (size_t)k + 8 > cap) {
                size_t nc = (n + (size_t)k + 8) * 2;
                stack_item_t *ns = realloc(st, nc * sizeof(stack_item_t));
                if (!ns) { truncated = 1; break; }
                st = ns; cap = nc;
            }
            /* 逆序压栈，保证出栈顺序与 ioreg 一致 */
            for (int j = k - 1; j >= 0; j--)
                st[n++] = (stack_item_t){ kids[j], idx, it.depth + 1 };
        }
        IOObjectRelease(e);
    }

    /* 栈里剩下的（被截断/取消）对象要释放，否则 mach port 泄漏 */
    while (n > 0) IOObjectRelease(st[--n].entry);
    free(st);

    il_addf(&b, "META\t%zu\t%d\t%s", nn, truncated, pl);
    for (size_t i = 0; i < nn; i++) {
        node_t *x = &nodes[i];
        char pidbuf[32];
        if (x->clientPID > 0) snprintf(pidbuf, sizeof(pidbuf), "%d", x->clientPID);
        else snprintf(pidbuf, sizeof(pidbuf), "-");
        il_addf(&b,
            "NODE\t%d\t%d\t%d\t0x%llx\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s",
            x->index, x->parent, x->depth, (unsigned long long)x->entryID,
            x->name, x->cls,
            x->bundleID[0] ? x->bundleID : "-",
            x->persBundleID[0] ? x->persBundleID : "-",
            x->ioClass[0] ? x->ioClass : "-",
            x->providerClass[0] ? x->providerClass : "-",
            pidbuf,
            x->clientName[0] ? x->clientName : "-",
            x->clientSource[0] ? x->clientSource : "-",
            x->path[0] ? x->path : "-");
    }
    free(nodes);
    return il_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 选中节点的完整属性表                                                */
/* ------------------------------------------------------------------ */

int cproc_ioreg_properties(const char *path, cproc_lines_t *out)
{
    out->lines = NULL; out->count = 0;
    ioreg_lines_t b;
    if (il_init(&b) != 0) return -1;

    if (!path || !*path || strcmp(path, "-") == 0) {
        il_add(&b, "PMETA\t0\t0");
        il_add(&b, "ERROR\tno path");
        return il_finish(&b, out);
    }

    io_registry_entry_t e = 0;
    /* IORegistryEntryGetPath 给出的旧式路径（如 "IOService:/AppleARMPE/..."）
     * 仍被接受，不需要转换格式。 */
    CFStringRef cpath = CFStringCreateWithCString(
        kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    if (cpath) {
        e = IORegistryEntryCopyFromPath(CPROC_IO_MAIN_PORT, cpath);
        CFRelease(cpath);
    }
    if (!e) {
        il_add(&b, "PMETA\t0\t0");
        il_add(&b, "ERROR\tIORegistryEntryCopyFromPath failed");
        return il_finish(&b, out);
    }

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0)
        != KERN_SUCCESS || !props) {
        il_add(&b, "PMETA\t0\t0");
        il_add(&b, "ERROR\tIORegistryEntryCreateCFProperties failed");
        IOObjectRelease(e);
        return il_finish(&b, out);
    }

    CFIndex count = CFDictionaryGetCount(props);
    CFTypeRef *keys = calloc((size_t)(count > 0 ? count : 1), sizeof(CFTypeRef));
    CFTypeRef *vals = calloc((size_t)(count > 0 ? count : 1), sizeof(CFTypeRef));
    ioreg_lines_t propsOut;
    int haveProps = (il_init(&propsOut) == 0);
    int truncated = 0, emitted = 0;
    if (keys && vals && haveProps) {
        CFDictionaryGetKeysAndValues(props, (const void **)keys,
                                     (const void **)vals);
        /* 按 key 排序，属性表稳定不跳动 */
        for (CFIndex i = 0; i < count; i++) {
            for (CFIndex j = i + 1; j < count; j++) {
                CFStringRef a = (CFStringRef)keys[i], c = (CFStringRef)keys[j];
                if (CFGetTypeID(a) == CFStringGetTypeID() &&
                    CFGetTypeID(c) == CFStringGetTypeID() &&
                    CFStringCompare(a, c, kCFCompareCaseInsensitive) == kCFCompareGreaterThan) {
                    CFTypeRef t;
                    t = keys[i]; keys[i] = keys[j]; keys[j] = t;
                    t = vals[i]; vals[i] = vals[j]; vals[j] = t;
                }
            }
        }
        for (CFIndex i = 0; i < count; i++) {
            if (emitted >= 400) { truncated = 1; break; }
            char kb[512], vb[4096];
            const char *tn = "cf";
            cfstring_to_buf((CFStringRef)keys[i], kb, sizeof(kb));
            cftype_to_buf(vals[i], vb, sizeof(vb), &tn);
            if (!kb[0]) continue;
            il_addf(&propsOut, "PROP\t%s\t%s\t%s", kb, tn,
                    vb[0] ? vb : "-");
            emitted++;
        }
    } else truncated = 1;
    free(keys); free(vals);
    CFRelease(props);
    IOObjectRelease(e);

    /* 首行固定是 PMETA，之后才是属性行 */
    il_addf(&b, "PMETA\t%d\t%d", emitted, truncated);
    if (haveProps) {
        for (int i = 0; i < propsOut.n; i++) il_add(&b, propsOut.v[i]);
        for (int i = 0; i < propsOut.n; i++) free(propsOut.v[i]);
        free(propsOut.v);
    }
    return il_finish(&b, out);
}
