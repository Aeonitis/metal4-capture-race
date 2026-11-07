#!/bin/sh
# Second round, closer to nxnative's captures: unspecialized colour attachments
# ("base" pipelines), more fragment shaders, and a set with many vertex shaders.
#   ./matrix2.sh [RUNS]
cd "$(dirname "$0")"
R=${1:-2}
SEED=${SEED_BASE:-3000}
run() { label=$1; n=$2; shift 2; i=0; while [ $i -lt "$R" ]; do SEED=$((SEED+1)); ./run.sh "$label" "$SEED" --pipelines "$n" --timeout 600 "$@"; i=$((i+1)); done; }
(NVS=4 NFS=2048; export NVS NFS; run unspec-flush100 8000 --unspecialized --flush-every 100); SEED=$((SEED+R))
(NVS=1 NFS=2048; export NVS NFS; run unspec-nvs1-flush100 2048 --unspecialized --flush-every 100); SEED=$((SEED+R))
(NVS=4 NFS=2048; export NVS NFS; run unspec-noflush 8000 --unspecialized); SEED=$((SEED+R))
(NVS=64 NFS=256; export NVS NFS; run unspec-nvs64-grouped 16000 --unspecialized --grouped); SEED=$((SEED+R))
(NVS=4 NFS=2048; export NVS NFS; run unspec-serial-same-vertex 8000 --unspecialized --flush-every 100 --serial-same-vertex); SEED=$((SEED+R))
# Does the per-vertex-function lock help against the flush race? (It should not: that race is flush vs capture.)
run flush-concurrent-serial-same-vertex 5000 --flush-every 100 --flush-concurrent --serial-same-vertex
# Flush concurrently but never more than one compile at a time: is it flush vs capture, or capture vs capture?
run flush-concurrent-1thread 1500 --flush-every 100 --flush-concurrent --threads 1
