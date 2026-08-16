# Codex Dashboard

A local-first macOS dashboard and CLI for understanding Codex activity by project, session, model, time, tokens, and API-equivalent cost.

The importer opens `~/.codex/state_5.sqlite` read-only and enriches indexed sessions from rollout JSONL files. It never reads authentication files and never uploads session content. The only routine network request is an anonymous pricing-catalog download from `https://models.dev/api.json`; it contains no local metrics or identifiers.

## Run

```bash
swift run CodexDashboard
swift run codex-metrics summary
swift run codex-metrics periods --by month --enrich
swift run codex-metrics sessions --project storyviz --enrich
```

For Xcode development, open `CodexDashboard.xcodeproj`, choose the shared **CodexDashboard** scheme, and press Run. The project also includes the **CodexMetricsCLI** scheme and the `CodexMetricsCoreTests` test target. The Xcode project and `Package.swift` reference the same source files.

The dashboard presents indexed metrics immediately, then enriches timing and token breakdown for the selected date range with determinate progress. Range changes update the display independently without cancelling an active scan; after that scan settles, enrichment extends to any newly in-scope rollouts. This keeps the range control responsive while the default 30-day view still avoids parsing the full archive. Parsed metrics and byte checkpoints—not conversation text—are transactionally persisted in `~/Library/Application Support/CodexDashboard/metrics-v1.sqlite` using WAL mode. Growing append-only rollouts resume after the last complete newline instead of being rescanned from the beginning; an actively written partial JSON record is never checkpointed, and oversized tool-result lines are discarded as a stream once identified. Durable session history lives in the same database, so source-log removal and parser-cache invalidation do not erase historical metrics. Existing `rollouts-v4.json` and `history-v1.json` data is migrated automatically. Later launches only parse appended bytes or reparse files that were replaced.

While the dashboard remains open, one low-priority in-process task checks the Codex index/WAL and known rollout file metadata roughly every 20 seconds with jitter. It quietly enriches only new or changed sessions, pauses in Low Power Mode or under serious thermal pressure, and uses exponential retry backoff after failures. It does not launch a helper process or run after the app quits. The CLI stays index-only unless `--enrich` is passed.

Use **Usage & Billing → Scan All History** once to preserve every rollout currently available. Export and import on the same screen create or restore a portable JSON archive containing metric events, session metadata, and effective-dated price schedules—never conversation content or credentials.

## Product plan

### Implemented MVP

- Read-only project and session discovery from the Codex SQLite index
- Resilient fallback extraction from rollout JSONL
- Input, cached input, cache-write, output, reasoning, and total tokens
- Session span, completed-turn agent runtime, average first-token latency, median/P95 turn time
- Tool-call, message, abort, active-day, project, source, branch, and model dimensions
- Daily, weekly, and monthly token/runtime/cost aggregation
- Live local subscription snapshot with plan, quota windows, reset times, credits, and limit status
- Pointer-hover chart inspection with exact token, runtime, cost, and session values
- API-equivalent cost estimates with explicit coverage and invoice caveats
- Native SwiftUI views for overview, hierarchical projects → sessions, models, billing, and metric definitions
- CLI summary, table output, filtering, time periods, and JSON export
- Durable metric history with effective-dated pricing and portable JSON import/export
- Daily dynamic pricing refresh from models.dev with validated local caching and bundled offline fallback
- Current per-model rate cards and locally persisted price-change charts

### Next iterations

1. Add an opt-in OpenAI Organization Costs provider using a Keychain-held admin key; keep actual API costs separate from local-folder attribution.
2. Add a signed first-party pricing source if OpenAI exposes one, plus user pricing overrides.
3. Add CSV export, budget thresholds, anomaly detection, and optional menu-bar weekly summaries.
4. Add a signed, sandbox-aware Xcode distribution target with user-selected Codex-directory access.

## Metric semantics

See [METRICS.md](METRICS.md). The most important distinction is:

- **Agent runtime** is the sum of completed Codex turn durations.
- **Session span** is creation-to-last-update and includes idle gaps.
- **Estimated cost** is an API list-price equivalent, not a ChatGPT subscription invoice.

## Privacy and compatibility

Codex storage is an implementation detail and may evolve. The reader checks available SQLite columns and uses the rollout parser for missing details. The app is strictly read-only with respect to `~/.codex`; it writes only its own parser cache and durable metric history. Exported history contains session metadata and aggregate token events, but never conversation content or authentication data.
