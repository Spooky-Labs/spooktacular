# Metric Catalog

Everything exposed by `GET /metrics` on `spook serve`, in Prometheus text exposition format (version 0.0.4). All series are namespaced under `spooktacular_`.

| Metric | Type | Unit | Meaning | Key SLO / alert |
|--------|------|------|---------|-----------------|
| `spooktacular_running_vms` | gauge | count | Number of VMs currently running on this host | Capacity headroom vs `max_vms` |
| `spooktacular_max_vms` | gauge | count | Kernel-enforced VM ceiling (always 2 on Apple Silicon) | Documents the cap for capacity math |
| `spooktacular_free_disk_gb` | gauge | GiB | Free space on the VM storage volume | Page below 50 GiB — each VM needs ~30 GiB |
| `spooktacular_clones_total` | counter | count | Lifetime VM clone operations | Throughput — combine with histogram quantiles |
| `spooktacular_starts_total` | counter | count | Lifetime VM start operations | |
| `spooktacular_stops_total` | counter | count | Lifetime VM stop operations | |
| `spooktacular_deletes_total` | counter | count | Lifetime VM delete operations | |
| `spooktacular_api_requests_total{method,path}` | counter | count | API requests by method + path | Identify hot endpoints |
| `spooktacular_api_errors_total` | counter | count | 4xx + 5xx responses | Alert on `rate(...[5m]) > 0.1` |
| `spooktacular_clone_duration_seconds` | summary | seconds | Clone wall-clock | p95 < 60s for warm pool SLO |
| `spooktacular_boot_duration_seconds` | summary | seconds | VM boot wall-clock | p95 < 120s |
| `spooktacular_ssh_ready_duration_seconds` | summary | seconds | Time from start to SSH answering | p95 < 180s |
| `spooktacular_runner_registration_duration_seconds` | summary | seconds | VM-boot-to-GitHub-registered | p95 < 300s ("time-to-green") |
| `spooktacular_time_to_first_job_seconds` | summary | seconds | Runner-ready-to-first-job | Diagnoses scheduler lag |
| `spooktacular_scrub_duration_seconds` | summary | seconds | Warm-pool recycle wall-clock | p95 < 45s |
| `spooktacular_cleanup_failures_total` | counter | count | Scrub/delete failures | Alert on any non-zero rate |

## Reading summary metrics

Swift's `MetricsCollector` exposes summaries as `_count` + `_sum` only (no quantile buckets). To derive p95 / p99 in Prometheus, enable histogram collection via a recording rule:

```yaml
groups:
  - name: spooktacular-summaries
    interval: 30s
    rules:
      - record: spooktacular_boot_duration_seconds:rate_sum
        expr: rate(spooktacular_boot_duration_seconds_sum[5m])
      - record: spooktacular_boot_duration_seconds:rate_count
        expr: rate(spooktacular_boot_duration_seconds_count[5m])
      - record: spooktacular_boot_duration_seconds:avg
        expr: spooktacular_boot_duration_seconds:rate_sum / spooktacular_boot_duration_seconds:rate_count
```

Or — preferred for real quantile SLOs — add a proxy layer (e.g., an OpenTelemetry collector) that converts these summaries into histograms with sensible bucket boundaries.

## Extending the catalog

New metrics belong in `Sources/SpookApplication/Metrics.swift`. The guiding rules:

1. **Actor-isolated counters only.** No shared-mutable state outside the actor.
2. **Keep cardinality bounded.** API request labels are already cardinality-dense (method × path); don't add a third label without a hard upper bound.
3. **Every metric gets an alert or a dashboard panel.** Metrics no one looks at waste storage and attention.
