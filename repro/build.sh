#!/bin/sh
# Build the repro and its shaders.
#   ./build.sh [SEED] [NUM_VS] [NUM_FS]
# Outputs go to ../build (gitignored): repro binary and shaders-<SEED>/*.metallib.
set -eu
unset SDKROOT
cd "$(dirname "$0")"
SEED=${1:-1}
NVS=${2:-4}
NFS=${3:-512}
OUT=../build
SH=$OUT/shaders-$SEED
mkdir -p "$OUT" "$SH"

xcrun clang -O2 -g -fobjc-arc -Wall -framework Metal -framework Foundation \
    -o "$OUT/repro" repro.m

if [ ! -f "$SH/.done-$NVS-$NFS" ]; then
    python3 gen_shaders.py "$SH" "$NVS" "$NFS" "$SEED"
    # One .metallib per shader function, compiled in parallel.
    ls "$SH"/*.metal | xargs -P "$(sysctl -n hw.ncpu)" -I{} sh -c \
        'f="{}"; xcrun metal -c -o "${f%.metal}.air" "$f" && xcrun metallib -o "${f%.metal}.metallib" "${f%.metal}.air" && rm "${f%.metal}.air"'
    touch "$SH/.done-$NVS-$NFS"
fi
echo "built $OUT/repro; shaders in $SH ($NVS vertex, $NFS fragment)"
