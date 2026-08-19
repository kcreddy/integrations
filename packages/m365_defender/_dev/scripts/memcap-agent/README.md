# m365_defender agentless worst-case memory harness

Memory test for the three agentless m365_defender inputs, built for the agentless Operational Readiness Review (ORR). It answers one question — **how much memory does an agentless pod running this integration need, and what would it take to need less?**

Two properties of the measurement are load-bearing:

- **Concurrent.** A pod runs every enabled stream in a single `elastic-agent`, and every httpjson/cel input lives in the same beat process and the same Go heap. Measuring streams separately and adding the results is wrong in both directions (the process baseline is paid once, but the decode peaks share one heap and one GC cycle), so the default run is one agent with one page per enabled stream. Single-stream runs (`STREAMS=incident bin/run.sh`) exist for attribution — which stream causes a peak — never as addends.
- **Sustained.** Production pods fetch back-to-back while catching up, decoding each page while the previous one is still uncollected garbage, and that is where the production peaks come from. A cold single page understates them by ~2x, so sizing numbers come from sustained runs (`DRAIN=1` with a short `INTERVAL`); cold runs are the cheap way to measure the shape of a curve.

It is a bespoke Docker + cgroup harness, **not** an `elastic-package` benchmark: the real `elastic-agent` image, run the way `agentless-controller` deploys it, against the `elastic/stream` mock serving one big API page, under a Docker `--memory` cap.

The memory driver is a single **API page**, and the shape differs per stream:

| stream          | input    | endpoint                                   | page driver |
| --------------- | -------- | ------------------------------------------ | ----------- |
| `alert`         | httpjson | `/v1.0/security/alerts_v2`                 | records × per-alert size; server caps `$top` at 1000 |
| `incident`      | httpjson | `/v1.0/security/incidents` (`$expand=alerts`) | incidents × alerts-per-incident × per-alert size (nested split, `keep_parent`) |
| `vulnerability` | cel      | `/api/machines/SoftwareVulnerabilityChangesByMachine` | records × per-record size; `pageSize=10000` hard-coded; CEL re-encodes each record |

Scope: the three streams agentless runs. The `event` data stream is deliberately absent — its input is `azure-eventhub`, which agentless does not support, so it never contributes to an agentless pod.

## Layout

```
memcap-agent/
├── bin/                    # everything that runs
│   ├── run.sh              # ONE agent, one page per stream in STREAMS (default: all three)
│   ├── sweep.sh            # repeat run.sh along one axis: scale | alerts_per_incident
│   ├── lib.sh              # corpus build, drift guard, memory accounting, the results CSV
│   └── fake-es.py          # draining sink (sustained mode)
├── streams/                # everything a run reads, per stream
│   ├── hbs.sha256          # hashes of the shipped .hbs the configs were rendered from
│   ├── alert/
│   │   ├── elastic-agent.yml      # rendered config; ship logic between SHIP LOGIC markers
│   │   ├── mock-config.yml        # token + alerts_v2 page serving the corpus
│   │   └── corpus/                # template.ndjson, config.yml, fields.yml
│   ├── incident/                  # as above; include_alerts=true, nested split
│   └── vulnerability/             # as above; CEL program rendered from cel.yml.hbs
└── results/                # the measurements the documents publish (committed)
    ├── scale.csv                  # cold, all page sizes scaled together
    ├── alerts-per-incident.csv    # cold, shipped page sizes, alerts[] swept
    ├── sustained.csv              # back-to-back fetching - the production-comparable mode
    ├── knobs.csv                  # the same worst case with one thing changed per row
    └── per-stream.csv             # one stream at a time: the per-stream driver
```

Runs also write `work/` (the generated corpora) and `logs/` (console output and the CSV of every run). Neither is committed — see `.gitignore`. A run needs nothing but this directory, Docker and the corpus generator: no tenant access, no sample file, no network beyond the image pulls.

## Keeping the configs in sync with the shipping inputs

The numbers are only meaningful if the harness runs what the package ships. Each `streams/<stream>/elastic-agent.yml` carries a **rendered copy** of the ship logic — the CEL `program:` for `vulnerability`, the `request.transforms` + `response.pagination` + `response.split` + `cursor` block for `alert`/`incident` — between `SHIP LOGIC` markers, with two deliberate deviations noted in each file's header (`batch_size` neutralised to a huge sentinel so the real time-boundary pagination halts after one page, and a fixed `initial_interval`).

The copy is only trustworthy while its source is unchanged, so `bin/run.sh` hashes the shipped `.hbs` files against `streams/hbs.sha256` before every run and refuses to run on a mismatch, printing the refresh instructions. Refreshing is a rare, deliberate step: re-copy the changed block between the markers (each config's header says exactly how) and update the hash file. `run.sh` also asserts that the merged config has one input per enabled stream and that each mock config still has exactly its token rule plus one data rule, so a config that grows a rule fails loudly instead of quietly losing an endpoint.

## Record shapes

Go's JSON decode cost tracks the **number of keys and containers** it allocates, not just the byte count, so a corpus template that hits the right size with the wrong shape gets the memory wrong. The templates in `streams/<stream>/corpus/` are calibrated against a real tenant response: the response was sanitised offline and only its statistics — key set, byte/key/container counts, array cardinalities — crossed into the repo, as the key set and `repeat`/`until` counts in `template.ndjson`. **No customer payload is stored here, and no runner reads one.**

The generated `alert` record matches the real mean within ~2% on bytes, keys, containers and string bytes per record; `incident` (a 21-key base record plus an `alerts[]` array of the alert shape, which is what `$expand=alerts` returns) lands within 0.4% at page level. Two deliberate deviations: records are uniform (only page totals matter to a decode peak), and `alerts[]` per incident is a swept parameter rather than a measured value, because the sample tenant was quiet and it is the one page-size input nothing bounds. `vulnerability` has no tenant response to calibrate against, so its ~1 KB record is modelled on the package's own pipeline test data — the one page input still uncalibrated.

Getting the shape roughly right (key count, nesting, array sizes) is what matters; run-to-run GC noise on sustained runs is ~16%, so precision far beyond that buys nothing.

## Prerequisites

- Docker running (pulls `elastic-agent`, `observability/stream`, `curlimages/curl`, and `python:3.12-alpine` when `DRAIN=1`). Check free memory in the Docker VM first: a run that needs more than the VM has left is reclaimed by the host and the numbers are meaningless. Stop other stacks (e.g. `elastic-package stack down`) before large caps.
- The corpus generator built once (every run builds its pages with it):
  ```
  cd elastic-integration-corpus-generator-tool && go build -o eicgt .
  ```
  Point `TOOL=` at that repo if it is not at the default path.

## What to run

```
# cold: one page per stream at the shipped production page sizes
bin/run.sh

# sustained: inputs keep fetching and the output drains - compare with production telemetry
DRAIN=1 INTERVAL=10s HOLD_S=300 MEM_LIMIT=3g bin/run.sh

# fit the pod curve, two axes
AXIS=scale               SWEEP_CAP=3g POINTS="0.25 0.5 1 2 3 4 5" bin/sweep.sh
AXIS=alerts_per_incident SWEEP_CAP=3g POINTS="25 50 100 200 400"  bin/sweep.sh

# attribution: what does one stream cost on its own?
STREAMS=incident ALERTS_PER_INCIDENT=400 bin/run.sh
```

One-off "what is this knob worth" comparisons are plain `run.sh` invocations sharing a CSV, each changing one thing against the sustained worst case (this is how `results/knobs.csv` was measured):

```
common="DRAIN=1 INTERVAL=10s HOLD_S=300 ALERTS_PER_INCIDENT=400 RESULTS_CSV=logs/knobs.csv RESULT_AXIS=knob"

# baseline: nothing changed
env $common RESULT_POINT=1 RESULT_LABEL="baseline (nothing changed)" MEM_LIMIT=3g bin/run.sh

# does GOMEMLIMIT alone hold the worst case inside 1Gi?
env $common RESULT_POINT=2 RESULT_LABEL="GOMEMLIMIT=850MiB (nothing else)" \
  GOMEMLIMIT=850MiB MEM_LIMIT=1g bin/run.sh

# do bounded page sizes hold it inside 1Gi?
env $common RESULT_POINT=3 RESULT_LABEL="incident batch_size 50->10 + vulnerability pageSize 10000->1000" \
  INCIDENT_EVENTS=10 VULN_EVENTS=1000 MEM_LIMIT=1g bin/run.sh
```

Key env: `STREAMS` (which streams the agent runs; default all three), `ALERT_EVENTS` / `INCIDENT_EVENTS` / `VULN_EVENTS` (records per page, default = the shipped production page sizes), `ALERTS_PER_INCIDENT`, `MEM_LIMIT`, `DRAIN=1` (drain through `fake-es.py`), `INTERVAL` + `HOLD_S` (sustained mode), `GOMEMLIMIT` (soft heap ceiling; agentless sets none), `STACK_VERSION` / `AGENT_IMAGE` (which build to profile), `KEEP=1` (leave containers up), `TOOL` (corpus generator path). Sweeps add `AXIS`, `POINTS`, `SWEEP_CAP`.

Sustained mode needs `DRAIN=1`. With an unreachable output the queue fills, the input blocks on publish and no second page is ever decoded — the opposite of a catching-up pod.

### Publishing a number

Every run appends a row to a CSV (`logs/runs.csv` for a bare run, one file per sweep otherwise); the schema is documented at the top of `bin/lib.sh`. To publish a measurement: copy the CSV into `results/`, blank the `run_log` column (it names a file under `logs/`, which is not committed), and lead the file with a `#` comment saying when and how it was measured. The tables below and the ORR quote the committed CSVs by path — when a result is re-measured, update the CSV first and then every table that quotes it. `results/` is committed because a number whose provenance is a terminal that has since been closed cannot be re-checked.

### Which agent version to profile

Serverless agentless runs **elastic-agent `main`**, shipped as the `docker.elastic.co/observability-ci/ecp-elastic-agent-service:git-<sha>` image, which rotates every ~1-2 days as `main` advances (the pod's `agent.version` metric field is stale metadata). `main` currently declares **9.6.0**, so the default `STACK_VERSION` is `9.6.0-SNAPSHOT`, the standard publicly pullable proxy for the same code line — not a `cloud-release` GA tag, which is the stateful fleet. For maximum fidelity set `AGENT_IMAGE` to the exact serverless build (requires registry access). Record the exact build measured in the ORR, and lean on the memory *driver* (`page_size x record_size x multiplier`) as the version-independent quantity.

## Output

`bin/run.sh` prints a `RESULT` block and appends the same numbers to the results CSV. Two figures are published, each with its own production counterpart — comparing across the pair is comparing two different quantities:

- **`memory.peak`** — cgroup high-water mark, a true maximum, not sampled. It counts page cache as well as anonymous memory, so its production counterpart is the cgroup usage metric (`usage.bytes`) and the pod cap, **not** `kubernetes.container.memory.workingset.bytes`. On an OOM run it is pinned at the cap and is *not* the true peak — use a bigger cap.
- **`working set peak`** — the largest `memory.current - inactive_file` seen during the run (the arithmetic kubelet uses), sampled every 3s. **This is the figure to hold against `workingset.bytes` telemetry.** A spike shorter than the sampling interval can be missed, so it is a lower bound.

Everything else in the block (end-of-run current/working set, anon, page cache, per-stream fetch counts, OOM flag) is diagnostics. In particular the end-of-run working set on a sustained run measures which phase of the GC cycle the run stopped in, not a peak — never quote it as one.

`bin/sweep.sh` prints a summary table plus a least-squares fit `y ≈ base + k·x` over the non-OOM rows: `base` is the whole-container floor (agent + beat + monitoring, paid once), `k` is what each extra unit of load costs, and the OOM boundary is where `base + k·x` reaches the cap.

## Result: per pod (all three agentless streams in one agent)

Measured with generated pages calibrated to a real response (see **Record shapes**), agent `9.6.0-SNAPSHOT`, 2026-08-04 (cold) and 2026-08-12 (sustained). Tables are quoted from the committed CSVs named above each one; the CSV is the artifact, the table is a view of it.

**Cold, one page per stream, page sizes scaled together** (from `results/scale.csv`; alerts-per-incident 100; the bold row is the shipped configuration):

| scale | alert | incident | vuln | raw pages | working set |
| --- | --- | --- | --- | --- | --- |
| 0.25 | 250 | 12 | 2,500 | 10.2 MB | 214 MB |
| 0.5 | 500 | 25 | 5,000 | 20.8 MB | 286 MB |
| **1** | **1,000** | **50** | **10,000** | **41.6 MB** | **400 MB** |
| 2 | 2,000 | 100 | 20,000 | 83.1 MB | 720 MB |
| 3 | 3,000 | 150 | 30,000 | 124.9 MB | 938 MB |
| 4 | 4,000 | 200 | 40,000 | 166.5 MB | 1,175 MB |
| 5 | 5,000 | 250 | 50,000 | 208.0 MB | 1,529 MB |

```
working_set ≈ 146 MB + 6.47 × raw_page_bytes        (R² = 0.996, 7 points)
```

which gives a raw page budget per cap, shared across all three streams, of **512Mi ≈ 57 MB · 1Gi ≈ 136 MB · 2Gi ≈ 294 MB · 4Gi ≈ 610 MB**. The intercept is the whole-container floor and matches the fleet-median steady state in the ORR telemetry (~195 MB) once a small real page is added.

A cold single page is the noisiest measurement here: repeat runs at the shipped page sizes landed between 368 and 448 MB (±10%), because where the plateau detector stops depends on GC timing. The sustained numbers below are steadier and are what the sizing rests on.

Scales above 1 measure `k`; they are **not** tenants that can exist. `alert` cannot exceed 1,000 records (Graph clamps `$top`) and `vulnerability` is fixed at 10,000 (`pageSize` is hard-coded in the CEL program). Which leaves one uncapped input:

**Cold, alerts-per-incident swept with every page size at its shipped value** (from `results/alerts-per-incident.csv`):

| alerts/incident | raw pages | working set |
| --- | --- | --- |
| 25 | 21.0 MB | 329 MB |
| 50 | 27.8 MB | 360 MB |
| 100 | 41.6 MB | 368 MB |
| 200 | 69.0 MB | 505 MB |
| 400 | 123.8 MB | 780 MB |

```
working_set ≈ 280 MB + 1.22 MB × alerts_per_incident        (R² = 0.983, 5 points)
```

`alerts[]` on one incident costs ~1.2 MB of pod memory per alert, because `$expand=alerts` plus the nested split with `keep_parent` turns each embedded alert into an event that also carries its parent. Nothing in the package or the API bounds it.

### Explaining the production peak

A cold page does not explain the telemetry: even 400 alerts per incident only reaches 780 MB, while production working set peaks at 1,377–1,507 MB and production cgroup usage peaks at ~1,515 MB (p95) to ~1,578 MB (max). The missing factor is back-to-back fetching — `alert` polls every 5m and `incident` every 1m against a 24h initial lookback, and the CEL stream re-enters immediately while `want_more` is true against a 336h lookback, while `GODEBUG=madvdontneed=1` keeps freed pages charged to the cgroup. The ORR telemetry says so directly: the hottest pods are the *backfilling* ones. `DRAIN=1` plus a short `INTERVAL` reproduces it (from `results/sustained.csv`):

| alerts/incident | run | raw pages | peak | working set peak |
| --- | --- | --- | --- | --- |
| 100 | run 1 | 41.6 MB | 719 MB | 714 MB |
| 400 | run 1 | 123.8 MB | 1,836 MB | 1,664 MB |
| 400 | run 2 | 123.8 MB | 1,915 MB | 1,675 MB |
| 400 | run 3 | 123.8 MB | 1,835 MB | 1,603 MB |

Against the cold runs at the same page sizes, sustained fetching costs ~1.9× the cold single-page figure at 100 alerts per incident and ~2.1–2.45× at 400, on both metrics.

The 400 point is recorded three times because the sizing decision rests on it. Counting the knob ladder's baseline row (`results/knobs.csv` row 1), a fourth run of the same configuration, `memory.peak` spans **1,835–2,135 MB** and the working-set peak **1,603–1,932 MB** over identical inputs — a 16% spread that is GC timing, not noise that averages away, so quote the **maximum** and never a single run.

Compare metric for metric: the harness `memory.peak` maximum (2,135 MB) sits above production cgroup usage (max ~1,578 MB), and the harness working-set peak maximum (1,932 MB) sits above production `workingset.bytes` (peak 1,507 MB). On both pairings the worst case *bounds* the observed telemetry rather than matching it, which is what a deliberately constructed worst case should do. (An earlier 2026-08-04 run of this point, transcribed from console output, read 1,516 MB and appeared to land on the production p95; it is not reproducible — all four committed runs are 21–41% above it — and is superseded by `results/sustained.csv`.)

Fitting the four sustained runs gives `sustained_peak ≈ 337 MB + 3.81 MB × alerts_per_incident` (R² = 0.996), putting the OOM boundary at roughly **180 alerts/incident for 1Gi** and **450 for 2Gi**. The repeats pin down the spread at 400, not the shape of the curve, so treat those boundaries as the right order of magnitude rather than precise thresholds.

At 400 alerts per incident the measured worst case is **2,135 MB**, above 2Gi (2,048 MB) — a pod at that request would OOM, so 2Gi is off the table for this worst case. 3Gi leaves ~30% headroom and 4Gi ~48%. Getting under 2Gi with headroom means changing the shape of a poll rather than the size of the pod:

### What each knob is worth

Every row is the same sustained worst case with one thing changed (from `results/knobs.csv`; the exact commands are under **What to run**). Rows 2 and 3 run at a 1Gi cap because the question they answer is whether the mitigation holds the worst case inside 1Gi:

| configuration | cap | peak | working set peak |
| --- | --- | --- | --- |
| baseline (nothing changed) | 3Gi | 2,136 MB | 1,932 MB |
| GOMEMLIMIT=850MiB (nothing else) | 1Gi | 1,024 MB | 950 MB |
| incident batch_size 50->10 + vulnerability pageSize 10000->1000 | 1Gi | 651 MB | 640 MB |

- **`GOMEMLIMIT`** is the only lever that needs no package change, and it works on this peak because the peak is *garbage*: a soft ceiling makes Go collect it sooner. The pod survived 5 minutes of the worst case inside 1Gi with identical throughput — but `memory.peak` pinned at exactly 1,024 MB, meaning the run consumed the entire cgroup and survived on reclaim. That is a mechanism working, not a margin to ship on; it is also no fix if one page's *live* data exceeded the ceiling. Treat the mechanism as proven and the value as unset.
- **Bounding the page sizes** is the durable fix: 651 MB, inside 1Gi with 36% headroom, a 3.3× reduction, and it removes the unbounded term rather than absorbing it. `incident.batch_size` is already a package variable (default 50); `vulnerability`'s `pageSize=10000` is hard-coded in the CEL program and would need a code change to expose.
- **`include_alerts=false`** is not in the table because it removes the driver outright (incident pages become ~0.05 MB) rather than scaling it. The alerts it drops are largely the same documents the `alert` data stream already collects, so it is worth considering on cost grounds independent of memory.
- **`preserve_original_event`** stays off in all of these; turning it on retains the raw JSON alongside the decoded event and would roughly double the per-event cost.

## Result: per stream (attribution, not sizing)

One stream enabled at a time, page size swept, cap 6Gi (from `results/per-stream.csv`). This establishes the memory **driver** per stream, which is what the ORR asks for. **These do not add up to a pod** — each run pays the whole-container baseline once, so summing the three bases triple-counts it; the per-pod numbers above are the sizing basis.

| stream | fit (base + k·page) | 1Gi boundary | 512Mi boundary |
| --- | --- | --- | --- |
| `alert` | ≈126 MB + 11.43·page | ~79 MB / ~14,343 recs | ~34 MB / ~6,170 recs |
| `incident` | ≈170 MB + 7.27·page | ~117 MB / ~213 recs | ~47 MB / ~85 recs |
| `vulnerability` | ≈146 MB + 10.14·page | ~87 MB / ~100,489 recs | ~36 MB / ~41,884 recs |

`incident` counts are incidents **at 100 alerts each** (~576 KB per incident). These are `memory.peak` (page cache included) rather than working set, because this sweep predates the working-set accounting. Agent build for all committed results: `docker.elastic.co/elastic-agent/elastic-agent:9.6.0-SNAPSHOT`, 2026-08-03/04 (cold, per-stream) and 2026-08-12 (sustained, knobs).

## Notes / deviations from a live agentless pod

- By default the output points at an unreachable Elasticsearch: events are held, so the decoded page stays resident (conservative worst case). This measures memory *capacity*, not throughput. `DRAIN=1` replaces it with a local sink, which sustained mode needs.
- The sink drains as fast as the agent can push; agentless applies a ratelimit processor on the export path, and that backpressure keeps events resident for longer, so the sustained numbers here are if anything a slight underestimate. The published worst case still bounds production, which is the property the sizing rests on.
- httpjson `batch_size` is neutralised to a huge sentinel in the rendered configs to force a single page; the pagination that runs is still the real 5.15.1 time-boundary shape (`$filter … gt`, `$skip=0`), just held to one page. Production defaults: `alert` `batch_size=1000` (the Graph `$top` cap), `incident` `batch_size=50`.
- State store is local disk here (agentless uses Elasticsearch); the cursor is a few KB and irrelevant to the decode peak. APM is off.
- `alert` and `incident` pages are calibrated against a real response; `vulnerability` is not (no response was available). Its 10,000-record page contributes only ~8 MB of the 123 MB worst case, so a wrong per-record size there moves the total little — but it is the one input whose realism is unverified.
- Agentless sets no `GOMEMLIMIT`; runs that pass one are exploring a mitigation, not measuring the shipped configuration.
- If the cel input ever adopts the CEL `emit` macro / streaming decode (elastic/beats#51279), the vulnerability memory profile changes fundamentally and this harness plus the ORR numbers must be re-run.
