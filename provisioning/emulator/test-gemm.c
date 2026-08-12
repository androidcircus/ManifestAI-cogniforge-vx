/*
 * provisioning/emulator/test-gemm.c
 * Standalone numeric verification of cogniforge-gemm.c (no QEMU required).
 *
 * Build + run via test-gemm.sh, or directly:
 *   gcc -O2 -o test-gemm test-gemm.c cogniforge-gemm.c && ./test-gemm
 *
 * Checks the scalar kernel always, and the AVX-512 kernel when this TU is
 * compiled with __AVX512F__ (the runtime avx512f check keeps it correct on
 * non-AVX-512 hosts by falling back to the scalar path).
 */
#include "cogniforge-gemm.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static float frand(int *seed)
{
    *seed = *seed * 1103515245 + 12345;
    return (float)((*seed >> 16) & 0x7fff) / 16383.5f - 1.0f;
}

/* Naive reference: C[m x n] = A[m x k] * B[k x n] (row-major, strides). */
static void ref_gemm(int m, int n, int k, int lda, int ldb, int ldc,
                     int accum, const float *a, const float *b, float *c)
{
    for (int i = 0; i < m; i++) {
        for (int j = 0; j < n; j++) {
            float acc = accum ? c[i * ldc + j] : 0.0f;
            for (int p = 0; p < k; p++) {
                acc += a[i * lda + p] * b[p * ldb + j];
            }
            c[i * ldc + j] = acc;
        }
    }
}

static int g_failures;

static void check_case(const char *name, int m, int n, int k,
                       int lda, int ldb, int ldc, int accum)
{
    const size_t abytes = (size_t)m * lda;
    const size_t bbytes = (size_t)k * ldb;
    const size_t cbytes = (size_t)(m * ldc > 0 ? m * ldc : 1);

    float *a = malloc(sizeof(float) * abytes);
    float *b = malloc(sizeof(float) * bbytes);
    float *cgot = malloc(sizeof(float) * cbytes);
    float *cref = calloc(cbytes, sizeof(float));

    int seed = 42 + accum * 1000 + k;
    for (size_t i = 0; i < abytes; i++) a[i] = frand(&seed);
    for (size_t i = 0; i < bbytes; i++) b[i] = frand(&seed);
    for (size_t i = 0; i < cbytes; i++) cref[i] = cgot[i] = frand(&seed);

    ref_gemm(m, n, k, lda, ldb, ldc, accum, a, b, cref);

    CogniForgeGemmDesc desc = {
        .m = m, .n = n, .k = k,
        .lda = lda, .ldb = ldb, .ldc = ldc,
        .a = a, .b = b, .c = cgot,
        .flags = accum ? COGNIFORGE_GEMM_ACCUM : 0,
    };
    int rc = cogniforge_gemm(&desc);

    if (rc != COGNIFORGE_GEMM_OK) {
        printf("FAIL %-28s rc=%d\n", name, rc);
        g_failures++;
    } else {
        double maxerr = 0.0;
        for (int i = 0; i < m; i++) {
            for (int j = 0; j < n; j++) {
                double d = fabs((double)cref[i * ldc + j] - cgot[i * ldc + j]);
                if (d > maxerr) maxerr = d;
            }
        }
        if (maxerr > 1e-3) {
            printf("FAIL %-28s maxerr=%.3e\n", name, maxerr);
            g_failures++;
        } else {
            printf(" ok  %-28s m=%2d n=%2d k=%2d lda=%d ldb=%d ldc=%d acc=%d "
                   "maxerr=%.1e\n", name, m, n, k, lda, ldb, ldc, accum, maxerr);
        }
    }

    free(a); free(b); free(cgot); free(cref);
}

static void check_error(const char *name, int expect, const CogniForgeGemmDesc *d)
{
    int rc = cogniforge_gemm(d);
    if (rc == expect) {
        printf(" ok  %-28s rc=%d\n", name, rc);
    } else {
        printf("FAIL %-28s rc=%d (expected %d)\n", name, rc, expect);
        g_failures++;
    }
}

int main(void)
{
    const float zero = 0.0f;
    float *zero_ptr = (float *)&zero;

    printf("CogniForge GEMM verification\n");

    /* Square and rectangular, padded strides, accumulate on and off. */
    check_case("C=A*B 32x32x32", 32, 32, 32, 32, 32, 32, 0);
    check_case("C=A*B 64x48x40 padded", 64, 48, 40, 72, 56, 72, 0);
    check_case("C=A*B 127x31x65 odd", 127, 31, 65, 128, 40, 130, 0);
    check_case("C=A*B+C 48x32x16 accum", 48, 32, 16, 52, 38, 50, 1);
    check_case("C=A*B+C 1x1x1 accum", 1, 1, 1, 1, 1, 1, 1);
    check_case("C=A*B 3x3x3", 3, 3, 3, 3, 3, 3, 0);

    /* Error paths. */
    CogniForgeGemmDesc bad = {
        .m = 4, .n = 4, .k = 4, .lda = 4, .ldb = 4, .ldc = 4,
        .a = zero_ptr, .b = zero_ptr, .c = zero_ptr, .flags = 0,
    };
    check_error("null desc", COGNIFORGE_GEMM_BAD_PARAMS, NULL);

    bad.m = 0;
    check_error("zero m", COGNIFORGE_GEMM_BAD_PARAMS, &bad);
    bad.m = 4; bad.lda = 2;                 /* lda < k */
    check_error("lda<k", COGNIFORGE_GEMM_BAD_PARAMS, &bad);
    bad.lda = 4; bad.ldb = 2;
    check_error("ldb<n", COGNIFORGE_GEMM_BAD_PARAMS, &bad);
    bad.ldb = 4; bad.m = COGNIFORGE_GEMM_MAX_DIM + 1;
    check_error("m too large", COGNIFORGE_GEMM_DIM_TOO_LARGE, &bad);

    if (g_failures) {
        printf("%d FAILURE(S)\n", g_failures);
        return 1;
    }
    printf("all checks passed\n");
    return 0;
}