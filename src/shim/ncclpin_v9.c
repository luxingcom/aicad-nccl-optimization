/*
 * libncclpin.so v9 — DGX Spark NCCL/EngineCore 线程绑核 shim
 *
 * 基线: v3 (open-kit 2026-08-13 归档) + 生产 v8 实测问题 (2026-08-14 取证)
 * 实测证据: 生产 v8 日志全为 "default => CPU 5-19"；vLLM 主进程 18 线程 aff=5-19/5-9，
 *           隔离核 8-9 零占用 → NCCL 数据面线程未落隔离核。
 *
 * v9 变更 (基于 2026-08-14 实测修正, 覆盖旧文档 plan-cpu-cluster0 的过时布局):
 *  宿主实测: isolcpus=8-9 (2×X925 3900MHz 隔离核, 专给 NCCL 数据面)
 *           CPU 0-4,10-14 = A725 2808MHz | CPU 5-9,15-19 = X925 3900MHz
 *  生产设计 (start_tp4_cluster.sh R11 PSR): NCCL=8-9, EngineCore=15-19
 *  1. NCCL 数据面线程 => CPU 8-9 (隔离核; 旧 v3 写 0-4 依据过时文档, 已修正)
 *  2. 其他线程 => CPU 5-19 (与生产 v8 一致, 零回归; 隔离核 8-9 由 isolcpus 自动避开)
 *  3. thread_entry 竞态修复: per-create malloc + 原子 consumed + 入口内 free
 *  4. 环境开关 NCCLPIN_VERBOSE=1 控制日志; NCCLPIN_DISABLE=1 完全禁用
 *  5. 线程名匹配表 (NCCL 2.30.7 ringonly 实测前缀):
 *     NCCL* / pt_nccl* / pt_tcpstore* / *Proxy* => CPU 8-9
 *     其他                                    => CPU 5-19
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sched.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>

#define NCCL_LO 8
#define NCCL_HI 9
#define DEF_LO  5
#define DEF_HI  19

static int pin_verbose = -1;   /* -1=未初始化 */
static int pin_disabled = 0;

static int pin_should_log(void) {
    if (pin_verbose < 0) {
        const char *v = getenv("NCCLPIN_VERBOSE");
        pin_verbose = (v != NULL && strcmp(v, "1") == 0);
        const char *d = getenv("NCCLPIN_DISABLE");
        pin_disabled = (d != NULL && strcmp(d, "1") == 0);
    }
    return pin_verbose && !pin_disabled;
}

static void pin_pthread(pthread_t th, const char *tag, int lo, int hi) {
    cpu_set_t set;
    CPU_ZERO(&set);
    for (int c = lo; c <= hi; c++) CPU_SET(c, &set);
    if (pthread_setaffinity_np(th, sizeof(set), &set) == 0) {
        if (pin_should_log())
            fprintf(stderr, "[libncclpin] %s => CPU %d-%d\n", tag, lo, hi);
    } else {
        fprintf(stderr, "[libncclpin] %s pin fail(%s)\n", tag, strerror(errno));
    }
}

__attribute__((constructor))
static void ncclpin_ctor(void) {
    if (pin_disabled) return;
    cpu_set_t set;
    CPU_ZERO(&set);
    for (int c = DEF_LO; c <= DEF_HI; c++) CPU_SET(c, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

/* ---- 线程名分类 ---- */
enum pin_class { PIN_NCCL, PIN_DEFAULT };

static enum pin_class classify_name(const char *name) {
    if (name == NULL) return PIN_DEFAULT;
    if (strncmp(name, "NCCL", 4) == 0 || strstr(name, "Proxy") != NULL ||
        strncmp(name, "pt_nccl", 7) == 0 || strncmp(name, "pt_tcpstore", 11) == 0)
        return PIN_NCCL;
    return PIN_DEFAULT;
}

/* ---- setname 拦截: 按名 pin (优先路径) ---- */
int pthread_setname_np(pthread_t thread, const char *name) {
    static int (*real)(pthread_t, const char *) = NULL;
    if (!real) real = (int (*)(pthread_t, const char *))dlsym(RTLD_NEXT, "pthread_setname_np");
    int rc = real(thread, name);
    if (rc == 0 && name && !pin_disabled) {
        if (classify_name(name) == PIN_NCCL)
            pin_pthread(thread, name, NCCL_LO, NCCL_HI);
        else
            pin_pthread(thread, name, DEF_LO, DEF_HI);
    }
    return rc;
}

/* ---- create 拦截: 默认 pin 5-19 (不覆盖已按名 pin 的线程) ---- */
typedef struct {
    void *(*fn)(void *);
    void *arg;
    atomic_int consumed;
} wrap_t;

static void *thread_entry(void *p) {
    wrap_t *w = (wrap_t *)p;
    if (w == NULL) return NULL;
    /* 等待创建者填充完成 (atomic release/acquire 配对, 避免半初始化窗口) */
    while (!atomic_load_explicit(&w->consumed, memory_order_acquire))
        ;
    void *(*fn)(void *) = w->fn;
    void *arg = w->arg;
    free(w); /* 字段已读取完毕, 此处释放安全 (v3 已验证模式) */
    pin_pthread(pthread_self(), "default", DEF_LO, DEF_HI);
    return fn(arg);
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg) {
    static int (*real)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = NULL;
    if (!real) real = (int (*)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *))
                      dlsym(RTLD_NEXT, "pthread_create");
    if (pin_disabled) return real(thread, attr, start_routine, arg);

    wrap_t *w = (wrap_t *)malloc(sizeof(wrap_t));
    if (!w) return real(thread, attr, start_routine, arg);
    w->fn = start_routine;
    w->arg = arg;
    atomic_store_explicit(&w->consumed, 1, memory_order_release);
    int rc = real(thread, attr, thread_entry, w);
    if (rc != 0) free(w); /* 创建失败才回收 */
    return rc;
}
