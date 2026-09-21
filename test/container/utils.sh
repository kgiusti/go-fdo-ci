#! /usr/bin/env bash

set -euo pipefail

compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/compose"
client_compose_file="${compose_dir}/client/client.yaml"
servers_compose_file="${compose_dir}/server/test-onboarding.yaml"

coverage_dockerfile_server="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/coverage/Dockerfile.server"
coverage_dockerfile_client="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/coverage/Dockerfile.client"
export coverage_dockerfile_server
export coverage_dockerfile_client

# Export base_dir explicitly for Docker Compose
export base_dir

# Export client and server source dir for Docker Compose
export client_src_dir
export server_src_dir

# Export container_user explicitly for Docker Compose
container_user="$(id -u):$(id -g)"
export container_user

# Container working directory
container_working_dir="/workdir"
export container_working_dir

server_coverage_dir="${COVERAGE_ROOT:+${COVERAGE_ROOT}/raw/server}"
client_coverage_dir="${COVERAGE_ROOT:+${COVERAGE_ROOT}/raw/client}"
export server_coverage_dir
export client_coverage_dir

server_service_names=""

# Compute the docker compose --file arguments for the servers compose file(s),
# lazily, at call time. This must NOT be computed once at source time because
# many test scripts override 'servers_compose_file' after sourcing this file.
server_compose_args() {
  local args=("--file" "${servers_compose_file}")
  coverage_enabled && args+=("--file" "${compose_dir}/coverage-overlay-server.yaml")
  printf '%s\n' "${args[@]}"
}

# Same as 'server_compose_args', but for the client compose file(s).
client_compose_args() {
  local args=("--file" "${client_compose_file}")
  coverage_enabled && args+=("--file" "${compose_dir}/coverage-overlay-client.yaml")
  printf '%s\n' "${args[@]}"
}

apply_server_coverage_overlay() {
  coverage_enabled || return 0
  mkdir -p "${server_coverage_dir}"
}

apply_client_coverage_overlay() {
  coverage_enabled || return 0
  mkdir -p "${client_coverage_dir}"
}

curl() {
  docker run --user "${container_user}" --network fdo --volume "${PWD}:${PWD}:z" --rm curlimages/curl "$@"
}

get_real_ip() {
  local service_name=$1
  docker inspect --format='{{.NetworkSettings.Networks.fdo.IPAddress}}' "${service_name}"
}

install_client() {
  fetch_client_repo
  apply_client_coverage_overlay
  local client_compose_files=()
  mapfile -t client_compose_files < <(client_compose_args)
  docker compose "${client_compose_files[@]}" build -q go-fdo-client
}

uninstall_client() {
  # we don't need to remove any container, all of them are removed after invocation
  # but we need to remove the container image.
  docker compose --file "${client_compose_file}" down
}

run_go_fdo_client() {
  # Translate host paths to container paths in arguments
  local args=()
  for arg in "$@"; do
    # Replace base_dir with container_working_dir in paths
    args+=("${arg//$base_dir/$container_working_dir}")
  done
  local client_compose_files=()
  mapfile -t client_compose_files < <(client_compose_args)
  local exit_code=0
  timeout "${client_timeout}" docker compose "${client_compose_files[@]}" run --rm go-fdo-client "${args[@]}" || exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    log_warn "Command timed out (${exit_code}): 'go-fdo-client $*'"
  fi
  return ${exit_code}
}

install_server() {
  fetch_server_repo
  apply_server_coverage_overlay
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  docker compose "${server_compose_files[@]}" build -q go-fdo-server
  server_service_names="$(docker compose --file "${servers_compose_file}" config --services)"
}

uninstall_server() {
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  docker compose "${server_compose_files[@]}" down
}

start_service() {
  local service_name=$1
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  docker compose "${server_compose_files[@]}" up -d "${service_name}"
}

start_services() {
  log_info "Starting services"
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  # shellcheck disable=SC2086
  docker compose "${server_compose_files[@]}" up -d ${server_service_names}
}

stop_service() {
  local service_name=$1
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  docker compose "${server_compose_files[@]}" stop "${service_name}"
}

stop_services() {
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  # shellcheck disable=SC2086
  docker compose "${server_compose_files[@]}" stop ${server_service_names}
}

get_service_logs() {
  local service=$1
  local server_compose_files=()
  mapfile -t server_compose_files < <(server_compose_args)
  docker compose "${server_compose_files[@]}" logs --no-log-prefix "${service}"
}

get_logs() {
  log_info "Retrieving logs"
  for service in $(docker compose --file "${servers_compose_file}" config --services); do
    log "🛑 '${service}' logs:\n"
    get_service_logs "${service}"
  done
}

save_service_logs() {
  local service=$1
  local log_file="${logs_dir}/${service}.log"
  get_service_logs "${service}" >"${log_file}"
}

save_logs() {
  log_info "Saving logs"
  for service in $(docker compose --file "${servers_compose_file}" config --services); do
    log "\t⚙ Saving '${service}' logs "
    save_service_logs "${service}"
    log_success
  done
}

on_failure() {
  trap - EXIT
  save_logs
  stop_services
  test_fail
}

# If a configuration file is present we need to modify all file paths used in the configuration
# to be rooted at container_working_dir, not base_dir. This allows the container tests to
# use configuration files generated by the CI tests
configure_services() {
  generate_https_certs
  log_info "Configuring services"
  for service in "${services[@]}"; do
    configure_service "${service}"
    local conf_file="${service}_config_file"
    if [[ -v "${conf_file}" && -f "${!conf_file}" ]]; then
      sed -i "s%${base_dir}%${container_working_dir}%g" "${!conf_file}"
    fi
  done
}
