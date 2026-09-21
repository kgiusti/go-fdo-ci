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
raw_dir="$(cd "${raw_dir}" && pwd)"

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
out_file="${out_dir}/coverage-${binary_name}.out"
html_file="${out_dir}/coverage-${binary_name}.html"

(cd "${src_dir}" && go tool covdata textfmt -i="${raw_dir}" -o="${out_file}")
(cd "${src_dir}" && go tool cover -html="${out_file}" -o "${html_file}")

total="$(cd "${src_dir}" && go tool cover -func="${out_file}" | awk '/^total:/ {print $NF}')"
echo "TOTAL ${binary_name} ${total}"
