# e2e testbed code coverage — design

## Goal

go-fdo-server and go-fdo-client will gate PRs on test coverage thresholds
computed in part from go-fdo-ci's e2e testbed (`test/ci`, `test/container`).
go-fdo-ci must:

1. Run the e2e testbed with coverage-instrumented `go-fdo-server` and
   `go-fdo-client` binaries, for every test case (native and container).
2. Merge per-test coverage data into one total per binary.
3. Provide a `make test-coverage` target and a `make clean` target.
4. Report total coverage at the end of the e2e GitHub Actions job.

Enforcing thresholds is out of scope — go-fdo-server/go-fdo-client own that.

## Non-goals

- Modifying go-fdo-server/go-fdo-client Dockerfiles or Makefiles.
- Per-test-case coverage breakdown (only one merged total per binary).
- Unit test coverage (that's each repo's own CI concern).

## Background (current behavior)

- `test/ci/*.sh` ("Native"): `utils.sh` builds server/client via `make` in
  checked-out source dirs (`SERVER_LOCAL_PATH`/`CLIENT_LOCAL_PATH` override,
  else `fetch_server_repo`/`fetch_client_repo` clone `main` from upstream),
  installs to `workdir/bin`, runs as local processes (`nohup`), stops them
  with `pkill` (sends SIGTERM by default). go-fdo-server already traps
  SIGINT/SIGTERM and exits cleanly.
- `test/container/*.sh` ("Container"): `utils.sh` builds server/client
  Docker images via `docker compose build` (image `build:` context points at
  the same checked-out source dirs), runs via `docker compose up`, stops via
  `docker compose stop` (SIGTERM, then SIGKILL after a grace period).
- `.github/workflows/e2e.yml` builds a matrix from every `test-*.sh` under
  both directories and runs each as an independent job on its own runner.
- Neither the go-fdo-server nor go-fdo-client Dockerfile accepts a `GOFLAGS`
  build-arg, so a container image can't be told to build with `-cover`
  without a Dockerfile change.

## Why this matters for coverage

Go's `-cover`-instrumented binaries flush counter data to `GOCOVERDIR` on a
graceful exit (return from `main`/`os.Exit(0)`), not on `SIGKILL`. Since
go-fdo-server already shuts down gracefully on SIGTERM, and both stop paths
(`pkill`, `docker compose stop`) send SIGTERM first, no server-side changes
are needed. `GOCOVERDIR` must point at a directory that survives each test's
cleanup (`test/ci`'s `cleanup` wipes `base_dir` after every run), and — for
containers — must be a bind-mounted host path, since counter files are
written inside the container.

## Design

### 1. Coverage directories (shared, persistent)

A `COVERAGE_ROOT` (Makefile var, default `$(CURDIR)/test-coverage`) holds:

```
test-coverage/
  raw/server/    # GOCOVERDIR for every go-fdo-server process, every test
  raw/client/    # GOCOVERDIR for every go-fdo-client process, every test
  coverage-server.out / .html
  coverage-client.out / .html
```

Every native and container test run — across the whole matrix — writes into
the same `raw/server` and `raw/client` dirs. Since coverage aggregation is
line/package based, mixing native-built and container-built binaries (same
source revision, different toolchain images) in one merge is valid and is
exactly what gives the desired single "total coverage" number per binary.

These directories live outside `base_dir` / the container's working-dir
mount root so per-test cleanup never touches them.

### 2. `COVERAGE_ENABLED` env var — the single toggle

`test/ci/utils.sh` and `test/container/utils.sh` read `COVERAGE_ENABLED`
(default `0`). No changes to individual `test-*.sh` scripts — they only
call the shared `utils.sh` functions.

**Native (`test/ci/utils.sh`)**
- `install_server`/`install_client`: when enabled, `make build
  GOFLAGS="-cover -covermode=atomic"` instead of plain `make`.
- Before `start_services`/client calls: export `GOCOVERDIR` pointing at
  `raw/server` (for `run_go_fdo_server`) — client invocations
  (`run_go_fdo_client`) are short-lived one-shot commands, so they need
  their own `GOCOVERDIR=raw/client` set around each call rather than a
  single shared server-style var.

**Container (`test/container/utils.sh`)**
- go-fdo-ci owns two minimal coverage Dockerfiles,
  `test/container/coverage/Dockerfile.server` and `Dockerfile.client`,
  mirroring the upstream Dockerfiles' build/runtime stages but adding
  `ARG GOFLAGS` / `ENV GOFLAGS=${GOFLAGS}` before `RUN make build`.
- A docker-compose overlay per binary
  (`test/container/compose/coverage-overlay-server.yaml`,
  `coverage-overlay-client.yaml`) overrides the `build:` stanza of the
  `go-fdo-server`/`go-fdo-client` build service to use the coverage
  Dockerfile with `GOFLAGS=-cover -covermode=atomic`, and adds
  `GOCOVERDIR=/workdir/coverage` env + a bind mount of the host
  `raw/server` or `raw/client` dir to `/workdir/coverage` on every service
  that runs the binary (manufacturer/rendezvous/owner, go-fdo-client).
- `install_server`/`install_client`/`start_services`/`run_go_fdo_client`
  include the relevant overlay in the `docker compose -f ... -f ...`
  invocation when `COVERAGE_ENABLED=1`. This avoids touching the 13+
  existing per-test compose files.

### 3. Makefile (new, go-fdo-ci root)

```
COVERAGE_ROOT   ?= $(CURDIR)/test-coverage
SERVER_LOCAL_PATH ?=
CLIENT_LOCAL_PATH ?=
SERVER_REF        ?= main
CLIENT_REF        ?= main
```

- `test-coverage`: resolve server/client source (reuse existing
  `SERVER_LOCAL_PATH`/`CLIENT_LOCAL_PATH`/`SERVER_REF`/`CLIENT_REF`
  contract already implemented in `test/ci/utils.sh`) → set
  `COVERAGE_ENABLED=1` and the shared `GOCOVERDIR`s → run every
  `test/ci/test-*.sh` and `test/container/test-*.sh` sequentially → merge:
  `go tool covdata merge -i=raw/server -o=merged/server`, `textfmt`, then
  `go tool cover -html` for both binaries → print `go tool cover -func`
  total % for each.
- `clean`: removes `$(COVERAGE_ROOT)` (raw + merged + reports), any cloned
  `src/server`/`src/client` checkouts, and the native `workdir/bin`
  install dir — so a stale run can never leak into the next
  `test-coverage` invocation. This is the explicit "discard coverage
  history" reset requested.

### 4. CI (`.github/workflows/e2e.yml`)

- Each matrix job runs with `COVERAGE_ENABLED=1` and uploads its raw
  `raw/server`/`raw/client` contents as an artifact
  (`coverage-raw-${{ matrix.name }}`).
- A new final job, `coverage-report` (`needs: e2e`, `if: always()`),
  downloads all `coverage-raw-*` artifacts into one shared root, merges
  per binary, and writes the total server/client coverage percentages to
  `$GITHUB_STEP_SUMMARY`, plus uploads the merged HTML reports as
  artifacts. It does not fail the workflow on low coverage — reporting
  only.

## Testing

- Run `make test-coverage` locally against `SERVER_LOCAL_PATH`/
  `CLIENT_LOCAL_PATH` pointing at local checkouts; confirm
  `coverage-server.html`/`coverage-client.html` show non-zero coverage
  contributed by both native and container test runs.
- Run `make clean` and confirm `test-coverage/`, cloned `src/`, and
  `workdir/bin` are gone, and a subsequent `make test-coverage` starts
  from zero (no stale counts carried over).
- Kill a manufacturer/rendezvous/owner process mid-test manually to
  confirm SIGTERM-based shutdown still flushes coverage (regression guard
  for the graceful-shutdown assumption).
- Dry-run the modified `e2e.yml` on a branch/PR to confirm the
  `coverage-report` job downloads artifacts from all matrix jobs and
  prints a sane total.
