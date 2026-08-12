/*
 * provisioning/emulator/cogniforge-gemm.h
 *
 * CogniForge emulated tensor-core API: a self-contained FP32 SGEMM.
 *
 * Compiled into QEMU as part of the cogniforge-gpu device model, and also
 * usable standalone (see test-gemm.c) so the math can be verified without
 * building QEMU at all.
 */
#ifndef COGNIFORGE_GEMM_H
#define COGNIFORGE_GEMM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Row-major FP32 GEMM:  C[m x n] = A[m x k] * B[k x n]
 * Optionally accumulates into C (C = A*B + C) when COGNIFORGE_GEMM_ACCUM is
 * set in ->flags.  lda / ldb / ldc are row strides in float elements, so the
 * kernels can operate on padded or transposed buffers.
 */
#define COGNIFORGE_GEMM_ACCUM (1u << 0)

typedef struct CogniForgeGemmDesc {
    uint32_t m, n, k;
    uint32_t lda, ldb, ldc;
    const float *a;
    const float *b;
    float *c;
    uint32_t flags;
} CogniForgeGemmDesc;

enum {
    COGNIFORGE_GEMM_OK = 0,
    COGNIFORGE_GEMM_BAD_PARAMS = -1,   /* null desc / zero dims / bad strides */
    COGNIFORGE_GEMM_DIM_TOO_LARGE = -2,/* dimension above COGNIFORGE_GEMM_MAX_DIM */
};

#define COGNIFORGE_GEMM_MAX_DIM 4096

/* Returns COGNIFORGE_GEMM_OK or a negative error code. */
int cogniforge_gemm(const CogniForgeGemmDesc *d);

#ifdef __cplusplus
}
#endif

#endif /* COGNIFORGE_GEMM_H */