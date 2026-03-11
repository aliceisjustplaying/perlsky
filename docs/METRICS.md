# Metrics

`perlsky` now exposes Prometheus-style metrics at `/metrics`.

## Security

- If `metrics_token` is configured, the endpoint requires `Authorization: Bearer <token>`.
- If `metrics_token` is omitted, the endpoint is public.
- For internet-facing deployments, prefer setting `metrics_token` and/or restricting `/metrics` at the reverse proxy layer.

## Main Metrics

- `perlsky_xrpc_requests_total`
  Counts HTTP XRPC requests by method, NSID, endpoint type, and status.
- `perlsky_xrpc_request_duration_seconds`
  Histogram for HTTP XRPC latency with the same labels.
- `perlsky_xrpc_errors_total`
  Counts rendered XRPC failures by method, NSID, endpoint type, status, and error code.
- `perlsky_xrpc_unhandled_exceptions_total`
  Counts true unhandled exceptions on XRPC routes by method, NSID, and endpoint type.
- `perlsky_subscription_connections_total`
  Counts websocket subscription opens by NSID.
- `perlsky_subscription_active`
  Gauge of active websocket subscriptions by NSID.
- `perlsky_subscription_closes_total`
  Counts websocket closes by NSID and close code.
- `perlsky_subscription_frames_total`
  Counts emitted websocket frames by NSID, frame type, and encoding.
- `perlsky_subscription_bytes_total`
  Counts emitted websocket bytes by NSID and encoding.
- `perlsky_subscription_duration_seconds`
  Histogram of websocket lifetime by NSID.
- `perlsky_crawler_requests_total`
  Counts outbound `com.atproto.sync.requestCrawl` calls by crawler service and result.
- `perlsky_crawler_request_duration_seconds`
  Histogram of outbound crawler request latency.
- `perlsky_blob_ingress_bytes_total`
  Counts uploaded blob bytes by MIME type.
- `perlsky_blob_egress_bytes_total`
  Counts downloaded blob bytes by MIME type.
- `perlsky_store_operations_total`
  Counts instrumented SQLite-backed store operations by operation and status.
- `perlsky_store_operation_duration_seconds`
  Histogram of instrumented store operation duration.
- `perlsky_service_proxy_requests_total`
  Counts local and upstream `app.bsky.*` proxy requests by NSID, source, and status.
- `perlsky_service_proxy_request_duration_seconds`
  Histogram for service-proxy request latency with the same labels.
- `perlsky_service_proxy_local_post_index_cache_access_total`
  Counts request-local hits, process-cache hits, and rebuilds for the local post index.
- `perlsky_service_proxy_local_post_index_rebuild_duration_seconds`
  Histogram of local post-index rebuild time.
- `perlsky_service_proxy_local_post_index_entries`
  Gauge of local post-index entry counts by kind.
- `perlsky_service_proxy_local_post_resolution_total`
  Counts how local post lookups were resolved: request cache, shared index, store, or non-local bypass.
- `perlsky_service_proxy_profile_record_cache_total`
  Counts local profile record cache hits and misses.
- `perlsky_repo_resolution_total`
  Counts repo/DID resolution paths, including request-cache reuse versus fallback scans.
- `perlsky_build_info`
  Static build/service info gauge.

## Current Store Coverage

The store metrics currently cover the highest-signal operations on the live path:

- transactions
- event append and event stream reads
- event high-watermark reads
- blob put/get
- label put/list
- record list
- repo CAR export

This is enough to understand the hot PDS paths under load without trying to wrap every SQLite call in the codebase.

## Suggested Alerts

- high error rate on `perlsky_xrpc_requests_total`
- spikes in `perlsky_xrpc_errors_total` for a specific `nsid` or `error`
- any growth in `perlsky_xrpc_unhandled_exceptions_total`
- sustained increase in `perlsky_xrpc_request_duration_seconds`
- non-zero `perlsky_subscription_active` with no corresponding frame growth
- crawler errors from `perlsky_crawler_requests_total{result="error"}`
- large ingress with low egress or vice versa on blob byte counters
- persistent growth in store latency histograms
- sustained `result="rebuild"` growth in `perlsky_service_proxy_local_post_index_cache_access_total`
- high `p95` in `perlsky_service_proxy_local_post_index_rebuild_duration_seconds`
- unexpected growth in `source="list_scan"` for `perlsky_repo_resolution_total`

## Prometheus

The repo includes a checked-in example scrape job at [ops/prometheus/perlsky.yml](../ops/prometheus/perlsky.yml).

On the live VPS we scrape every `15s` instead of more aggressively to avoid adding pressure while Prometheus is already remote-writing to Grafana Cloud.

## Grafana

The repo includes:

- [ops/grafana/perlsky-dashboard.json](../ops/grafana/perlsky-dashboard.json): overview dashboard for XRPC, service-proxy, store, subscription, and blob metrics
- [ops/grafana/prometheus-datasource.yml](../ops/grafana/prometheus-datasource.yml): example provisioned Prometheus data source
- [ops/grafana/perlsky-dashboard-provider.yml](../ops/grafana/perlsky-dashboard-provider.yml): example dashboard provider that watches a dashboard directory

The dashboard expects a Prometheus data source. When provisioning, either keep the checked-in `uid` from the example data source or update the dashboard's `${DS_PROMETHEUS}` mapping during import.

## Example Scrape

```sh
curl -H 'Authorization: Bearer YOUR_TOKEN' \
  http://127.0.0.1:7755/metrics
```
