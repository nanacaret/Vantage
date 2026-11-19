/* SPDX-License-Identifier: MIT */
/*
 * net_info.c —— 系统网络信息采集（网卡 / 地址 / 路由表）
 *
 * 与进程详情一样，这里只输出 **纯 ASCII 数据行**（'\t' 分隔），
 * 不做任何本地化：界面文案（列头、状态说明）都由 Swift 侧用 L() 组装。
 * 这样新增字段不需要动 C 的双语表，也不会把中文混进协议数据。
 *
 * 数据来源全部是公开接口，读取不需要 root：
 *   · getifaddrs()           网卡 + AF_LINK（MAC / index）+ inet/inet6 地址
 *   · ioctl(SIOCGIFMTU)      每个网卡的 MTU（getifaddrs 不提供）
 *   · sysctl NET_RT_DUMP     路由表（AF_INET / AF_INET6 各 dump 一次）
 */
#include "CProc.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>

/* ---------- 极简行收集器（与 proc_detail.c 的 cproc_lines_t 同约定） ---------- */
typedef struct {
    char **v;
    int32_t n;
    int32_t cap;
} nl_t;

static void nl_add(nl_t *b, const char *s)
{
    if (b->n >= b->cap) {
        int32_t nc = b->cap ? b->cap * 2 : 32;
        char **nv = realloc(b->v, (size_t)nc * sizeof(char *));
        if (!nv) return;
        b->v = nv;
        b->cap = nc;
    }
    b->v[b->n++] = strdup(s ? s : "");
}

static void nl_addf(nl_t *b, const char *fmt, ...)
{
    char tmp[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    nl_add(b, tmp);
}

static int nl_finish(nl_t *b, cproc_lines_t *out)
{
    out->lines = b->v;
    out->count = b->n;
    b->v = NULL;
    b->n = b->cap = 0;
    return 0;
}

/* ---------- 工具 ---------- */

static const char *iftype_name(unsigned char type)
{
    switch (type) {
    case IFT_ETHER:     return "ether";
    case IFT_LOOP:      return "loopback";
    case IFT_PPP:       return "ppp";
    case IFT_IEEE1394:  return "firewire";
    case IFT_CELLULAR:  return "cellular";
    case IFT_BRIDGE:    return "bridge";
    case IFT_ENC:       return "enc";
    case IFT_6LOWPAN:   return "lowpan";
    case IFT_GIF:       return "gif";
    case IFT_STF:       return "stf";
    default:            return "other";
    }
}

static void mac_string(const struct sockaddr_dl *sdl, char *out, size_t cap)
{
    out[0] = '\0';
    if (!sdl || sdl->sdl_alen <= 0) return;
    const unsigned char *a = (const unsigned char *)LLADDR(sdl);
    size_t o = 0;
    for (int i = 0; i < sdl->sdl_alen && o + 4 < cap; i++) {
        int n = snprintf(out + o, cap - o, i ? ":%02x" : "%02x", a[i]);
        if (n < 0) break;
        o += (size_t)n;
    }
}

/* 把 netmask sockaddr 转成前缀长度；失败返回 -1 */
static int prefix_from_mask(const struct sockaddr *sa)
{
    if (!sa || sa->sa_len == 0) return -1;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        uint32_t m = ntohl(sin->sin_addr.s_addr);
        int bits = 0;
        while (m & 0x80000000u) { bits++; m <<= 1; }
        return bits;
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        int bits = 0;
        for (int i = 0; i < 16; i++) {
            unsigned char b = sin6->sin6_addr.s6_addr[i];
            if (b == 0xff) { bits += 8; continue; }
            while (b & 0x80) { bits++; b <<= 1; }
            break;
        }
        return bits;
    }
    return -1;
}

/* sockaddrs 在路由消息里按 4 字节对齐连续排列 */
#define ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))
#define NEXT_SA(p) ((struct sockaddr *)((char *)(p) + ROUNDUP((p)->sa_len)))

/* ---------- 网卡列表 ----------
 * 列：index, name, flags(hex), mtu, mac, type
 * 顺序与 getifaddrs 一致（系统本来就把 lo0 / en0 排前面）。 */
int cproc_net_ifaces(cproc_lines_t *out)
{
    if (!out) return -EINVAL;
    struct ifaddrs *ifa0 = NULL;
    if (getifaddrs(&ifa0) != 0) return -errno;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);

    nl_t b = {0};
    for (struct ifaddrs *ifa = ifa0; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK) continue;
        const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)ifa->ifa_addr;

        int mtu = 0;
        if (sock >= 0) {
            struct ifreq ifr;
            memset(&ifr, 0, sizeof(ifr));
            snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", ifa->ifa_name);
            if (ioctl(sock, SIOCGIFMTU, &ifr) == 0) mtu = ifr.ifr_mtu;
        }
        char mac[64];
        mac_string(sdl, mac, sizeof(mac));
        unsigned char type = sdl ? sdl->sdl_type : 0;

        nl_addf(&b, "%d\t%s\t%08x\t%d\t%s\t%s",
                sdl ? sdl->sdl_index : 0, ifa->ifa_name,
                ifa->ifa_flags, mtu, mac, iftype_name(type));
    }

    if (sock >= 0) close(sock);
    freeifaddrs(ifa0);
    return nl_finish(&b, out);
}

/* ---------- 地址列表 ----------
 * 列：ifname, family(inet|inet6|link), addr, prefix, netmask, peer/broadcast, scope
 * inet6 的 scope 是 sin6_scope_id（0 表示全局）；inet 恒为 0。 */
int cproc_net_addrs(cproc_lines_t *out)
{
    if (!out) return -EINVAL;
    struct ifaddrs *ifa0 = NULL;
    if (getifaddrs(&ifa0) != 0) return -errno;

    nl_t b = {0};
    for (struct ifaddrs *ifa = ifa0; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr) continue;
        char addr[INET6_ADDRSTRLEN + 8] = "-";
        char mask[INET6_ADDRSTRLEN + 8] = "-";
        char peer[INET6_ADDRSTRLEN + 8] = "-";
        int prefix = -1;
        unsigned scope = 0;
        const char *fam = NULL;

        switch (ifa->ifa_addr->sa_family) {
        case AF_INET: {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
            inet_ntop(AF_INET, &sin->sin_addr, addr, sizeof(addr));
            fam = "inet";
            if (ifa->ifa_netmask) {
                const struct sockaddr_in *m = (const struct sockaddr_in *)ifa->ifa_netmask;
                inet_ntop(AF_INET, &m->sin_addr, mask, sizeof(mask));
            }
            prefix = prefix_from_mask(ifa->ifa_netmask);
            if (ifa->ifa_flags & IFF_POINTOPOINT) {
                if (ifa->ifa_dstaddr) {
                    const struct sockaddr_in *d = (const struct sockaddr_in *)ifa->ifa_dstaddr;
                    inet_ntop(AF_INET, &d->sin_addr, peer, sizeof(peer));
                }
            } else if (ifa->ifa_flags & IFF_BROADCAST) {
                if (ifa->ifa_broadaddr) {
                    const struct sockaddr_in *d = (const struct sockaddr_in *)ifa->ifa_broadaddr;
                    inet_ntop(AF_INET, &d->sin_addr, peer, sizeof(peer));
                }
            }
            break;
        }
        case AF_INET6: {
            const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)ifa->ifa_addr;
            inet_ntop(AF_INET6, &sin6->sin6_addr, addr, sizeof(addr));
            fam = "inet6";
            scope = sin6->sin6_scope_id;
            if (ifa->ifa_netmask) {
                const struct sockaddr_in6 *m = (const struct sockaddr_in6 *)ifa->ifa_netmask;
                inet_ntop(AF_INET6, &m->sin6_addr, mask, sizeof(mask));
            }
            prefix = prefix_from_mask(ifa->ifa_netmask);
            break;
        }
        case AF_LINK: {
            const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)ifa->ifa_addr;
            mac_string(sdl, addr, sizeof(addr));
            if (addr[0] == '\0') continue;          /* 没有 MAC 的链路层条目跳过 */
            fam = "link";
            break;
        }
        default:
            continue;
        }

        nl_addf(&b, "%s\t%s\t%s\t%d\t%s\t%s\t%u",
                ifa->ifa_name, fam, addr, prefix, mask, peer, scope);
    }

    freeifaddrs(ifa0);
    return nl_finish(&b, out);
}

/* 路由消息里的 netmask 不是普通 AF_INET sockaddr：内核按
 *   sa_len = 4 + n（n = 有效字节数），sa_family = 0xff，
 *   之后紧跟 n 个掩码字节
 * 编码（例如 255.0.0.0 → len 5、字节 ff；254.0.0.0 → len 5、字节 fe；
 * 255.255.0.0 → len 6、ff ff）。所以不能拿 sin_addr 直接读。
 * 返回前缀位数，取不到返回 -1。 */
static int prefix_from_rtmask(const struct sockaddr *sa)
{
    if (!sa || sa->sa_len <= 4) return -1;
    int nbytes = sa->sa_len - 4;
    const unsigned char *p = (const unsigned char *)sa + 4;
    int bits = 0;
    for (int i = 0; i < nbytes; i++) {
        unsigned char b = p[i];
        if (b == 0xff) { bits += 8; continue; }
        while (b & 0x80) { bits++; b <<= 1; }
        break;
    }
    return bits;
}

/* ---------- 路由表 ----------
 * 列：family, dest, gateway, flags, netif, expire
 * flags 用 netstat 的字母约定（U G H S C W I L R b m 1 2 3 …），
 * 这样熟悉 route/netstat 的人能直接对照。 */
static void route_flags_string(int f, char *out, size_t cap)
{
    static const struct { int bit; char ch; } tbl[] = {
        { RTF_UP,        'U' },
        { RTF_GATEWAY,   'G' },
        { RTF_HOST,      'H' },
        { RTF_REJECT,    'R' },
        { RTF_DYNAMIC,   'D' },
        { RTF_MODIFIED,  'M' },
        { RTF_STATIC,    'S' },
        { RTF_CLONING,   'C' },
        { RTF_WASCLONED, 'W' },
        { RTF_IFSCOPE,   'I' },
        { RTF_LLINFO,    'L' },
        { RTF_PRCLONING,'c' },
        { RTF_BLACKHOLE, 'b' },
        { RTF_MULTICAST, 'm' },
        { RTF_PROTO1,    '1' },
        { RTF_PROTO2,    '2' },
        { RTF_PROTO3,    '3' },
        { RTF_IFREF,     'i' },
        { RTF_PROXY,     'p' },
        { RTF_ROUTER,    'r' },
        { RTF_GLOBAL,    'g' },
    };
    size_t o = 0;
    out[0] = '\0';
    for (size_t i = 0; i < sizeof(tbl) / sizeof(tbl[0]) && o + 2 < cap; i++) {
        if (f & tbl[i].bit) out[o++] = tbl[i].ch;
    }
    out[o] = '\0';
}

/* 从 sockaddr 取可读地址；AF_LINK 返回网卡名 */
static void sa_to_text(const struct sockaddr *sa, char *out, size_t cap)
{
    snprintf(out, cap, "-");
    if (!sa || sa->sa_len == 0) return;
    switch (sa->sa_family) {
    case AF_INET: {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        inet_ntop(AF_INET, &sin->sin_addr, out, (socklen_t)cap);
        return;
    }
    case AF_INET6: {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        inet_ntop(AF_INET6, &sin6->sin6_addr, out, (socklen_t)cap);
        /* 链路本地网关带 scope（%en0）才有意义，route 命令也认这个写法 */
        if (sin6->sin6_scope_id) {
            char scope[IF_NAMESIZE + 1] = {0};
            size_t used = strlen(out);
            if (if_indextoname(sin6->sin6_scope_id, scope) && used + 2 < cap) {
                snprintf(out + used, cap - used, "%%%s", scope);
            }
        }
        return;
    }
    case AF_LINK: {
        const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)sa;
        char name[IF_NAMESIZE] = {0};
        if (sdl->sdl_index && if_indextoname(sdl->sdl_index, name)) {
            snprintf(out, cap, "%s", name);
        } else {
            mac_string(sdl, out, cap);
            if (out[0] == '\0') snprintf(out, cap, "link#%u", sdl->sdl_index);
        }
        return;
    }
    default:
        return;
    }
}

static int dump_routes(int family, nl_t *b)
{
    int mib[6] = { CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP, 0 };
    size_t need = 0;
    if (sysctl(mib, 6, NULL, &need, NULL, 0) != 0) return -errno;
    if (need == 0) return 0;

    char *buf = NULL;
    for (int attempt = 0; attempt < 6; attempt++) {
        buf = malloc(need);
        if (!buf) return -ENOMEM;
        size_t got = need;
        if (sysctl(mib, 6, buf, &got, NULL, 0) == 0) { need = got; break; }
        int err = errno;
        free(buf);
        buf = NULL;
        if (err != ENOMEM) return -err;
        need *= 2;                  /* 表在变化：加大缓冲重试 */
    }
    if (!buf) return -ENOMEM;

    const char *fam = (family == AF_INET6) ? "inet6" : "inet";
    char *next = buf;
    char *end = buf + need;
    while (next + sizeof(struct rt_msghdr) <= end) {
        struct rt_msghdr *rtm = (struct rt_msghdr *)next;
        if (rtm->rtm_msglen == 0) break;
        next += rtm->rtm_msglen;

        /* 组播路由对「看默认网关 / 改路由」没有意义，噪声又大，跳过 */
        if (rtm->rtm_flags & RTF_MULTICAST) continue;

        struct sockaddr *dst = NULL, *gate = NULL, *mask = NULL;
        /* rtm_addrs 是 RTA_* 位掩码（不是个数）：消息里只出现置位的
           sockaddr，所以必须按位遍历、只对置位的推进指针，否则
           dest / gateway / netmask 会整体错位（表现为前缀长度乱飞）。 */
        struct sockaddr *sa = (struct sockaddr *)(rtm + 1);
        for (int bit = 1; bit && bit <= RTAX_MAX; bit <<= 1) {
            if ((rtm->rtm_addrs & bit) == 0) continue;
            if (!sa) break;
            if (sa->sa_len > 0) {
                if (bit == RTA_DST)     dst = sa;
                if (bit == RTA_GATEWAY) gate = sa;
                if (bit == RTA_NETMASK) mask = sa;
                sa = NEXT_SA(sa);
            } else {
                /* 占位条目（默认路由的 netmask 就写成 sa_len=0）：占 4 字节 */
                sa = (struct sockaddr *)((char *)sa + sizeof(uint32_t));
            }
        }

        char dtext[128], gtext[128];
        sa_to_text(dst, dtext, sizeof(dtext));
        sa_to_text(gate, gtext, sizeof(gtext));

        /* 目的地带上前缀长度，方便直接抄进 route 命令 */
        char dest[160];
        int plen = prefix_from_rtmask(mask);
        if (plen < 0 && (rtm->rtm_flags & RTF_HOST)) {
            plen = (family == AF_INET6) ? 128 : 32;
        }
        if (plen < 0) plen = 0;
        if (dst && (dst->sa_family == AF_INET || dst->sa_family == AF_INET6)) {
            snprintf(dest, sizeof(dest), "%s/%d", dtext, plen);
        } else {
            snprintf(dest, sizeof(dest), "%s", dtext);
        }

        char netif[IF_NAMESIZE + 1] = "-";
        if (rtm->rtm_index && !if_indextoname(rtm->rtm_index, netif)) {
            snprintf(netif, sizeof(netif), "if%d", rtm->rtm_index);
        }

        char flags[32];
        route_flags_string(rtm->rtm_flags, flags, sizeof(flags));

        /* rtm_rmx.rmx_expire 是绝对时戳（只有 RTF_LLINFO 项有意义），
           转成「还剩多少秒」更好看；其它路由恒为 0。 */
        long expire = 0;
        if ((rtm->rtm_flags & RTF_LLINFO) && rtm->rtm_rmx.rmx_expire > 0) {
            long left = (long)rtm->rtm_rmx.rmx_expire - (long)time(NULL);
            expire = left > 0 ? left : 0;
        }

        nl_addf(b, "%s\t%s\t%s\t%s\t%s\t%ld",
                fam, dest, gtext, flags, netif, expire);
    }
    free(buf);
    return 0;
}

int cproc_net_routes(cproc_lines_t *out)
{
    if (!out) return -EINVAL;
    nl_t b = {0};
    int e4 = dump_routes(AF_INET, &b);
    int e6 = dump_routes(AF_INET6, &b);
    /* 两个族都失败才算失败；只有一个失败时仍返回已拿到的部分 */
    if (e4 != 0 && e6 != 0) {
        for (int32_t i = 0; i < b.n; i++) free(b.v[i]);
        free(b.v);
        return e4;
    }
    return nl_finish(&b, out);
}

/* ---------- 聚合快照：一次调用拿到全部（UI 刷新用，少三次 C 边界） ---------- */
int cproc_net_snapshot(cproc_lines_t *ifaces, cproc_lines_t *addrs,
                       cproc_lines_t *routes)
{
    int rc = 0;
    if (ifaces && cproc_net_ifaces(ifaces) != 0) rc = -1;
    if (addrs && cproc_net_addrs(addrs) != 0) rc = -1;
    if (routes && cproc_net_routes(routes) != 0) rc = -1;
    return rc;
}
