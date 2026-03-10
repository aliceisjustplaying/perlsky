# perlds

`perlds` is a Perl 5 Personal Data Server for the AT Protocol / Bluesky ecosystem.

The project goal is to expose the current external `com.atproto.*` PDS-facing XRPC
surface from the official lexicons, with a local SQLite-backed implementation for:

- account and session management
- DID/handle identity resolution
- record and blob storage
- DAG-CBOR block storage
- Merkle Search Tree repository state
- CAR export/import and sync endpoints

The codebase intentionally keeps protocol metadata close to the source by deriving
its route inventory from the upstream lexicons vendored during development.
