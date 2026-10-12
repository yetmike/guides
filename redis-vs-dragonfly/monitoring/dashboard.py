#!/usr/bin/env python3
"""Generate the two Grafana dashboards for the benchmark.

usage: dashboard.py <uid> "<title>" <namespace> contender=color [contender=color ...]

Writes <uid>.json (the six comparison panels) and <uid>-health.json (load
generator and client node CPU, for the operator). Import them in Grafana
(Dashboards -> New -> Import) and pick your Prometheus-compatible datasource
in the "datasource" dropdown.

Panels read the loadgen histograms (bench_* metrics, label db=<contender>) and
cAdvisor for CPU/memory/network (job "cadvisor-benchmark", see
scrape-config.yaml), keyed on container name == contender. Keep container
names equal to the loadgen DB label and everything lines up.
"""
import json, sys

uid, title, ns, *contenders = sys.argv[1:]
colors = dict(c.split("=") for c in contenders)
# longest first so "redis-cluster-0" is not claimed by the "redis" alternative
names = "|".join(sorted(colors, key=len, reverse=True))
ds = {"type": "prometheus", "uid": "${datasource}"}  # picked in the dashboard dropdown
ri = "[$__rate_interval]"
cad = f'job="cadvisor-benchmark", namespace="{ns}", container=~"{names}"'


def panel(i, title, expr, unit, x, y, legend="{{db}}", extra=()):
    return {
        "id": i, "title": title, "type": "timeseries", "datasource": ds,
        "gridPos": {"x": x, "y": y, "w": 12, "h": 6},  # 3 rows fit 1080p at 1.5x
        "fieldConfig": {
            "defaults": {"unit": unit, "min": 0, "custom": {"lineWidth": 3, "fillOpacity": 8, "showPoints": "never"}},
            "overrides": [{"matcher": {"id": "byName", "options": n},
                           "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
                          for n, c in colors.items()]},
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "targets": [{"refId": "A", "expr": expr, "legendFormat": legend, "datasource": ds}, *extra],
    }


def q(p, op):
    return f'histogram_quantile({p}, sum by (le, db) (rate(bench_op_duration_seconds_bucket{{op="{op}"}}{ri})))'


panels = [
    panel(1, "SET latency p99", q(0.99, "set"), "s", 0, 0),
    panel(2, "Requests per second (SET+GET)", f'sum by (db) (rate(bench_ops_total{{status="ok"}}{ri}))', "reqps", 12, 0),
    panel(3, "GET latency p99", q(0.99, "get"), "s", 0, 6),
    panel(4, "CPU (cores, all pods of a contender)", f'sum by (container) (rate(container_cpu_usage_seconds_total{{{cad}}}{ri})) > 0.005', "none", 12, 6, "{{container}}"),
    panel(5, "Network transmit", f'sum by (db) (label_replace(rate(container_network_transmit_bytes_total{{job="cadvisor-benchmark", namespace="{ns}", pod=~"({names})-.*"}}{ri})*8, "db", "$1", "pod", "^({names})-.*"))', "bps", 0, 12),
    panel(6, "Memory working set", f'sum by (container) (container_memory_working_set_bytes{{{cad}}})', "bytes", 12, 12, "{{container}}"),
]
health = [
    panel(1, "Errors per second", f'sum by (db) (rate(bench_ops_total{{status="error"}}{ri}))', "reqps", 0, 0),
    panel(2, "Target vs achieved (SET+GET)", f'sum by (db) (rate(bench_ops_total{{status="ok"}}{ri}))', "reqps", 12, 0,
          extra=[{"refId": "B", "expr": "max by (db) (bench_target_rps) * 2", "legendFormat": "target {{db}}", "datasource": ds}]),
    panel(3, "Load generator CPU (must stay below its limit)", f'sum by (pod) (rate(container_cpu_usage_seconds_total{{job="cadvisor-benchmark", namespace="{ns}", container="loadgen"}}{ri}))', "none", 0, 6, "{{pod}}"),
    panel(4, "Node CPU (softirq shows here)", 'sum by (node) (rate(container_cpu_usage_seconds_total{job="cadvisor-benchmark", id="/"}[$__rate_interval]))', "none", 12, 6, "{{node}}"),
    panel(5, "SET latency p50", q(0.5, "set"), "s", 0, 12),
    panel(6, "GET latency p50", q(0.5, "get"), "s", 12, 12),
]


def write(uid, title, panels):
    dash = {"uid": uid, "title": title, "tags": ["benchmark"], "timezone": "browser", "schemaVersion": 39,
            "version": 1, "refresh": "5s", "time": {"from": "now-30m", "to": "now"},
            "templating": {"list": [{"name": "datasource", "type": "datasource", "query": "prometheus"}]},
            "panels": panels}
    with open(f"{uid}.json", "w") as f:
        json.dump(dash, f, indent=2)
        f.write("\n")


write(uid, title, panels)
write(uid + "-health", title + " (health)", health)
