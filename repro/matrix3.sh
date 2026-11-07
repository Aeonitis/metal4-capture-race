#!/bin/sh
# Third round: the modes matrix2.sh did not reach (it stopped during run 3004),
# and workaround E (--per-thread-capture).
#   ./matrix3.sh [RUNS]
# Results accumulate in ../build/results.tsv.
cd "$(dirname "$0")"
R=${1:-2}
SEED=${SEED_BASE:-4000}
run() { label=$1; n=$2; shift 2; i=0; while [ $i -lt "$R" ]; do SEED=$((SEED+1)); ./run.sh "$label" "$SEED" --pipelines "$n" --timeout 600 "$@"; i=$((i+1)); done; }
# Left over from matrix2.sh
(NVS=4 NFS=2048; export NVS NFS; run unspec-noflush 8000 --unspecialized); SEED=$((SEED+R))
(NVS=64 NFS=256; export NVS NFS; run unspec-nvs64-grouped 16000 --unspecialized --grouped); SEED=$((SEED+R))
(NVS=4 NFS=2048; export NVS NFS; run unspec-serial-same-vertex 8000 --unspecialized --flush-every 100 --serial-same-vertex); SEED=$((SEED+R))
# Does workaround A also stop the write race? (Expected: no. That race is writing vs capturing.)
run flush-concurrent-serial-same-vertex 5000 --flush-every 100 --flush-concurrent --serial-same-vertex
# The write race with one compile at a time: writing vs capturing, or capturing vs capturing?
run flush-concurrent-1thread 1500 --flush-every 100 --flush-concurrent --threads 1
# Workaround E: one compiler + serializer per worker, no locks
run per-thread-capture 5000 --flush-every 100 --per-thread-capture
(NVS=4 NFS=2048; export NVS NFS; run unspec-per-thread-capture 8000 --unspecialized --flush-every 100 --per-thread-capture); SEED=$((SEED+R))
