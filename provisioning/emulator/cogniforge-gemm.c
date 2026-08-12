/*
 * provisioning/emulator/cogniforge-gemm.c
 *
 * CogniForge emulated tensor-core backend: a self-contained FP32 SGEMM.
 *
 * This is REAL compute - the loop nests below execute on the host CPU and
 * write results back into the device's VRAM.  Two kernels are provided:
 *
 *   - a portable scalar/saxpy kernel (always compiled)
 *   - an AVX-512 FMA kernel (compiled only when the TU is built with
 *     __AVX512F__, i.e. -mavx512f or -march matching AVX-512), selected at
 *     runtime only when the host CPU advertises avx512f.
 *
 * Care is taken so this file has no QEMU dependencies: only the C runtime.
 */
#include "cogniforge-gemm.h"

#include <string.h>

#if defined(__AVX512F__)
#include <immintrin.h>
#endif

/* ------------------------------------------------------------------ */
/* Portable scalar kernel (saxpy form: cache friendly, correct)        */
/* ------------------------------------------------------------------ */
static void gemm_scalar(const CogniForgeGemmDesc *d)
{
    const float *a = d->a;
    const float *b = d->b;
    float *c = d->c;
    const uint32_t m = d->m;
    const uint32_t n = d->n;
    const uint32_t k = d->k;
    const uint32_t lda = d->lda;
    const uint32_t ldb = d->ldb;
    const uint32_t ldc = d->ldc;

    if (!(d->flags & COGNIFORGE_GEMM_ACCUM)) {
        for (uint32_t i = 0; i < m; i++) {
            float *crow = c + (uint64_t)i * ldc;
            memset(crow, 0, (size_t)n * sizeof(float));
        }
    }

    for (uint32_t i = 0; i < m; i++) {
        const float *arow = a + (uint64_t)i * lda;
        float *crow = c + (uint64_t)i * ldc;
        for (uint32_t p = 0; p < k; p++) {
            const float aval = arow[p];
            const float *brow = b + (uint64_t)p * ldb;
            for (uint32_t j = 0; j < n; j++) {
                crow[j] += aval * brow[j];
            }
        }
    }
}

#if defined(__AVX512F__)
/* ------------------------------------------------------------------ */
/* AVX-512 FMA kernel: 16-wide saxpy over the n axis                   */
/* ------------------------------------------------------------------ */
static void gemm_avx512(const CogniForgeGemmDesc *d)
{
    const float *a = d->a;
    const float *b = d->b;
    float *c = d->c;
    const uint32_t m = d->m;
    const uint32_t n = d->n;
    const uint32_t k = d->k;
    const uint32_t lda = d->lda;
    const uint32_t ldb = d->ldb;
    const uint32_t ldc = d->ldc;

    if (!(d->flags & COGNIFORGE_GEMM_ACCUM)) {
        for (uint32_t i = 0; i < m; i++) {
            float *crow = c + (uint64_t)i * ldc;
            memset(crow, 0, (size_t)n * sizeof(float));
        }
    }

    for (uint32_t i = 0; i < m; i++) {
        const float *arow = a + (uint64_t)i * lda;
        float *crow = c + (uint64_t)i * ldc;
        for (uint32_t p = 0; p < k; p++) {
            const __m512 aval = _mm512_set1_ps(arow[p]);
            const float *brow = b + (uint64_t)p * ldb;
            uint32_t j;
            for (j = 0; j + 16 <= n; j += 16) {
                __m512 acc = _mm512_loadu_ps(crow + j);
                acc = _mm512_fmadd_ps(aval, _mm512_loadu_ps(brow + j), acc);
                _mm512_storeu_ps(crow + j, acc);
            }
            for (; j < n; j++) {
                crow[j] += arow[p] * brow[j];
            }
        }
    }
}

static int host_has_avx512f(void)
{
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_cpu_supports("avx512f");
#else
    return 0;
#endif
}
#endif /* __AVX512F__ */

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */
int cogniforge_gemm(const CogniForgeGemmDesc *d)
{
    if (d == NULL || d->a == NULL || d->b == NULL || d->c == NULL) {
        return COGNIFORGE_GEMM_BAD_PARAMS;
    }
    if (d->m == 0 || d->n == 0 || d->k == 0) {
        return COGNIFORGE_GEMM_BAD_PARAMS;
    }
    if (d->m > COGNIFORGE_GEMM_MAX_DIM ||
        d->n > COGNIFORGE_GEMM_MAX_DIM ||
        d->k > COGNIFORGE_GEMM_MAX_DIM) {
        return COGNIFORGE_GEMM_DIM_TOO_LARGE;
    }
    if (d->lda < d->k || d->ldb < d->n || d->ldc < d->n) {
        return COGNIFORGE_GEMM_BAD_PARAMS;
    }

#if defined(__AVX512F__)
    if (host_has_avx512f()) {
        gemm_avx512(d);
        return COGNIFORGE_GEMM_OK;
    }
#endif
    gemm_scalar(d);
    return COGNIFORGE_GEMM_OK;
}