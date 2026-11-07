#!/bin/sh
# Run every mode a few times; each run gets a fresh shader seed.
# Results accumulate in ../build/results.tsv.
#   ./matrix.sh [PIPELINES] [RUNS]
cd "$(dirname "$0")"
N=${1:-10000}
R=${2:-2}
SEED=${SEED_BASE:-1000}
run() { label=$1; shift; i=0; while [ $i -lt "$R" ]; do SEED=$((SEED+1)); ./run.sh "$label" "$SEED" --pipelines "$N" --timeout 600 "$@"; i=$((i+1)); done; }
run cap-flush100            --flush-every 100
(NVS=1; export NVS; run cap-flush100-nvs1 --flush-every 100); SEED=$((SEED+R))
run cap-flush100-shared     --flush-every 100 --shared-libs
run cap-flush100-concurrent --flush-every 100 --flush-concurrent
run cap-flush5000          --flush-every 5000
run cap-spec-always        --flush-every 100 --specialize always
run cap-24threads          --flush-every 100 --threads 24
run serial-same-vertex     --flush-every 100 --serial-same-vertex
run no-capture             --no-capture
