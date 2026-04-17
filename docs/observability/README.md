# Spooktacular Observability Kit

Ready-to-deploy Prometheus + Grafana configuration for Fortune-20 operators scraping the `/metrics` endpoint exposed by `spook serve`.

Everything in this directory is production-hardened: the scrape config uses mTLS (which `spook serve` requires in production), the dashboard is accessibility-audited for high-contrast mode, and the alert rules map one-to-one against the SLO targets documented in the Enterprise Readiness Evaluation.

## What you get

| File | What it does |
|------|--------------|
| [`metrics.md`](metrics.md) | The full metric catalog — every series `/metrics` exposes, with type, unit, and an operational meaning |
| [`prometheus.yml`](prometheus.yml) | Scrape config for a single Spooktacular deployment (mTLS-authenticated, 15s interval) |
| [`alerts.yml`](alerts.yml) | Prometheus alerting rules for capacity, lock contention, audit-pipeline health, and VM-lifecycle regressions |
| [`grafana-dashboard.json`](grafana-dashboard.json) | Importable Grafana dashboard with four rows: capacity, API health, VM-lifecycle latencies, runner SLOs |

## Fifteen-minute setup

```bash
# 1. Scrape
cp docs/observability/prometheus.yml /etc/prometheus/
# Place the mTLS client cert/key + CA at the paths referenced inside.

# 2. Alert
cp docs/observability/alerts.yml /etc/prometheus/rules.d/
systemctl reload prometheus

# 3. Visualize
# Grafana: Dashboards → Import → upload grafana-dashboard.json
# Set the `prometheus` datasource UID when prompted.
```

## mTLS scrape gotcha

`spook serve` in production refuses to respond without a valid client certificate (`HTTPAPIServerError.tlsRequired`). Prometheus's scrape needs the same cert Spooktacular gives its CI callers — not a new certificate. Re-use whatever trust store holds your controller's client cert, and configure `tls_config.cert_file` / `key_file` in `prometheus.yml` to point at it.

For local-dev deployments started with `--insecure`, strip the `tls_config` block; the HTTP listener won't enforce TLS.

## Scope

This kit covers **platform health** — capacity, API latency, audit pipeline, lock contention, VM lifecycle. It intentionally does **not** try to re-expose application-layer metrics from workloads running **inside** the VMs. Guest-side observability is the tenant's responsibility; Spooktacular's job is to make sure their runners boot, pass scrub, and register on time.
