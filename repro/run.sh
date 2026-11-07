#!/bin/sh
# Run the repro once with a fresh shader seed and record the outcome.
#   ./run.sh LABEL SEED [repro options...]
# Appends one line to ../build/results.tsv: label, seed, exit status, seconds,
# pipelines built, crash report (if any).
set -u
unset SDKROOT
cd "$(dirname "$0")"
LABEL=$1; SEED=$2; shift 2
NVS=${NVS:-4}; NFS=${NFS:-512}
./build.sh "$SEED" "$NVS" "$NFS" >/dev/null || exit 1
LOG=../build/run-$LABEL-$SEED.log
MARK=../build/.mark-$LABEL-$SEED
touch "$MARK"
START=$(date +%s)
../build/repro --shaders ../build/shaders-$SEED "$@" >"$LOG" 2>&1
RC=$?
END=$(date +%s)
sleep 5   # give ReportCrash time to write the .ips
IPS=$(find "$HOME/Library/Logs/DiagnosticReports" -name 'repro-*.ips' -newer "$MARK" 2>/dev/null | head -1)
BUILT=$(grep -o '[0-9]*/[0-9]* pipelines' "$LOG" | tail -1)
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$LABEL" "$SEED" "$RC" "$((END-START))" "${BUILT:-0}" "${IPS:-none}" | tee -a ../build/results.tsv
rm -f "$MARK"
# Shader sets are small but not free; drop this seed's set.
rm -rf ../build/shaders-$SEED
