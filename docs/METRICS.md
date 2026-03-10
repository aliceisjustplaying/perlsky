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
- sustained increase in `perlsky_xrpc_request_duration_seconds`
- non-zero `perlsky_subscription_active` with no corresponding frame growth
- crawler errors from `perlsky_crawler_requests_total{result="error"}`
- large ingress with low egress or vice versa on blob byte counters
- persistent growth in store latency histograms

## Example Scrape

```sh
curl -H 'Authorization: Bearer YOUR_TOKEN' \
  http://127.0.0.1:7755/metrics
```
