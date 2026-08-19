#!/usr/bin/env bash
#
# Shared helpers for the m365_defender memory harness.
#
# Sourced by bin/run.sh (one agent, one or more streams) and bin/sweep.sh (many runs
# along one axis). Both must exercise the same page and the same shipped config, so
# the shared logic lives here once rather than being copied per runner.
#
# Provides:
#   harness_gen_corpus <stream> <work> <pkg> <records> <alerts_per_incident>
#       writes <work>/corpus/corpus-1 and echoes its size in bytes.
#   harness_check_drift
#       verifies the shipped .hbs files still match the rendered configs under
#       streams/ (see streams/hbs.sha256); aborts the run on a mismatch.
#
# Neither function starts containers; the runners own that.

# Layout anchors, derived once so no caller carries a relative path around:
#   HARNESS_ROOT    memcap-agent/            (bin/, streams/, results/, logs/, work/)
#   HARNESS_STREAMS memcap-agent/streams/    per-stream inputs to a run
#   HARNESS_PKG     packages/m365_defender/  the shipping package the configs are rendered from
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_STREAMS="$HARNESS_ROOT/streams"
HARNESS_PKG="$(cd "$HARNESS_ROOT/../../.." && pwd)"

# --------------------------- corpus ---------------------------
#
# Pages come from the corpus generator, so a run needs nothing but this repo: no tenant
# access, no sample file, no network. The output contract is a JSON fragment - compact
# records, each ending in a trailing comma - which mock-config.yml splices between
# `{"value":[` and a closing record.
#
# The templates under <stream>/corpus/ are not guesses: their key set, nesting, array
# cardinality and string lengths are calibrated against a real tenant response, so a
# generated page matches a real one in both bytes and key count (the two things Go's JSON
# decode cost tracks). Only those statistics crossed into the repo; see "Record shapes"
# in README.md.
harness_gen_corpus() {
  local stream="$1" work="$2" pkg="$3" records="$4" alerts_per_incident="$5"

  mkdir -p "$work/corpus"

  # Copy the template so markers can be substituted without touching the source, and
  # strip the trailing newline (the generator appends one after every record; a newline
  # in the template would double up and leave blank lines between records).
  printf '%s' "$(cat "$pkg/template.ndjson")" > "$work/template.ndjson"
  if [ "$stream" = "incident" ]; then
    sed -i.bak "s/__ALERTS_PER_INCIDENT__/$alerts_per_incident/g" "$work/template.ndjson"
    rm -f "$work/template.ndjson.bak"
    echo ">> [$stream] $alerts_per_incident alerts per incident" >&2
  fi
  echo ">> [$stream] generating $records records ..." >&2
  CORPORA_LOCATION="$work/corpus" "$HARNESS_EICGT" generate-with-template \
    "$work/template.ndjson" "$pkg/fields.yml" -c "$pkg/config.yml" \
    -y gotext -t "$records" >/dev/null
  local gen
  gen="$(ls -1 "$work/corpus"/*template.ndjson | head -n1)"
  cp "$gen" "$work/corpus/corpus-1"          # mock globs /var/log/<stream>/corpus-*

  wc -c < "$work/corpus/corpus-1" | tr -d ' '
}

# --------------------------- drift guard ---------------------------
#
# Each stream's config under streams/<stream>/elastic-agent.yml carries a rendered copy
# of the ship logic from the package's .hbs (the region between the SHIP LOGIC markers
# in each file). A copy is only trustworthy while its source is unchanged, so every run
# hashes the shipped .hbs files against streams/hbs.sha256 first and refuses to run on
# a mismatch. Staleness is a loud failure with a re-render instruction, not a silently
# wrong ORR number. The guard detects drift; it does not try to re-render - refreshing
# the copy is a rare, deliberate, human step (instructions are in each config's header).
harness_check_drift() {
  local manifest="$HARNESS_STREAMS/hbs.sha256"
  [ -f "$manifest" ] || { echo "missing $manifest (the drift guard needs it)"; return 1; }
  if (cd "$HARNESS_PKG" && shasum -a 256 --status -c "$manifest"); then
    return 0
  fi
  echo "ERROR: a shipped .hbs changed since the harness configs were rendered:"
  (cd "$HARNESS_PKG" && shasum -a 256 -c "$manifest" 2>/dev/null | grep -v ': OK$') || true
  echo
  echo "Re-copy the changed block into the SHIP LOGIC region of the affected"
  echo "streams/<stream>/elastic-agent.yml (the header of that file says how), then"
  echo "refresh the manifest:"
  echo "  cd $HARNESS_PKG && shasum -a 256 \\"
  echo "    data_stream/alert/agent/stream/httpjson.yml.hbs \\"
  echo "    data_stream/incident/agent/stream/httpjson.yml.hbs \\"
  echo "    data_stream/vulnerability/agent/stream/cel.yml.hbs \\"
  echo "    > $manifest"
  return 1
}

# --------------------------- did the page actually get served? ---------------------------
#
# Match the mock's access-log line, not the endpoint path on its own: at startup the mock
# logs `Setting up rule #N for path "<path>"` for every rule, so a bare path grep reports
# a hit before any request has been made and would happily "confirm" a page that was
# never fetched. The access log is emitted once per served request, so counting it gives
# the true fetch count.
harness_served_pattern() {
  case "$1" in
    alert)         echo '] "GET /v1.0/security/alerts_v2' ;;
    incident)      echo '] "GET /v1.0/security/incidents' ;;
    vulnerability) echo '] "GET /api/machines/SoftwareVulnerabilityChangesByMachine' ;;
  esac
}

# Fetches served for one stream. Counted host-side from the mock's logs so it costs no
# exec into the agent's cgroup (which would ratchet memory.peak).
harness_served_count() {
  local svc="$1" stream="$2"
  docker logs "$svc" 2>&1 | grep -cF "$(harness_served_pattern "$stream")" || true
}

# --------------------------- memory accounting ---------------------------
#
# Reports the cgroup memory breakdown in ONE docker exec. Never call this inside a poll
# loop: each exec joins the container cgroup and ratchets memory.peak up.
#
# Why the breakdown matters. `memory.peak` and `docker stats` count anonymous memory
# (the Go heap - what a leak or a big decode actually costs) AND the page cache the
# container charged while reading files, which for the elastic-agent image is hundreds of
# MB of binaries. Kubernetes reports something different again:
#
#   container_memory_working_set_bytes = memory.current - inactive_file
#
# so it drops reclaimable cache but keeps active cache. Production ORR telemetry uses the
# working-set metric, so comparing it against a raw memory.peak from this harness would
# compare two different quantities. This prints all of them: peak, current, anon, file,
# and a working-set figure computed the way kubelet computes it.
#
# Sets: MEM_PEAK MEM_CURRENT MEM_ANON MEM_FILE MEM_INACTIVE_FILE MEM_WORKINGSET (bytes).
harness_read_memory() {
  local agent="$1" raw
  raw=$(docker exec "$agent" sh -c '
    if [ -f /sys/fs/cgroup/memory.peak ]; then
      echo "peak $(cat /sys/fs/cgroup/memory.peak)"
      echo "current $(cat /sys/fs/cgroup/memory.current)"
      cat /sys/fs/cgroup/memory.stat
    else
      echo "peak $(cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes)"
      echo "current $(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)"
      cat /sys/fs/cgroup/memory/memory.stat
    fi' 2>/dev/null || true)

  MEM_PEAK=$(printf '%s\n' "$raw"  | awk '$1=="peak"{print $2; exit}')
  MEM_CURRENT=$(printf '%s\n' "$raw" | awk '$1=="current"{print $2; exit}')
  MEM_ANON=$(printf '%s\n' "$raw" | awk '$1=="anon"||$1=="total_rss"{print $2; exit}')
  MEM_FILE=$(printf '%s\n' "$raw" | awk '$1=="file"||$1=="total_cache"{print $2; exit}')
  MEM_INACTIVE_FILE=$(printf '%s\n' "$raw" | awk '$1=="inactive_file"||$1=="total_inactive_file"{print $2; exit}')
  MEM_PEAK=${MEM_PEAK:-0}; MEM_CURRENT=${MEM_CURRENT:-0}
  MEM_ANON=${MEM_ANON:-0}; MEM_FILE=${MEM_FILE:-0}; MEM_INACTIVE_FILE=${MEM_INACTIVE_FILE:-0}
  MEM_WORKINGSET=$((MEM_CURRENT - MEM_INACTIVE_FILE))
  if [ "$MEM_WORKINGSET" -lt 0 ]; then MEM_WORKINGSET=0; fi
  return 0
}

# --------------------------- the results CSV ---------------------------
#
# Every run appends one row here, not just the sweeps, because a number that only ever
# existed in a terminal cannot be re-checked later. The tables in README.md and in the
# ORR quote these files by path, so keep the schema stable: adding a column is safe,
# renaming or reordering one breaks comparability with the committed results/.
#
#   axis          what was varied across the rows of this file: scale | alerts_per_incident
#                 | knob | stream. One file per axis.
#   point         the x value. Numeric for a swept axis; a slug for `knob`/`stream`.
#   label         human-readable row name, used verbatim as the first column of knob tables.
#   streams       which agentless streams ran in the agent, `+`-separated.
#   params        free-form `k=v` pairs (page size per stream, alerts_per_incident, ...).
#                 Space-separated so the field stays comma-free and needs no quoting.
#   mode          cold (one page per input) | sustained (back-to-back fetching, drained).
#   *_bytes       as measured, in bytes; convert to MB when quoting, not in the file, so
#                 no precision is lost.
#
# Of the memory columns, exactly two are the ones to publish, each against its own
# production counterpart - mixing them up is how an ORR reads a coincidence as a
# confirmation:
#   peak_bytes    cgroup memory.peak: a true kernel high-water mark, but of anon + page
#                 cache. Compare with production cgroup usage (`usage.bytes`), and with
#                 the pod cap for the OOM boundary. NOT the kubelet metric.
#   workingset_peak_bytes
#                 the largest working set seen during the run, sampled every 3s
#                 (docker stats already subtracts inactive_file on cgroup v2). Compare
#                 with production `workingset.bytes`. A 3s sample can miss a shorter
#                 spike, so it is a lower bound. Empty on rows measured before this
#                 column existed.
# The remaining memory columns are diagnostics: workingset_bytes is a closing snapshot
# (not a peak - it measures which phase of the GC cycle the run stopped in), anon_bytes
# says what the decode itself cost.
#
#   run_log       the console log of this run, under logs/. A local breadcrumb only:
#                 logs/ is not committed, so this is blanked when a CSV is promoted into
#                 results/ rather than left pointing at a file no reviewer has. Provenance
#                 for a published file belongs in its `#` header comment instead.
HARNESS_CSV_HEADER='axis,point,label,streams,params,mode,mem_limit_bytes,gomemlimit,hold_s,total_raw_bytes,peak_bytes,workingset_bytes,workingset_peak_bytes,anon_bytes,oom,agent_image,run_log'

# harness_emit_result_row <csv> <axis> <point> <label> <params> <run_log>
# Reads the run's own state (STREAMS, MEM_*, oom, ...) from the caller's scope.
harness_emit_result_row() {
  local csv="$1" axis="$2" point="$3" label="$4" params="$5" run_log="$6"
  local mode limit_bytes
  mode=$([ "${HOLD_S:-0}" -gt 0 ] && echo sustained || echo cold)
  limit_bytes=$(awk -v s="${MEM_LIMIT:-0}" 'BEGIN{
    n=s; sub(/[A-Za-z]+$/,"",n); u=tolower(substr(s,length(n)+1))
    m=1; if(u=="k")m=1024; else if(u=="m")m=1048576; else if(u=="g")m=1073741824
    printf "%d", n*m
  }' </dev/null)
  mkdir -p "$(dirname "$csv")"
  [ -f "$csv" ] || printf '%s\n' "$HARNESS_CSV_HEADER" > "$csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$axis" "$point" "$label" "$(echo "${STREAMS:-}" | tr ' ' '+')" "$params" "$mode" \
    "$limit_bytes" "${GOMEMLIMIT:-}" "${HOLD_S:-0}" "${TOTAL_PAGE:-0}" \
    "${MEM_PEAK:-0}" "${MEM_WORKINGSET:-0}" "${MEM_WORKINGSET_PEAK:-}" "${MEM_ANON:-0}" \
    "${oom:-unknown}" "${AGENT_IMAGE:-}" "$(basename "${run_log:-}")" >> "$csv"
}

# The two headline figures first, each with the production metric it may be compared
# with; everything else is diagnostics. Publishing more than the two is how a document
# ends up holding a memory.peak against a working-set peak because both say "peak".
harness_print_memory() {
  local mb=1048576
  printf ' memory.peak     : %s (~%s MB)  <- compare with production usage.bytes and the pod cap\n' "$MEM_PEAK" "$((MEM_PEAK / mb))"
  if [ "${MEM_WORKINGSET_PEAK:-0}" -gt 0 ]; then
    printf ' working set peak: ~%s MB   <- compare with production workingset.bytes (3s samples, lower bound)\n' \
      "$((MEM_WORKINGSET_PEAK / mb))"
  fi
  printf ' diagnostics     : end-of-run current ~%s MB (working set ~%s MB), anon (heap) ~%s MB, page cache ~%s MB (inactive ~%s MB)\n' \
    "$((MEM_CURRENT / mb))" "$((MEM_WORKINGSET / mb))" "$((MEM_ANON / mb))" "$((MEM_FILE / mb))" "$((MEM_INACTIVE_FILE / mb))"
}

# --------------------------- shared prerequisites ---------------------------
harness_require_docker() {
  command -v docker >/dev/null || { echo "docker not found"; return 1; }
  docker info >/dev/null 2>&1 || { echo "docker daemon not running"; return 1; }
}

# Locates the corpus generator, which every run needs to build its pages.
harness_find_eicgt() {
  local tool="${1:-$HOME/go/src/github.com/elastic/elastic-integration-corpus-generator-tool}"
  if [ -x "$tool/eicgt" ]; then
    HARNESS_EICGT="$tool/eicgt"
  elif [ -x "$tool/elastic-integration-corpus-generator-tool" ]; then
    HARNESS_EICGT="$tool/elastic-integration-corpus-generator-tool"
  else
    echo "corpus tool binary not found in $tool (build it first: cd $tool && go build -o eicgt .)"
    return 1
  fi
}
