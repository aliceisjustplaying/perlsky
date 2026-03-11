# Performance

This document covers two practical tools for `perlsky` performance work:

- Prometheus metrics for live visibility
- `script/benchmark-local-appview` for repeatable local endpoint timing

## Benchmark Script

`script/benchmark-local-appview` spins up an ephemeral local `perlsky` daemon, seeds a small repo with posts and a reply chain, then benchmarks the hottest local appview endpoints over real HTTP:

- `app.bsky.actor.getProfile`
- `app.bsky.feed.getAuthorFeed`
- `app.bsky.feed.getPostThread`

Example:

```sh
script/benchmark-local-appview --iterations 75 --warmup 15 --posts 100 --replies 12
```

JSON output:

```sh
script/benchmark-local-appview --format json > data/local-appview-benchmark.json
```

The benchmark is intentionally small and deterministic. It is best for comparing one local appview change against another, not for claiming cluster-scale throughput.

Useful flags:

- `--iterations N`: measured requests per endpoint, default `50`
- `--warmup N`: unmeasured warmup requests per endpoint, default `10`
- `--posts N`: number of posts to seed for the author feed, default `50`
- `--replies N`: length of the reply chain for the thread benchmark, default `8`
- `--feed-limit N`: `getAuthorFeed` page size, default `25`
- `--keep-tmp`: keep the temporary benchmark dataset on disk for inspection

The script also prints a metrics excerpt so it is easy to sanity-check whether local appview cache counters moved during the run.

## Recommended Workflow

For repeatable tuning:

1. Run the benchmark script before a perf change and save the output.
2. Apply the change.
3. Run the same benchmark again with the same arguments.
4. Compare:
   - `p50`
   - `p95`
   - `max`
   - derived `req/s`
5. Check `/metrics` to confirm that cache hit/rebuild counters changed the way you expected.
6. If the change looks promising, compare the same Prometheus panels in Grafana after deployment.

## Current Hot Metrics

The most relevant local appview metrics are:

- `perlsky_service_proxy_requests_total`
- `perlsky_service_proxy_request_duration_seconds`
- `perlsky_service_proxy_local_post_index_cache_access_total`
- `perlsky_service_proxy_local_post_index_rebuild_duration_seconds`
- `perlsky_service_proxy_local_post_index_entries`
- `perlsky_service_proxy_local_post_resolution_total`
- `perlsky_service_proxy_profile_record_cache_total`
- `perlsky_repo_resolution_total`

See [METRICS.md](./METRICS.md) for Prometheus and Grafana queries.
