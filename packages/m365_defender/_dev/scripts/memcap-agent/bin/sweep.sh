#!/usr/bin/env bash
#
# m365_defender agentless memory sweep - repeat bin/run.sh along one axis.
#
# A single run gives one point. Sizing needs the transfer function:
#
#     working_set ~= base + k x <axis>
#
# base is the whole-container floor (agent + beat + monitoring), paid once no matter how
# many streams are enabled, and k is what each extra unit of load costs. That is the shape
# an agentless memory request should be derived from, because it says what happens when a
# tenant is bigger than the one you measured.
#
# Two axes, one per invocation:
#
#   AXIS=scale (default)  scales every stream's page size together from the shipped
#     defaults. Measures k over a wide range. Past 1.0 the points are NOT tenants that can
#     exist - alert is capped at batch_size=1000 because Graph caps $top at 1000, and
#     vulnerability is fixed at pageSize=10000 in the CEL program - so treat scale>1 as a
#     way to measure the multiplier, not as a load anyone will see.
#
#   AXIS=alerts_per_incident   holds every page size at its shipped value and sweeps the
#     alerts[] array. With alert and vulnerability both capped by config, this is the ONE
#     input to pod memory that nothing bounds: $expand=alerts plus a nested split with
#     keep_parent turns each embedded alert into an event that also carries its parent.
#
# One-off comparisons that change a single knob (GOMEMLIMIT, a smaller page size, a lower
# cap) do not need a sweep: run bin/run.sh directly with the overrides and a shared
# RESULTS_CSV so the rows land in one file - see "What to run" in README.md.
#
# Sizing runs should be sustained (DRAIN=1 with a short INTERVAL): a cold page understates
# a production pod by ~2x because production fetches back-to-back. Cold is the cheaper
# mode and is fine for measuring the shape of a curve.
#
# Run at a cap comfortably above the largest expected peak - an OOM pins memory.peak at
# the cap and is excluded from the fit.
#
#   AXIS=scale SWEEP_CAP=3g POINTS="0.25 0.5 1 2 3" bin/sweep.sh
#   AXIS=alerts_per_incident SWEEP_CAP=3g POINTS="25 50 100 200 400" bin/sweep.sh
#
# Needs enough free memory in the Docker VM for the largest run; check `docker info` and
# stop other containers first, or the host will reclaim and distort the numbers.
#
# Writes one CSV per sweep under logs/. Promote the file to results/ when its numbers are
# the ones a document publishes - see README.md, "Publishing a number".

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

AXIS="${AXIS:-scale}"
SWEEP_CAP="${SWEEP_CAP:-3g}"
export STACK_VERSION="${STACK_VERSION:-9.6.0-SNAPSHOT}"
export AGENT_IMAGE="${AGENT_IMAGE:-docker.elastic.co/elastic-agent/elastic-agent:$STACK_VERSION}"
export ALERTS_PER_INCIDENT="${ALERTS_PER_INCIDENT:-100}"
export INTERVAL="${INTERVAL:-24h}"
export HOLD_S="${HOLD_S:-0}"
export DRAIN="${DRAIN:-0}"
export STREAMS="${STREAMS:-alert incident vulnerability}"

# Shipped production page sizes: the scale axis multiplies these, the other axis holds them.
BASE_ALERT="${BASE_ALERT:-1000}"
BASE_INCIDENT="${BASE_INCIDENT:-50}"
BASE_VULN="${BASE_VULN:-10000}"

case "$AXIS" in
  scale)               POINTS="${POINTS:-0.25 0.5 1 2 3}" ;;
  alerts_per_incident) POINTS="${POINTS:-25 50 100 200 400}" ;;
  *) echo "unknown AXIS=$AXIS (want: scale | alerts_per_incident)"; exit 1 ;;
esac

LOGDIR="$ROOT/logs"
mkdir -p "$LOGDIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/sweep-$AXIS-$TS.log"
CSV="${RESULTS_CSV:-$LOGDIR/sweep-$AXIS-$TS.csv}"

exec > >(tee -a "$LOG") 2>&1

echo "=================================================================="
echo " m365_defender memory sweep   $(date)"
echo " streams        : $STREAMS"
echo " agent version  : $STACK_VERSION"
echo " cap            : $SWEEP_CAP (chosen so runs do NOT OOM)"
echo " mode           : $([ "$HOLD_S" -gt 0 ] && echo "sustained (${HOLD_S}s at interval=$INTERVAL, drain=$DRAIN)" || echo "cold single page")"
echo " sweep axis     : $AXIS"
echo " points         : $POINTS"
if [ "$AXIS" = "scale" ]; then
  echo " scaled from    : alert=$BASE_ALERT incident=$BASE_INCIDENT vuln=$BASE_VULN (shipped defaults)"
  echo " alerts/incident: $ALERTS_PER_INCIDENT"
else
  echo " page sizes     : alert=$BASE_ALERT incident=$BASE_INCIDENT vuln=$BASE_VULN (shipped defaults, fixed)"
fi
echo " csv            : $CSV"
echo "=================================================================="

# One run. run.sh appends the row itself (see harness_emit_result_row in lib.sh) so the
# numbers in the CSV are the measured bytes, not a re-parse of rounded console output.
sweep_run() {
  local point="$1" label="$2"; shift 2
  local runlog="$LOGDIR/run-$AXIS-$TS-$point.log"
  echo
  echo ">>>>>> $AXIS=$point ${label:+($label) }cap=$SWEEP_CAP <<<<<<"
  # Sweep defaults first, the row's own assignments last: a knob row that sets MEM_LIMIT
  # is choosing the cap it is being tested at and must win over SWEEP_CAP.
  env MEM_LIMIT="$SWEEP_CAP" RESULTS_CSV="$CSV" RUN_LOG="$runlog" \
    RESULT_AXIS="$AXIS" RESULT_POINT="$point" RESULT_LABEL="$label" \
    "$@" "$HERE/run.sh" 2>&1 | tee "$runlog" || true
}

for p in $POINTS; do
  if [ "$AXIS" = "alerts_per_incident" ]; then
    a="$BASE_ALERT"; i="$BASE_INCIDENT"; v="$BASE_VULN"; per_incident="$p"
  else
    a=$(awk -v b="$BASE_ALERT"    -v f="$p" 'BEGIN{printf "%d", b*f}' </dev/null)
    i=$(awk -v b="$BASE_INCIDENT" -v f="$p" 'BEGIN{printf "%d", b*f}' </dev/null)
    v=$(awk -v b="$BASE_VULN"     -v f="$p" 'BEGIN{printf "%d", b*f}' </dev/null)
    per_incident="$ALERTS_PER_INCIDENT"
  fi
  sweep_run "$p" "" ALERT_EVENTS="$a" INCIDENT_EVENTS="$i" VULN_EVENTS="$v" ALERTS_PER_INCIDENT="$per_incident"
done

echo
echo "=================================================================="
echo " SWEEP SUMMARY"
echo "=================================================================="
# Columns are looked up by name from the header row rather than by position: the schema
# in lib.sh grows over time, and a positional index silently prints the wrong column
# instead of failing - which is how an OOM'd run could be read as a clean one.
printf ' %-10s %-11s %-10s %-10s %-10s %-6s %s\n' point raw_MB peak_MB ws_MB wsmax_MB oom label
awk -F, '
  # A column with no value is printed as a dash, not as 0.0: rows measured before a
  # column existed would otherwise read as a measurement of zero.
  function mb(v) { return v == "" ? "-" : sprintf("%.1f", v / 1048576) }
  /^#/ { next }
  $1 == "axis" { for (i = 1; i <= NF; i++) col[$i] = i; next }
  !("oom" in col) {
    print "  cannot summarise: no header row in " FILENAME > "/dev/stderr"
    exit 1
  }
  {
    printf " %-10s %-11s %-10s %-10s %-10s %-6s %s\n",
      $col["point"], mb($col["total_raw_bytes"]), mb($col["peak_bytes"]),
      mb($col["workingset_bytes"]), mb($col["workingset_peak_bytes"]),
      ($col["oom"] == "" ? "-" : $col["oom"]), $col["label"]
  }' "$CSV"

# Least-squares fit of memory against the swept axis, over the non-OOM rows (an OOM pins
# memory.peak at the cap, so including it would flatten the slope). This is a convenience
# print of `y ~= base + k*x`; the CSV is the artifact. When a document quotes the fit,
# it quotes the CSV the fit came from.
echo
awk -F, '
  /^#/ { next }
  $1 == "axis" { for (i = 1; i <= NF; i++) col[$i] = i; next }
  $col["oom"] == "true" { skipped++; next }
  $col["point"]+0 != $col["point"] { next }   # non-numeric point (adhoc rows)
  {
    x = $col["point"] + 0
    for (m = 1; m <= 2; m++) {
      y = (m == 1 ? $col["peak_bytes"] : $col["workingset_peak_bytes"])
      if (y == "") continue
      y = y / 1048576
      n[m]++; sx[m] += x; sy[m] += y; sxx[m] += x*x; sxy[m] += x*y
    }
  }
  END {
    name[1] = "memory.peak"; name[2] = "working-set peak"
    for (m = 1; m <= 2; m++) {
      if (n[m] < 2) { printf " fit %-17s: needs >=2 non-OOM points (have %d)\n", name[m], n[m]; continue }
      d = n[m]*sxx[m] - sx[m]*sx[m]
      if (d == 0) { printf " fit %-17s: degenerate x values\n", name[m]; continue }
      k = (n[m]*sxy[m] - sx[m]*sy[m]) / d
      b = (sy[m] - k*sx[m]) / n[m]
      printf " fit %-17s: ~= %.0f MB + %.2f MB per unit of %s  (%d points)\n", name[m], b, k, "'"$AXIS"'", n[m]
    }
    if (skipped) printf " (excluded %d OOM row(s) from the fit)\n", skipped
  }' "$CSV"

echo
echo "Full log : $LOG"
echo "CSV      : $CSV"
echo
echo "To publish these numbers: copy the CSV into results/ with a short '#' provenance"
echo "header (date, agent image, mode), blank the run_log column, and update by hand any"
echo "table that quotes it - see README.md, \"Publishing a number\"."
