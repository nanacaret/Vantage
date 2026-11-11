/* SPDX-License-Identifier: MIT */
#ifndef CPERF_H
#define CPERF_H

#include <stdint.h>
#include <stddef.h>

/*
 * CPerf —— macOS 性能数据监控（参考 macmon）
 *
 * 目标：在不使用 powermetrics / 不要求 root 的前提下，拿到 Apple Silicon 的
 *   CPU/GPU/ANE 功耗、DVFS 频率、die 温度、风扇、系统功率，
 *   以及公开的 CPU / 内存 / Swap / 磁盘 / 网络吞吐与热压等级。
 *
 * 分层：
 *   [公开、始终可用] host_statistics / host_processor_info / sysctl /
 *                    IOBlockStorageDriver / getifaddrs / vm_stat
 *   [私有、无 root、可选降级] libIOReport.dylib（dlopen + dlsym）、
 *                    AppleSMC（IOKit user client）、IORegistry DVFS 表
 *
 * 关键原则：unavailable != 0。每个字段是否可用由 valid 位标记，
 * UI 对无效字段显示「—」而不是 0，避免把"传感器读不到"伪装成"设备空闲"。
 *
 * 采样在 C 层自己的 pthread 里进行：IOReport subscription 必须留在创建它的
 * 线程上（DispatchQueue 不保证固定 OS 线程），Swift 侧只轮询最新的快照。
 */

#define CPERF_SOC_NAME_MAX 128
#define CPERF_STATUS_MAX   768

/* cproc_perf_t.valid 的位定义 */
#define CPERF_VALID_CPU          (1ULL << 0)   /* host_statistics 总 CPU */
#define CPERF_VALID_CORES        (1ULL << 1)   /* 分簇利用率（启发式） */
#define CPERF_VALID_MEM          (1ULL << 2)
#define CPERF_VALID_DISK         (1ULL << 3)
#define CPERF_VALID_NET          (1ULL << 4)
#define CPERF_VALID_POWER        (1ULL << 5)   /* IOReport Energy Model */
#define CPERF_VALID_FREQ         (1ULL << 6)   /* IOReport P-state residency */
#define CPERF_VALID_TEMP         (1ULL << 7)   /* SMC 温度传感器 */
#define CPERF_VALID_SYS_POWER    (1ULL << 8)   /* SMC PSTR */
#define CPERF_VALID_FAN          (1ULL << 9)
#define CPERF_VALID_DVFS         (1ULL << 10)  /* pmgr voltage-states 表 */
#define CPERF_VALID_THERMAL      (1ULL << 11)  /* notify 热压等级 */
#define CPERF_VALID_SOC          (1ULL << 12)  /* 芯片名 / 核心数 */
#define CPERF_VALID_RESIDENCY    (1ULL << 13)  /* P-state residency（活跃占比） */
#define CPERF_VALID_TIERS        (1ULL << 14)  /* 按 E/P/M 分簇的频率与活跃占比 */

/* 温度数据来源：0=无 1=AppleSMC 2=IOHID(核心传感器) 3=IOHID(PMU 传感器)
 * PMU tdie 是供电 IC 自身温度，不在 CPU 核心热点，绝对值偏低 15~20°C，
 * 界面必须标注，不能与 SMC Tp* 混为一谈。 */
#define CPERF_TEMP_NONE  0
#define CPERF_TEMP_SMC   1
#define CPERF_TEMP_HID   2
#define CPERF_TEMP_PMU   3

typedef struct {
    uint64_t valid;
    uint64_t timestamp_ns;

    /* CPU（公开） */
    double   cpu_user_pct;
    double   cpu_sys_pct;
    double   cpu_idle_pct;
    double   cpu_total_pct;
    double   p_core_pct;          /* 高性能簇利用率（按核心序号启发式） */
    double   e_core_pct;          /* 高能效簇利用率 */

    /* 频率 / 活跃占比（IOReport state residency） */
    double   cpu_freq_mhz;        /* 当前加权平均实时频率 */
    double   gpu_freq_mhz;
    double   cpu_active_ratio;    /* 0..1，非 IDLE/DOWN/OFF 的 residency 占比 */
    double   gpu_active_ratio;
    uint32_t p_freq_max_mhz;      /* DVFS 表静态上限 */
    uint32_t e_freq_max_mhz;
    uint32_t m_freq_max_mhz;
    uint32_t gpu_freq_max_mhz;

    /* 按 CPU tier 分开的实时数据（通道名含 ECPU / PCPU / MCPU / SCPU） */
    double   e_freq_mhz;
    double   p_freq_mhz;
    double   m_freq_mhz;
    double   e_active_ratio;
    double   p_active_ratio;
    double   m_active_ratio;
    uint32_t tier_count;          /* 实际检测到 2 或 3 个 CPU tier */

    /* 功耗（W）—— IOReport Energy Model 与 SMC PSTR 口径不同，不可相加 */
    double   cpu_power_w;
    double   gpu_power_w;
    double   ane_power_w;
    double   dram_power_w;
    double   soc_power_w;         /* IOReport 各部件之和 */
    double   sys_power_w;         /* SMC PSTR 整机负载 */

    /* 温度 / 风扇 / 热压 */
    double   cpu_temp_c;
    double   gpu_temp_c;
    double   max_temp_c;
    double   fan_rpm;
    uint32_t thermal_pressure;    /* 0=NOMINAL 1=FAIR 2=SERIOUS 3=CRITICAL */
    uint32_t temp_source;         /* CPERF_TEMP_* */
    uint32_t matched_energy_channels;
    uint32_t matched_state_channels;
    uint32_t power_source;        /* 0=无 2=Energy Model（精确过滤后） */

    /* IO 吞吐（B/s、IOPS） */
    double   disk_read_bps;
    double   disk_write_bps;
    double   disk_iops;
    double   net_rx_bps;
    double   net_tx_bps;

    /* 内存 / Swap（字节） */
    uint64_t mem_used;
    uint64_t mem_total;
    uint64_t mem_wired;
    uint64_t mem_compressed;
    uint64_t swap_used;
    uint64_t swap_total;

    /* 静态 SoC 信息 */
    uint32_t p_cores;
    uint32_t e_cores;
    uint32_t gpu_cores;
    uint32_t nperflevels;

    /* 字符串不放进结构：C 定长 char[] 导入 Swift 会变成巨型 tuple */
} cproc_perf_values_t;

/* 启动 / 停止常驻采样线程。interval_ms 建议 500..5000。
 * 返回 0 成功；重复调用会先停掉旧线程。 */
int  cproc_perf_start(uint32_t interval_ms);
void cproc_perf_stop(void);
void cproc_perf_set_interval(uint32_t interval_ms);

/* 拷贝最新快照。返回 0 表示拿到过至少一帧数据。 */
int  cproc_perf_latest(cproc_perf_values_t *out);

/* 字符串 / 静态信息 accessor */
const char *cproc_perf_soc_name(void);
const char *cproc_perf_status(void);

/* 逐通道原始诊断（每次采样后更新）。用于核对数值口径：
 * 实际匹配到的能量通道名 + 换算后的 W、P-state 通道的 state 名/档数/频率、
 * SMC 温度键与 IOHID 传感器名、各簇 DVFS 频率表档数。
 * 返回静态 buffer，不需要释放。 */
const char *cproc_perf_diagnostics(void);

/* 静态信息（不依赖采样线程） */
int      cproc_perf_is_apple_silicon(void);
uint32_t cproc_perf_interval_ms(void);
uint64_t cproc_perf_now_ns(void);

#endif /* CPERF_H */
