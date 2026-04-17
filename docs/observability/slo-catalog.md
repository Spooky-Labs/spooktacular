# SLI / SLO Catalog

This catalog is the authoritative mapping from Spooktacular SLOs to the Prometheus queries that measure them and the alert rules that fire when a budget is being burned.

Every SLO has four components:

1. **SLI** (Service Level Indicator) — a measurable property of the system.
2. **SLO** (Service Level Objective) — the target value of the SLI.
3. **Error budget window** — the period over which the SLO is evaluated.
4. **Alert rule** — the Prometheus rule (in [`alerts.yml`](alerts.yml)) that pages when the budget is burning faster than the target.

The framework follows the [Google SRE Workbook § Implementing SLOs](https://sre.google/workbook/implementing-slos/). For each SLO we track a **burn rate** rather than raw threshold breaches — a 100× burn rate over 5 minutes is a page, a 10× burn rate over an hour is a ticket.

## User-facing SLOs

These are the SLOs that go in the tenant-facing SLA document. Missing one is a breach that triggers customer credits.

| SLI | Definition | PromQL | SLO target | Window | Alert |
|-----|------------|--------|-----------|--------|-------|
| Clone latency (p95) | Time from `POST /vms/clone` to VM registered as ready | `histogram_quantile(0.95, rate(spooktacular_clone_duration_seconds_bucket[5m]))` | < 5 s | 30d rolling | `SpooktacularCloneLatencyHigh` |
| Boot duration (p99) | Time from `spook start` to first SSH response | `histogram_quantile(0.99, rate(spooktacular_boot_duration_seconds_bucket[5m]))` | < 90 s | 30d rolling | `SpooktacularBootLatencyRegression` |
| API request latency (p95) | Time to serve any `/v1/*` request, 200–299 | `histogram_quantile(0.95, rate(spooktacular_api_request_duration_seconds_bucket{status=~"2.."}[5m]))` | < 500 ms | 30d rolling | `SpooktacularAPIRequestP95High` |
| API error rate | 4xx + 5xx / total | `sum(rate(spooktacular_api_errors_total[5m])) / clamp_min(sum(rate(spooktacular_api_requests_total[5m])), 1)` | < 1 % | 30d rolling | `SpooktacularAPIErrorRateHigh` |
| Runner idle-to-claimed (p95) | Time from pool gains a VM to GitHub claims it | `histogram_quantile(0.95, rate(spooktacular_runner_claim_duration_seconds_bucket[5m]))` | < 30 s | 30d rolling | `SpooktacularRunnerClaimP95High` |

## Platform SLOs

These are operator-facing SLOs — their breach is an internal signal that capacity or audit pipelines are rotting, before it affects tenants.

| SLI | Definition | PromQL | SLO target | Window | Alert |
|-----|------------|--------|-----------|--------|-------|
| Audit write error rate | Failed audit appends / attempted | `sum(rate(spooktacular_audit_write_errors_total[5m])) / clamp_min(sum(rate(spooktacular_audit_writes_total[5m])), 1)` | < 0.1 % | 24h | `SpooktacularAuditWriteErrors` |
| Reconcile queue depth (p95) | RunnerPool reconciler backlog | `histogram_quantile(0.95, rate(spooktacular_reconcile_queue_depth_bucket[5m]))` | < 10 items | 24h | `SpooktacularReconcileQueueDeep` |
| TLS cert expiry | Minimum days until any serving cert expires | `min(spooktacular_tls_cert_days_until_expiry)` | > 14 days | instantaneous | `SpooktacularTLSCertExpiringSoon` |
| Merkle gap detection | Time to detect a broken audit chain | `max(spooktacular_audit_gap_detection_seconds)` | < 15 min | instantaneous | `SpooktacularAuditMerkleGap` |
| Watch stream uptime | % of time K8s watch is connected | `avg_over_time(up{job="spook-controller"}[5m])` | > 99.9 % | 7d rolling | `SpooktacularControllerWatchStreamDown` |

## Error budget accounting

Each SLO has an implicit budget: `(1 - SLO) × window`. For a 99.9 % target over 30 days the budget is 43 m 12 s of failure per window. When you’ve burned more than half the budget in the first half of the window, the relevant alert promotes from `ticket` to `page` severity.

## Adding a new SLO

1. Emit the SLI in [`Sources/SpookApplication/Metrics.swift`](../../Sources/SpookApplication/Metrics.swift). Keep cardinality bounded — one new label can quintuple your series count.
2. Add a row to this catalog with the PromQL, target, and window.
3. Add an alert rule in [`alerts.yml`](alerts.yml) — one multi-window burn-rate rule per SLI is the norm. See the Google SRE book’s “Multiwindow, Multi-Burn-Rate Alerts” pattern.
4. Add a dashboard panel to one of the dashboards in this directory so the SLI surfaces next to its SLO budget.
5. Wire the runbook link in the alert annotation at `https://spooktacular.app/docs/DISASTER_RECOVERY#<anchor>`.

Every step is required. A metric without an alert is dead weight. A metric without a dashboard is unused. A metric without a runbook just wakes on-call up with “what does this mean?”.
