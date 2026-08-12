#!/bin/bash
# provisioning/emulator/test-gemm.sh
# Build + run the standalone GEMM correctness test (no QEMU needed).
# Compiles once without AVX-512 and, if the compiler supports it, once with
# -mavx512f so the vector path is exercised on capable hosts.
#
# Usage: ./test-gemm.sh
set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-gcc}"
echo "==> [1/2] scalar kernel"
"$CC" -O2 -Wall -Wextra -o test-gemm test-gemm.c cogniforge-gemm.c
./test-gemm

echo "==> [2/2] AVX-512 kernel (if compiler supports it)"
if "$CC" -mavx512f -E -xc /dev/null >/dev/null 2>&1; then
  "$CC" -O2 -mavx512f -Wall -Wextra -o test-gemm-avx512 \
    test-gemm.c cogniforge-gemm.c
  ./test-gemm-avx512
else
  echo "    compiler does not support -mavx512f; skipping"
fi

rm -f test-gemm test-gemm-avx512
echo "==> done"
