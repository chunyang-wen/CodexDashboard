# Metrics specification

## Token metrics

| Metric | Calculation | Notes |
| --- | --- | --- |
| Total tokens | Final `total_token_usage.total_tokens` per session | Falls back to `threads.tokens_used` |
| Input tokens | `total_token_usage.input_tokens` | Includes cached reads and cache writes |
| Cached input | `cached_input_tokens` | Subset of input; never add it again to total |
| Cache-write input | `cache_write_input_tokens` | Tracked separately because some models charge a multiplier |
| Uncached input | `max(0, input - cached - cache-write)` | Used for cost estimation |
| Output tokens | `output_tokens` | Includes reasoning output |
| Reasoning output | `reasoning_output_tokens` | A diagnostic subset of output |
| Cache hit rate | cached input / input | Indicates prompt reuse and potential cost efficiency |

For trend and selected-range totals, consecutive cumulative token events are differenced and the delta is assigned to the event timestamp and active model. If a counter resets, the new value is treated as a fresh delta. While enrichment is still running, indexed sessions temporarily fall back to their last-update time and indexed total.

## Time and responsiveness

| Metric | Calculation | Interpretation |
| --- | --- | --- |
| Session span | `updated_at - created_at` | Includes idle time and should not be called working time |
| Agent runtime | Sum of `task_complete.duration_ms` | Wall time spent inside completed turns, including model and tool waits |
| Average first-token latency | Mean `task_complete.time_to_first_token_ms` | Startup responsiveness |
| Median turn time | P50 completed-turn duration | Typical turn experience |
| P95 turn time | P95 completed-turn duration | Slow-tail experience |
| Completed turns | Count of `task_complete` events | Completed interaction units |
| Aborted turns | Count of `turn_aborted` events | Interrupted/cancelled work |

The events do not reliably separate model compute, local tool execution, network waits, approvals, and subprocess runtime, so the dashboard intentionally calls the aggregate **agent runtime** rather than model time.

## Accumulated metrics

- Daily, weekly, and monthly tokens by event timestamp
- Daily, weekly, and monthly agent runtime by turn completion time
- Estimated cost by period and model
- Project totals: sessions, tokens, runtime, active days, last activity, dominant model
- Model totals: sessions, token mix, cache hit rate, runtime, estimated cost
- Portfolio totals: projects, sessions, active days, tokens, tool calls, completion/abort counts
- Tool totals: tool name, call frequency, sessions, attributed tokens, and attributed API-equivalent token cost
- Skill totals: skill name, activation frequency, sessions, attributed tokens, and attributed API-equivalent token cost

Period boundaries use the Mac's current calendar and time zone.

## Cost and billing

The local estimate is applied to each token delta using the model active when that delta was recorded:

```text
(uncached input / 1M × input rate)
+ (cached input / 1M × cached rate)
+ (cache-write input / 1M × input rate × write multiplier)
+ (output / 1M × output rate)
```

Reasoning tokens are not added separately because they are included in output. Rate cards are versioned by effective date, and every token delta is priced with the schedule in effect on its event date. Historical schedules are stored with the durable metric archive, so adding a future price does not rewrite prior estimates.

The app checks models.dev at most once every 24 hours and caches the response with HTTP validators. A validated price change creates a new schedule effective at the successful fetch time; it never mutates an earlier schedule. Invalid, unavailable, or unexpectedly large responses are ignored in favor of the last valid cached catalog or bundled local schedules. The UI always identifies whether pricing came from models.dev, its cache, or the bundled fallback. OpenAI's Models API supplies model identity and availability but does not currently expose token prices, so models.dev is explicitly treated as a third-party metadata source rather than an invoice authority.

The estimate does not include hosted-tool call charges, regional-processing uplifts, long-context multipliers, Batch/Flex discounts, negotiated rates, credits, taxes, or ChatGPT subscription terms. **It is not an invoice.** Actual API spend should come from the OpenAI Organization Costs endpoint and may only be attributable to OpenAI API project IDs, not local filesystem projects.

For tool-level analysis, every token delta is attributed to tool calls since the previous token event. When multiple calls precede one event, the token categories are divided evenly without changing the total. This is an estimate of the model-token work associated with each tool, not the tool vendor's own fee. Calls without a later token event remain visible in frequency totals with zero attributed cost.

Skill activation has no dedicated rollout event, so the dashboard uses an explicit read of `<skill>/SKILL.md` as its auditable activation signal. Following token deltas are divided among skills activated since the previous token event. Skill attribution overlaps tool attribution and must not be added to it or to the total estimate as a separate charge.

**Cost coverage** is the portion of tokens for which the dashboard has both a detailed input/output breakdown and a recognized model price. Always show coverage beside estimates.
