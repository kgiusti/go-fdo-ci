# e2e Testbed Code Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the go-fdo-ci e2e testbed (`test/ci`, `test/container`) the ability to run go-fdo-server/go-fdo-client with `-cover` instrumentation, merge coverage across every test case into one total per binary, expose this via `make test-coverage` / `make clean`, and report totals in the e2e GitHub Actions workflow.

**Architecture:** A single `COVERAGE_ENABLED` env var toggles coverage-aware code paths already living in `test/ci/utils.sh` and `test/container/utils.sh` (native builds gain `-cover`/`GOCOVERDIR`; container builds gain go-fdo-ci-owned coverage Dockerfiles applied via a docker-compose `-f` overlay). All test cases — native and container — write into two shared, persistent directories (one per binary), which a new root Makefile merges and reports on. CI uploads each matrix job's raw coverage as an artifact and a final job merges + summarizes.

**Tech Stack:** Bash, GNU Make, Docker Compose, Go 1.26 (`go tool covdata`, `go tool cover`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-21-e2e-coverage-design.md`

## Global Constraints

- Coverage must not be lost on process shutdown: only rely on graceful SIGTERM shutdown (already implemented in go-fdo-server) — never SIGKILL a coverage-instrumented process.
- Do not modify go-fdo-server or go-fdo-client source, Makefiles, or Dockerfiles — all coverage logic lives in go-fdo-ci.
- Do not touch the per-test compose YAML files under `test/container/compose/server/` or `client/` — coverage is applied via a separate overlay file passed on the `docker compose -f` command line.
- One merged total per binary (server, client) — no per-test-case breakdown.
- Reuse the existing `SERVER_LOCAL_PATH`/`CLIENT_LOCAL_PATH`/`SERVER_REF`/`CLIENT_REF` env-var contract already implemented by `fetch_server_repo`/`fetch_client_repo`/`install_server`/`install_client` in `test/ci/utils.sh` — do not invent a second override mechanism.
- `make clean` must remove every generated artifact (coverage data, reports, cloned sources, native bin dir) so a subsequent `make test-coverage` starts from zero.

---

## File Structure

- Create: `Makefile` — root Makefile: variables, `test-coverage`, `clean`, and a `merge-coverage` helper target.
- Create: `test/coverage/merge.sh` — merges raw `GOCOVERDIR` counter data for one binary into `.out`/`.html` reports and prints the total percentage.
- Modify: `test/ci/utils.sh` — coverage-aware `install_server`/`install_client`, `run_go_fdo_server`, `run_go_fdo_client`.
- Create: `test/container/coverage/Dockerfile.server` — coverage-instrumented build of go-fdo-server, mirroring upstream `Dockerfile`.
- Create: `test/container/coverage/Dockerfile.client` — coverage-instrumented build of go-fdo-client, mirroring upstream `Dockerfile`.
- Create: `test/container/compose/coverage-overlay-server.yaml` — env/volume/build overlay for server containers.
- Create: `test/container/compose/coverage-overlay-client.yaml` — env/volume/build overlay for the client container.
- Modify: `test/container/utils.sh` — coverage-aware `install_server`/`install_client`, `start_services`, `run_go_fdo_client`, using explicit service-name lists so the overlay's extra service stanzas never get started for tests that don't define them.
- Modify: `.github/workflows/e2e.yml` — set `COVERAGE_ENABLED=1` on the `e2e` job, upload raw coverage per matrix job, add a `coverage-report` job.
- Modify: `.gitignore` — add `test-coverage/`.

---

### Task 1: Root Makefile skeleton with `clean`

**Files:**
- Create: `Makefile`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `COVERAGE_ROOT` (make var, default `$(CURDIR)/test-coverage`), `SERVER_LOCAL_PATH`/`CLIENT_LOCAL_PATH`/`SERVER_REF`/`CLIENT_REF` (make vars, all overridable, empty/`main` defaults), `clean` target.

- [ ] **Step 1: Write the Makefile skeleton**

```makefile
#! /usr/bin/make -f

COVERAGE_ROOT     ?= $(CURDIR)/test-coverage
SERVER_LOCAL_PATH ?=
CLIENT_LOCAL_PATH ?=
SERVER_REF        ?= main
CLIENT_REF        ?= main

export SERVER_LOCAL_PATH
export CLIENT_LOCAL_PATH
export SERVER_REF
export CLIENT_REF

.PHONY: clean
clean:
	rm -rf "$(COVERAGE_ROOT)"
	rm -rf "$(CURDIR)/src"
	rm -rf "$(CURDIR)/workdir"
```

- [ ] **Step 2: Add the coverage output directory to `.gitignore`**

Modify `.gitignore`, add a line:

```
test-coverage
```

- [ ] **Step 3: Verify `make clean` runs cleanly with nothing to remove**

Run: `make clean`
Expected: exits 0, no error (directories may not exist yet — `rm -rf` on a missing path is a no-op).

- [ ] **Step 4: Verify `make clean` actually removes generated state**

```bash
mkdir -p test-coverage/raw/server src workdir
make clean
test ! -d test-coverage && test ! -d src && test ! -d workdir && echo OK
```

Expected: prints `OK`.

- [ ] **Step 5: Commit**

```bash
git add Makefile .gitignore
git commit -s -m "build: add root Makefile with clean target"
```

---

### Task 2: Native coverage support in `test/ci/utils.sh`

**Files:**
- Modify: `test/ci/utils.sh:434-468` (the `install_client`/`uninstall_client`/`install_server`/`uninstall_server` block) and `test/ci/utils.sh:265-277,320-332` (`run_go_fdo_client`, `run_go_fdo_server`)

**Interfaces:**
- Consumes: env var `COVERAGE_ENABLED` (`"0"`/`"1"`, default unset = disabled), env var `COVERAGE_ROOT` (set by the Makefile in Task 6; when unset/running plain e2e tests, coverage code paths are skipped entirely).
- Produces: when `COVERAGE_ENABLED=1`, `${COVERAGE_ROOT}/raw/server/` and `${COVERAGE_ROOT}/raw/client/` accumulate Go coverage counter files after a full native test run.

- [ ] **Step 1: Add a coverage-flags helper near the top of `test/ci/utils.sh`, after the `NC='\033[0m'` color block**

```bash
coverage_enabled() {
  [[ "${COVERAGE_ENABLED:-0}" = "1" ]]
}

coverage_goflags() {
  coverage_enabled && echo "-cover -covermode=atomic"
}

server_gocoverdir="${COVERAGE_ROOT:-}/raw/server"
client_gocoverdir="${COVERAGE_ROOT:-}/raw/client"
```

- [ ] **Step 2: Make `install_client`/`install_server` build with coverage flags when enabled**

Replace:

```bash
install_client() {
  fetch_client_repo
  log_info "Building client from local path: ${client_src_dir}"
  pushd "${client_src_dir}" >/dev/null
  make && install -m 755 go-fdo-client "${bin_dir}" && rm -f go-fdo-client
  popd >/dev/null
}
```

with:

```bash
install_client() {
  fetch_client_repo
  log_info "Building client from local path: ${client_src_dir}"
  pushd "${client_src_dir}" >/dev/null
  make build GOFLAGS="$(coverage_goflags)" && install -m 755 go-fdo-client "${bin_dir}" && rm -f go-fdo-client
  popd >/dev/null
}
```

Replace:

```bash
install_server() {
  fetch_server_repo
  log_info "Building server from local path: ${server_src_dir}"
  pushd "${server_src_dir}" >/dev/null
  make && install -m 755 go-fdo-server "${bin_dir}" && rm -f go-fdo-server
  popd >/dev/null
}
```

with:

```bash
install_server() {
  fetch_server_repo
  log_info "Building server from local path: ${server_src_dir}"
  pushd "${server_src_dir}" >/dev/null
  make build GOFLAGS="$(coverage_goflags)" && install -m 755 go-fdo-server "${bin_dir}" && rm -f go-fdo-server
  popd >/dev/null
}
```

(`make build` is the target both projects' Makefiles already expose; `GOFLAGS=""` when coverage is disabled behaves identically to the old plain `make`, since both Makefiles declare `GOFLAGS ?=`.)

- [ ] **Step 3: Set `GOCOVERDIR` around the server process and each client invocation**

Replace:

```bash
run_go_fdo_server() {
  local role=$1
  local address_port=$2
  local db_type=$3
  local db_dsn=$4
  local pid_file=$5
  local log=$6
  shift 6
  mkdir -p "$(dirname "${log}")"
  mkdir -p "$(dirname "${pid_file}")"
  nohup "${bin_dir}/go-fdo-server" "${role}" "${address_port}" --db-type "${db_type}" --db-dsn "${db_dsn}" --log-level=debug "${@}" &>"${log}" &
  echo -n $! >"${pid_file}"
}
```

with:

```bash
run_go_fdo_server() {
  local role=$1
  local address_port=$2
  local db_type=$3
  local db_dsn=$4
  local pid_file=$5
  local log=$6
  shift 6
  mkdir -p "$(dirname "${log}")"
  mkdir -p "$(dirname "${pid_file}")"
  if coverage_enabled; then
    mkdir -p "${server_gocoverdir}"
  fi
  GOCOVERDIR="${server_gocoverdir}" \
    nohup "${bin_dir}/go-fdo-server" "${role}" "${address_port}" --db-type "${db_type}" --db-dsn "${db_dsn}" --log-level=debug "${@}" &>"${log}" &
  echo -n $! >"${pid_file}"
}
```

Replace:

```bash
run_go_fdo_client() {
  mkdir -p "${credentials_dir}"
  cd "${credentials_dir}"
  # If the command times out, the return code is 124 (see: man timeout)
  # If the command finishes before the timeout, the return code comes from 'go-fdo-client'
  local exit_code=0
  timeout "${client_timeout}" "${bin_dir}/go-fdo-client" "$@" || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    log_warn "'go-fdo-client' exited with '${exit_code}' (124 -> timeout):\n  - go-fdo-client $*"
  fi
  cd - >/dev/null
  return ${exit_code}
}
```

with:

```bash
run_go_fdo_client() {
  mkdir -p "${credentials_dir}"
  cd "${credentials_dir}"
  if coverage_enabled; then
    mkdir -p "${client_gocoverdir}"
  fi
  # If the command times out, the return code is 124 (see: man timeout)
  # If the command finishes before the timeout, the return code comes from 'go-fdo-client'
  local exit_code=0
  GOCOVERDIR="${client_gocoverdir}" \
    timeout "${client_timeout}" "${bin_dir}/go-fdo-client" "$@" || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    log_warn "'go-fdo-client' exited with '${exit_code}' (124 -> timeout):\n  - go-fdo-client $*"
  fi
  cd - >/dev/null
  return ${exit_code}
}
```

(When `COVERAGE_ENABLED` is unset, `GOCOVERDIR=""` is passed to a plain, non-instrumented binary, which ignores it — no behavior change for the existing, non-coverage e2e runs.)

- [ ] **Step 4: Verify the plain (non-coverage) path still passes**

Run: `bash -n test/ci/utils.sh` (syntax check), then run one native test unmodified:

```bash
cd test/ci && ./test-onboarding.sh
```

Expected: `[PASS] ✅ Test PASSED!`, identical to before this change (COVERAGE_ENABLED unset).

- [ ] **Step 5: Verify the coverage path produces counter data**

```bash
export COVERAGE_ENABLED=1
export COVERAGE_ROOT="$(mktemp -d)"
cd test/ci && ./test-onboarding.sh
ls "${COVERAGE_ROOT}/raw/server" | grep -q . && echo "server coverage OK"
ls "${COVERAGE_ROOT}/raw/client" | grep -q . && echo "client coverage OK"
unset COVERAGE_ENABLED COVERAGE_ROOT
```

Expected: both `server coverage OK` and `client coverage OK` printed (Go coverage counter files, named `covcounters.*` and `covmeta.*`, present in each dir).

- [ ] **Step 6: Commit**

```bash
git add test/ci/utils.sh
git commit -s -m "feat: build native binaries with coverage instrumentation when enabled"
```

---

### Task 3: Coverage Dockerfiles for containerized binaries

**Files:**
- Create: `test/container/coverage/Dockerfile.server`
- Create: `test/container/coverage/Dockerfile.client`

**Interfaces:**
- Produces: two Dockerfiles, each accepting a `GOFLAGS` build-arg, producing the same final image shape (entrypoint, base image) as go-fdo-server's/go-fdo-client's own upstream `Dockerfile`, so the compose overlay in Task 4 can substitute them in without changing runtime behavior of the tests.

- [ ] **Step 1: Write `test/container/coverage/Dockerfile.server`**

Mirrors `go-fdo-server/Dockerfile` (read at plan-writing time: `golang:1.26-alpine` builder running `make build`, final stage `alpine` with `tzdata curl libecpg`), adding the `GOFLAGS` build-arg:

```dockerfile
# Coverage-instrumented build of go-fdo-server, used only by go-fdo-ci's
# e2e coverage overlay. Mirrors go-fdo-server/Dockerfile's stages.
FROM golang:1.26-alpine AS builder

ARG GOFLAGS=""
ENV GOFLAGS=${GOFLAGS}

WORKDIR /go/src/app
COPY . .

RUN apk add --no-cache curl git gcc make musl-dev npm
RUN make build && install -D -m 755 go-fdo-server /go/bin/

FROM alpine

RUN apk add --no-cache tzdata curl libecpg

COPY --from=builder /go/bin/go-fdo-server /usr/bin/go-fdo-server

ENTRYPOINT ["go-fdo-server"]
CMD []
```

- [ ] **Step 2: Write `test/container/coverage/Dockerfile.client`**

Mirrors `go-fdo-client/Dockerfile` (`golang:1.26-alpine` builder running `make`, final stage `gcr.io/distroless/static-debian12`):

```dockerfile
# Coverage-instrumented build of go-fdo-client, used only by go-fdo-ci's
# e2e coverage overlay. Mirrors go-fdo-client/Dockerfile's stages.
FROM golang:1.26-alpine AS builder

ARG GOFLAGS=""
ENV GOFLAGS=${GOFLAGS}

WORKDIR /go/src/app
COPY . .

RUN apk add make
RUN make build
RUN install -D -m 755 go-fdo-client /go/bin/

FROM gcr.io/distroless/static-debian12

COPY --from=builder /go/bin/go-fdo-client /usr/bin/go-fdo-client

ENTRYPOINT ["go-fdo-client"]
```

(go-fdo-client's Makefile `build` target is the one that honors `GOFLAGS`, per the client's own `.github/scripts/test-coverage.sh`, which already runs `make build GOFLAGS="-cover -covermode=atomic"` — using `make build` here instead of the upstream Dockerfile's bare `make` keeps the coverage flag flowing the same way.)

- [ ] **Step 3: Verify the server coverage Dockerfile builds and honors GOFLAGS**

```bash
docker build --build-arg GOFLAGS="-cover -covermode=atomic" \
  -f test/container/coverage/Dockerfile.server \
  -t go-fdo-server-coverage-test /home/kgiusti/work/fdo/go-fdo-server
docker run --rm --entrypoint sh go-fdo-server-coverage-test -c \
  "go version -m /usr/bin/go-fdo-server | grep -q 'GOCOVER' && echo 'instrumented'"
```

Expected: prints `instrumented` (a `-cover` build embeds `GOCOVERDIR`-related build info readable via `go version -m`) — if the alpine final stage lacks a shell, run the check against the **builder** stage instead:

```bash
docker build --build-arg GOFLAGS="-cover -covermode=atomic" \
  --target builder -f test/container/coverage/Dockerfile.server \
  -t go-fdo-server-coverage-builder /home/kgiusti/work/fdo/go-fdo-server
docker run --rm go-fdo-server-coverage-builder go version -m /go/bin/go-fdo-server | grep -i cover
```

Expected: output includes a `-cover`/coverage-related build setting line.

- [ ] **Step 4: Verify the client coverage Dockerfile builds the same way**

```bash
docker build --build-arg GOFLAGS="-cover -covermode=atomic" \
  --target builder -f test/container/coverage/Dockerfile.client \
  -t go-fdo-client-coverage-builder /home/kgiusti/work/fdo/go-fdo-client
docker run --rm go-fdo-client-coverage-builder go version -m /go/bin/go-fdo-client | grep -i cover
```

Expected: output includes a `-cover`/coverage-related build setting line.

- [ ] **Step 5: Commit**

```bash
git add test/container/coverage/Dockerfile.server test/container/coverage/Dockerfile.client
git commit -s -m "feat: add coverage-instrumented Dockerfiles for container e2e tests"
```

---

### Task 4: Docker Compose coverage overlays

**Files:**
- Create: `test/container/compose/coverage-overlay-server.yaml`
- Create: `test/container/compose/coverage-overlay-client.yaml`

**Interfaces:**
- Consumes: host env vars `server_coverage_dir`/`client_coverage_dir` (absolute host paths, set by `test/container/utils.sh` in Task 5), `container_working_dir` (already exported by `test/container/utils.sh`).
- Produces: two overlay compose files that, applied via `docker compose -f <base> -f <overlay>`, (a) rebuild the `go-fdo-server`/`go-fdo-client` build service using the Task 3 coverage Dockerfile with `GOFLAGS=-cover -covermode=atomic`, and (b) mount a persistent host directory at `${container_working_dir}/coverage` with `GOCOVERDIR` pointed at it, for every service that runs that image.

- [ ] **Step 1: Write `test/container/compose/coverage-overlay-server.yaml`**

Every server test's compose file resolves (directly or via `include:`) to a base that always defines `go-fdo-server` (the build service), `manufacturer`, `rendezvous`, and `owner`; the resale/ov-verification tests add a fourth service, `new_owner`, using the same `go-fdo-server` image. List all four here — Task 5 always passes an explicit service-name list to `docker compose`, so an overlay entry for a service a given test doesn't define is harmless (compose accepts it; it's simply never referenced):

```yaml
services:
  go-fdo-server:
    build:
      context: ${server_src_dir}
      dockerfile: ${PWD}/test/container/coverage/Dockerfile.server
      args:
        GOFLAGS: "-cover -covermode=atomic"

  manufacturer:
    environment:
      GOCOVERDIR: ${container_working_dir:-/workdir}/coverage
    volumes:
      - ${server_coverage_dir}:${container_working_dir:-/workdir}/coverage:z

  rendezvous:
    environment:
      GOCOVERDIR: ${container_working_dir:-/workdir}/coverage
    volumes:
      - ${server_coverage_dir}:${container_working_dir:-/workdir}/coverage:z

  owner:
    environment:
      GOCOVERDIR: ${container_working_dir:-/workdir}/coverage
    volumes:
      - ${server_coverage_dir}:${container_working_dir:-/workdir}/coverage:z

  new_owner:
    environment:
      GOCOVERDIR: ${container_working_dir:-/workdir}/coverage
    volumes:
      - ${server_coverage_dir}:${container_working_dir:-/workdir}/coverage:z
```

- [ ] **Step 2: Write `test/container/compose/coverage-overlay-client.yaml`**

```yaml
services:
  go-fdo-client:
    build:
      context: ${client_src_dir}
      dockerfile: ${PWD}/test/container/coverage/Dockerfile.client
      args:
        GOFLAGS: "-cover -covermode=atomic"
    environment:
      GOCOVERDIR: ${container_working_dir:-/workdir}/coverage
    volumes:
      - ${client_coverage_dir}:${container_working_dir:-/workdir}/coverage:z
```

- [ ] **Step 3: Verify the overlay merges cleanly against the base onboarding compose file**

```bash
export base_dir="$(mktemp -d)" client_src_dir=/home/kgiusti/work/fdo/go-fdo-client \
  server_src_dir=/home/kgiusti/work/fdo/go-fdo-server container_user="$(id -u):$(id -g)" \
  container_working_dir=/workdir server_coverage_dir="$(mktemp -d)"
docker compose \
  -f test/container/compose/server/test-onboarding.yaml \
  -f test/container/compose/coverage-overlay-server.yaml \
  config --services
```

Expected: prints `go-fdo-server`, `manufacturer`, `rendezvous`, `owner`, `new_owner` (the last one added by the overlay, harmless per Task 5's explicit service lists) with no YAML merge errors.

- [ ] **Step 4: Commit**

```bash
git add test/container/compose/coverage-overlay-server.yaml test/container/compose/coverage-overlay-client.yaml
git commit -s -m "feat: add docker-compose coverage overlays for server and client containers"
```

---

### Task 5: Container coverage support in `test/container/utils.sh`

**Files:**
- Modify: `test/container/utils.sh:1-22` (exported vars block), `:33-42` (`install_client`/`uninstall_client`), `:44-57` (`run_go_fdo_client`), `:59-76` (`install_server`/`uninstall_server`/`start_service`/`start_services`)

**Interfaces:**
- Consumes: `COVERAGE_ENABLED`, `COVERAGE_ROOT` (same as Task 2).
- Produces: when `COVERAGE_ENABLED=1`, `${COVERAGE_ROOT}/raw/server/` and `${COVERAGE_ROOT}/raw/client/` also receive counter data from container test runs (same two directories Task 2 writes to — this is what gives one merged total across native and container tests).

- [ ] **Step 1: Add coverage plumbing near the top of `test/container/utils.sh`, after the `container_working_dir` export**

```bash
server_coverage_dir="${COVERAGE_ROOT:-}/raw/server"
client_coverage_dir="${COVERAGE_ROOT:-}/raw/client"
export server_coverage_dir
export client_coverage_dir

server_compose_files=("--file" "${servers_compose_file}")
client_compose_files=("--file" "${client_compose_file}")

apply_server_coverage_overlay() {
  coverage_enabled || return 0
  mkdir -p "${server_coverage_dir}"
  server_compose_files+=("--file" "${compose_dir}/coverage-overlay-server.yaml")
}

apply_client_coverage_overlay() {
  coverage_enabled || return 0
  mkdir -p "${client_coverage_dir}"
  client_compose_files+=("--file" "${compose_dir}/coverage-overlay-client.yaml")
}
```

(`coverage_enabled` is already defined in `test/ci/utils.sh`, Task 2, which every `test/container/test-*.sh` sources before `test/container/utils.sh`.)

- [ ] **Step 2: Make `install_client`/`install_server` apply the overlay and pull in explicit service names**

Replace:

```bash
install_client() {
  fetch_client_repo
  docker compose --file "${client_compose_file}" build -q go-fdo-client
}
```

with:

```bash
install_client() {
  fetch_client_repo
  apply_client_coverage_overlay
  docker compose "${client_compose_files[@]}" build -q go-fdo-client
}
```

Replace:

```bash
install_server() {
  fetch_server_repo
  docker compose --file "${servers_compose_file}" build -q go-fdo-server
}
```

with:

```bash
install_server() {
  fetch_server_repo
  apply_server_coverage_overlay
  docker compose "${server_compose_files[@]}" build -q go-fdo-server
  server_service_names="$(docker compose --file "${servers_compose_file}" config --services)"
}
```

(`server_service_names` is captured from the **base** file, before the overlay is applied, so it never includes an overlay-only service like `new_owner` for tests that don't define it.)

- [ ] **Step 3: Make `run_go_fdo_client` use the overlay-aware compose file list**

Replace:

```bash
run_go_fdo_client() {
  # Translate host paths to container paths in arguments
  local args=()
  for arg in "$@"; do
    # Replace base_dir with container_working_dir in paths
    args+=("${arg//$base_dir/$container_working_dir}")
  done
  local exit_code=0
  timeout "${client_timeout}" docker compose --file "${client_compose_file}" run --rm go-fdo-client "${args[@]}" || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    log_warn "Command timed out (${exit_code}): 'go-fdo-client $*'"
  fi
  return ${exit_code}
}
```

with:

```bash
run_go_fdo_client() {
  # Translate host paths to container paths in arguments
  local args=()
  for arg in "$@"; do
    # Replace base_dir with container_working_dir in paths
    args+=("${arg//$base_dir/$container_working_dir}")
  done
  local exit_code=0
  timeout "${client_timeout}" docker compose "${client_compose_files[@]}" run --rm go-fdo-client "${args[@]}" || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    log_warn "Command timed out (${exit_code}): 'go-fdo-client $*'"
  fi
  return ${exit_code}
}
```

- [ ] **Step 4: Make `start_service`/`start_services`/`stop_service`/`stop_services`/`get_service_logs`/`uninstall_server` use the overlay-aware file list and explicit service names**

Replace:

```bash
uninstall_server() {
  docker compose --file "${servers_compose_file}" down
}

start_service() {
  local service_name=$1
  docker compose --file "${servers_compose_file}" up -d "${service_name}"
}

start_services() {
  log_info "Starting services"
  docker compose --file "${servers_compose_file}" up -d
}

stop_service() {
  local service_name=$1
  docker compose --file "${servers_compose_file}" stop "${service_name}"
}

stop_services() {
  docker compose --file "${servers_compose_file}" stop
}

get_service_logs() {
  local service=$1
  docker compose --file "${servers_compose_file}" logs --no-log-prefix "${service}"
}
```

with:

```bash
uninstall_server() {
  docker compose "${server_compose_files[@]}" down
}

start_service() {
  local service_name=$1
  docker compose "${server_compose_files[@]}" up -d "${service_name}"
}

start_services() {
  log_info "Starting services"
  # shellcheck disable=SC2086
  docker compose "${server_compose_files[@]}" up -d ${server_service_names}
}

stop_service() {
  local service_name=$1
  docker compose "${server_compose_files[@]}" stop "${service_name}"
}

stop_services() {
  # shellcheck disable=SC2086
  docker compose "${server_compose_files[@]}" stop ${server_service_names}
}

get_service_logs() {
  local service=$1
  docker compose "${server_compose_files[@]}" logs --no-log-prefix "${service}"
}
```

(`${server_service_names}` is deliberately unquoted — it's a space-separated list of service names computed in Step 2, mirroring how `get_logs`/`save_logs` already iterate `docker compose ... config --services` elsewhere in this file.)

- [ ] **Step 5: Verify the plain (non-coverage) path still passes**

```bash
cd test/container && ./test-onboarding.sh
```

Expected: `[PASS] ✅ Test PASSED!`, identical to before this change.

- [ ] **Step 6: Verify the coverage path produces counter data without starting the phantom `new_owner` service**

```bash
export COVERAGE_ENABLED=1
export COVERAGE_ROOT="$(mktemp -d)"
cd test/container && ./test-onboarding.sh
docker compose --file compose/server/test-onboarding.yaml --file compose/coverage-overlay-server.yaml ps -a --services --filter status=running
ls "${COVERAGE_ROOT}/raw/server" | grep -q . && echo "server coverage OK"
ls "${COVERAGE_ROOT}/raw/client" | grep -q . && echo "client coverage OK"
unset COVERAGE_ENABLED COVERAGE_ROOT
```

Expected: `docker compose ps` output does not list `new_owner` (test-onboarding.sh doesn't use it), both `server coverage OK` and `client coverage OK` are printed.

- [ ] **Step 7: Verify a resale test (which does define `new_owner`) still runs and produces coverage from it too**

```bash
export COVERAGE_ENABLED=1
export COVERAGE_ROOT="$(mktemp -d)"
cd test/container && ./test-resale.sh
unset COVERAGE_ENABLED COVERAGE_ROOT
```

Expected: `[PASS] ✅ Test PASSED!`.

- [ ] **Step 8: Commit**

```bash
git add test/container/utils.sh
git commit -s -m "feat: build container images with coverage instrumentation when enabled"
```

---

### Task 6: Coverage merge script and `make test-coverage`

**Files:**
- Create: `test/coverage/merge.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `${COVERAGE_ROOT}/raw/server`, `${COVERAGE_ROOT}/raw/client` (populated by Tasks 2 and 5).
- Produces: `${COVERAGE_ROOT}/coverage-server.out`, `coverage-server.html`, `coverage-client.out`, `coverage-client.html`; `test/coverage/merge.sh <binary-name> <raw-dir> <src-dir> <out-dir>` prints `TOTAL <binary-name> <NN.N%>` to stdout on success.

- [ ] **Step 1: Write `test/coverage/merge.sh`**

```bash
#! /usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <binary-name> <raw-gocoverdir> <source-dir> <out-dir>" >&2
  exit 1
}

[[ $# -eq 4 ]] || usage

binary_name=$1
raw_dir=$2
src_dir=$3
out_dir=$4

if [[ ! -d "${raw_dir}" ]] || [[ -z "$(ls -A "${raw_dir}" 2>/dev/null)" ]]; then
  echo "no coverage data found in '${raw_dir}' for '${binary_name}'" >&2
  exit 1
fi

mkdir -p "${out_dir}"
out_file="${out_dir}/coverage-${binary_name}.out"
html_file="${out_dir}/coverage-${binary_name}.html"

(cd "${src_dir}" && go tool covdata textfmt -i="${raw_dir}" -o="${out_file}")
(cd "${src_dir}" && go tool cover -html="${out_file}" -o "${html_file}")

total="$(cd "${src_dir}" && go tool cover -func="${out_file}" | awk '/^total:/ {print $NF}')"
echo "TOTAL ${binary_name} ${total}"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x test/coverage/merge.sh
```

- [ ] **Step 3: Add the `test-coverage` target to `Makefile`**

```makefile
COVERAGE_ENABLED := 1
export COVERAGE_ENABLED
export COVERAGE_ROOT

SERVER_SRC_DIR := $(if $(SERVER_LOCAL_PATH),$(SERVER_LOCAL_PATH),$(CURDIR)/src/server)
CLIENT_SRC_DIR := $(if $(CLIENT_LOCAL_PATH),$(CLIENT_LOCAL_PATH),$(CURDIR)/src/client)

.PHONY: test-coverage
test-coverage:
	mkdir -p "$(COVERAGE_ROOT)/raw/server" "$(COVERAGE_ROOT)/raw/client"
	set -e; \
	for t in test/ci/test-*.sh test/container/test-*.sh; do \
		echo "=== RUNNING: $$t ==="; \
		(cd "$$(dirname "$$t")" && "./$$(basename "$$t")"); \
	done
	test/coverage/merge.sh server "$(COVERAGE_ROOT)/raw/server" "$(SERVER_SRC_DIR)" "$(COVERAGE_ROOT)"
	test/coverage/merge.sh client "$(COVERAGE_ROOT)/raw/client" "$(CLIENT_SRC_DIR)" "$(COVERAGE_ROOT)"
```

(`SERVER_SRC_DIR`/`CLIENT_SRC_DIR` resolve to the same checkout paths that `fetch_server_repo`/`fetch_client_repo` in `test/ci/utils.sh` already use by default (`${PWD}/src/server`, `${PWD}/src/client}`) or to `SERVER_LOCAL_PATH`/`CLIENT_LOCAL_PATH` when set — `go tool covdata`/`go tool cover` need to run from a module directory matching the instrumented source to resolve file paths correctly.)

- [ ] **Step 4: Run the full target locally against local checkouts**

```bash
make test-coverage SERVER_LOCAL_PATH=/home/kgiusti/work/fdo/go-fdo-server CLIENT_LOCAL_PATH=/home/kgiusti/work/fdo/go-fdo-client
```

Expected: every `test-*.sh` under `test/ci` and `test/container` prints `[PASS]`, followed by two lines matching `TOTAL server <NN.N%>` and `TOTAL client <NN.N%>`, and `test-coverage/coverage-server.html`/`coverage-client.html` exist and are non-empty.

- [ ] **Step 5: Verify `make clean` removes the newly generated coverage output**

```bash
make clean
test ! -d test-coverage && echo OK
```

Expected: prints `OK`.

- [ ] **Step 6: Commit**

```bash
git add test/coverage/merge.sh Makefile
git commit -s -m "feat: add make test-coverage target that runs and merges e2e coverage"
```

---

### Task 7: CI — collect and report coverage in `e2e.yml`

**Files:**
- Modify: `.github/workflows/e2e.yml`

**Interfaces:**
- Consumes: `test/coverage/merge.sh` (Task 6), the `COVERAGE_ENABLED`/`GOCOVERDIR`-aware `test/ci/utils.sh` and `test/container/utils.sh` (Tasks 2 and 5).
- Produces: per-matrix-job artifacts `coverage-raw-${{ matrix.name }}`, a final `coverage-report` job that writes totals to `$GITHUB_STEP_SUMMARY` and uploads `coverage-server.html`/`coverage-client.html`.

- [ ] **Step 1: Set coverage env vars and upload raw data in the `e2e` job**

In `.github/workflows/e2e.yml`, add a `COVERAGE_ROOT` env var to the `e2e` job and export `COVERAGE_ENABLED`, and add an upload step after the existing cleanup step:

```yaml
  e2e:
    name: "${{ matrix.type }}: ${{ matrix.name }}"
    runs-on: ubuntu-latest
    needs: setup
    env:
      COVERAGE_ENABLED: "1"
      COVERAGE_ROOT: ${{ github.workspace }}/test-coverage
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.setup.outputs.matrix) }}
    steps:
      - name: Install golang
        uses: actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff # v5
        with:
          go-version: "1.26"

      - name: Check out go-fdo-ci
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          repository: fido-device-onboard/go-fdo-ci
          ref: ${{ inputs.go-fdo-ci-ref || github.ref }}

      - name: Check out go-fdo-server
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          repository: fido-device-onboard/go-fdo-server
          ref: ${{ inputs.go-fdo-server-ref || 'main' }}
          path: src/server

      - name: Check out go-fdo-client
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          repository: fido-device-onboard/go-fdo-client
          ref: ${{ inputs.go-fdo-client-ref || 'main' }}
          path: src/client

      - name: ${{ matrix.name }}
        run: |
          source ${{ matrix.dir }}/${{ matrix.test }}
          run_test

      - name: Get Manufacturer, Rendezvous and Owner server logs
        if: always()
        run: |
          source ${{ matrix.dir }}/${{ matrix.test }}
          get_logs

      - name: Cleanup the environment
        if: always()
        run: |
          source ${{ matrix.dir }}/${{ matrix.test }}
          cleanup

      - name: Upload raw coverage data
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: coverage-raw-${{ matrix.name }}
          path: ${{ env.COVERAGE_ROOT }}/raw
          if-no-files-found: warn
```

(`COVERAGE_ROOT` is set outside `base_dir`/`workdir`, so `cleanup`'s `remove_files` — which only touches `${base_dir}/*` — never deletes it; `if-no-files-found: warn` rather than `error`, since a test that fails before any binary starts may legitimately produce nothing.)

- [ ] **Step 2: Add the `coverage-report` job**

Append a new top-level job:

```yaml
  coverage-report:
    name: "Coverage report"
    runs-on: ubuntu-latest
    needs: e2e
    if: always()
    steps:
      - name: Install golang
        uses: actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff # v5
        with:
          go-version: "1.26"

      - name: Check out go-fdo-ci
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          repository: fido-device-onboard/go-fdo-ci
          ref: ${{ inputs.go-fdo-ci-ref || github.ref }}

      - name: Check out go-fdo-server
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          repository: fido-device-onboard/go-fdo-server
          ref: ${{ inputs.go-fdo-server-ref || 'main' }}
          path: src/server

      - name: Check out go-fdo-client
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          repository: fido-device-onboard/go-fdo-client
          ref: ${{ inputs.go-fdo-client-ref || 'main' }}
          path: src/client

      - name: Download all raw coverage artifacts
        uses: actions/download-artifact@v7
        with:
          pattern: coverage-raw-*
          path: test-coverage/downloaded
          merge-multiple: false

      - name: Merge downloaded coverage into shared raw dirs
        run: |
          mkdir -p test-coverage/raw/server test-coverage/raw/client
          find test-coverage/downloaded -path '*/server/*' -type f -exec cp -t test-coverage/raw/server {} +
          find test-coverage/downloaded -path '*/client/*' -type f -exec cp -t test-coverage/raw/client {} +

      - name: Merge and report server coverage
        run: test/coverage/merge.sh server test-coverage/raw/server "${{ github.workspace }}/src/server" test-coverage | tee -a "$GITHUB_STEP_SUMMARY"

      - name: Merge and report client coverage
        run: test/coverage/merge.sh client test-coverage/raw/client "${{ github.workspace }}/src/client" test-coverage | tee -a "$GITHUB_STEP_SUMMARY"

      - name: Upload merged coverage reports
        uses: actions/upload-artifact@v7
        with:
          name: coverage-report
          path: |
            test-coverage/coverage-server.html
            test-coverage/coverage-client.html
```

- [ ] **Step 3: Validate the workflow YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/e2e.yml'))" && echo "YAML OK"
```

Expected: prints `YAML OK`.

- [ ] **Step 4: Push to a branch and confirm on GitHub Actions**

Push the branch, open a draft PR (or use `workflow_dispatch`), and confirm: every matrix job uploads a `coverage-raw-*` artifact, the `coverage-report` job runs after all matrix jobs finish (`if: always()`), and its summary shows two `TOTAL server ...%` / `TOTAL client ...%` lines with reasonable non-zero percentages, plus a downloadable `coverage-report` artifact containing both HTML files.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/e2e.yml
git commit -s -m "ci: collect and report e2e coverage totals for server and client"
```

---

## Self-Review Notes

- **Spec coverage:** shared persistent raw dirs (§1) → Tasks 2/5; `COVERAGE_ENABLED` toggle (§2) → Tasks 2/5; coverage Dockerfiles + overlay (§2 container) → Tasks 3/4; Makefile `test-coverage` (§3) → Task 6; `clean` (user-added requirement) → Task 1 + verified again in Task 6; CI artifact upload + `coverage-report` job (§4) → Task 7.
- **Phantom-service risk** (overlay defining `new_owner` for tests that don't use it) is explicitly handled in Task 5 by always deriving service names from the un-overlaid base file before invoking `up`/`stop`, and verified in Task 5 Steps 6–7.
- **Type/name consistency:** `COVERAGE_ENABLED`, `COVERAGE_ROOT`, `server_gocoverdir`/`client_gocoverdir` (native), `server_coverage_dir`/`client_coverage_dir` (container), `server_compose_files`/`client_compose_files`, `server_service_names`, and `test/coverage/merge.sh <binary-name> <raw-dir> <src-dir> <out-dir>` are used with the same names/argument order everywhere they appear across Tasks 2, 5, 6, 7.
