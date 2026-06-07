# Agents

Instructions for AI coding agents working on this project.

## Project Overview

`livery_s3` is an S3-compatible object storage client built on the
`livery_client` HTTP client (from the sibling `livery` project). It
signs every request with AWS Signature V4 and works against AWS S3
and S3-compatible stores (Garage, MinIO, Ceph, ...). One OTP
application, a thin domain layer over `livery_client`:

```
src/livery_s3.erl        Public facade: new/1 + every operation
                         (object CRUD, metadata, ranges/streaming,
                         buckets, versioning, multipart, copy,
                         batch delete, presigned URLs)
src/livery_s3_sigv4.erl  AWS SigV4: the signing client layer (call/3),
                         the pure authorization/1, and presigned_url
src/livery_s3_uri.erl    RFC 3986 encoding, canonical query, URL +
                         host building, endpoint parsing
src/livery_s3_xml.erl    S3 XML responses -> light {Tag,Attrs,Children}
                         tree (xmerl_sax_parser) + navigation helpers
include/livery_s3.hrl    Shared config record, SigV4 constants
test/                    EUnit (SigV4 vectors, URI, XML, fake-adapter
                         round-trips) + livery_s3_garage_SUITE
test/docker/             Garage bring-up for the integration suite
docs/                    Markdown docs (features.md); ex_doc output is doc/
```

`livery` is a git dep in `rebar.config`. For co-development, override
it with a `_checkouts/livery` symlink to the sibling project
(`_checkouts/` is gitignored); push livery changes before relying on
them through the git dep.

Authoritative behaviour is the test suites under `test/`: the offline
EUnit suite (signing checked against AWS's published S3 examples, plus
fake-adapter request/response round-trips) and `livery_s3_garage_SUITE`
(a real lifecycle against Garage in Docker).

## Required Checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt          # Auto-format (always run first)
rebar3 compile      # Must compile cleanly (warnings_as_errors)
rebar3 lint         # Elvis linter
rebar3 xref         # Cross-reference analysis
rebar3 dialyzer     # Type checking
rebar3 eunit        # Offline unit tests
```

`make check` runs the offline gate (compile, xref, dialyzer, lint,
fmt, eunit). The Garage integration suite is separate (see below).

## Build & Development Commands

```bash
rebar3 compile                                  # Build
rebar3 eunit --cover                            # Unit tests with coverage
rebar3 cover --verbose                          # Coverage report
make test                                       # garage-up -> rebar3 ct -> garage-down
./test/docker/garage-up.sh                      # Start Garage in Docker
rebar3 ct --suite test/livery_s3_garage_SUITE   # Integration suite
rebar3 ex_doc                                   # Generate API docs into doc/
```

The integration suite skips itself if no S3 endpoint is reachable.
Override the target with `LIVERY_S3_ENDPOINT`, `LIVERY_S3_REGION`,
`LIVERY_S3_ACCESS_KEY`, `LIVERY_S3_SECRET_KEY`, `LIVERY_S3_BUCKET`.

## Architecture

### Client construction

`livery_s3:new/1` parses the endpoint, captures credentials and the
addressing style in an `#s3_config{}`, and builds one `livery_client`
whose stack is `[concurrency?, circuit_breaker?, retry, balance?,
signing]` (outermost to innermost; see `build_stack/2`). The client
value is reused for every call. **Retry is on by default** (transient
5xx + connection errors, idempotent ops only; livery's retry layer
never replays streamed bodies or non-idempotent methods).
`circuit_breaker` and `endpoints`/`balance` are ETS-backed and need the
`livery` application started; `retry` and `concurrency` do not.

### Request flow

Each operation builds the absolute request URL with `livery_s3_uri`
(`base_url => <<>>` on the client, so the URL passes through
verbatim), attaches S3 headers, and calls `livery_client`. The
`{livery_s3_sigv4, Config}` layer runs closest to the transport: it
derives the payload hash, sets `host`/`x-amz-date`/
`x-amz-content-sha256` (and `x-amz-security-token` when configured),
signs `host` plus every `x-amz-*` header, and adds `authorization`.

### Signing correctness

`livery_s3_uri` is the single source of truth for percent-encoding
and query ordering; the signer reads the path and query back out of
the URL it built, so signed and sent forms cannot drift. The pure
`livery_s3_sigv4:authorization/1` is pinned to AWS's published S3
worked examples in `livery_s3_sigv4_tests`.

### Responses

Buckets/versioning/multipart/batch/error bodies are XML, parsed by
`livery_s3_xml`. Object metadata comes from response headers
(`x-amz-meta-*` -> a `metadata` map). Non-2xx decodes to
`{error, {s3, Code, Message, #{status => S, request_id => RId}}}`;
a missing object/bucket on HEAD is `{error, not_found}`.

## Conventions

- Run `rebar3 fmt` before committing; elvis must pass. New per-module
  elvis ignores belong in `rebar.config` with a one-line reason.
- Commit messages: one imperative subject line, body only for
  non-obvious "why". No diff restatement, no "generated by" /
  "co-authored-by" trailers.
- Do not use the em-dash character in code, docs, or messages.
- Default to path-style addressing; it works with every
  S3-compatible store. Virtual-hosted is opt-in (`addressing =>
  virtual`).
- Do not add `livery_client:timeout/1` to a stack used for streamed
  downloads: it runs the request in a worker that exits and tears the
  connection down, so the stream reader gets `{error, closed}`. Use
  the `timeout` option (hackney `recv_timeout`) instead.
- Keep the facade thin. Signing, encoding, and XML belong in the
  helper modules, not in `livery_s3`.
