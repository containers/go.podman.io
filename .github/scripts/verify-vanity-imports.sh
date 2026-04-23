#!/usr/bin/env bash
set -euo pipefail

echo "This test modifies /etc/hosts to add a local DNS entry for go.podman.io. It will be removed after the test completes."
echo "Review your /etc/hosts file after the test completes."

HOSTS_MARKER="# verify-vanity-imports"
HOSTS_ENTRY="127.0.0.1 go.podman.io ${HOSTS_MARKER}"

cleanup() {
  sudo kill "${SERVER_PID:-}" 2>/dev/null || true

  if grep -qF "${HOSTS_MARKER}" /etc/hosts; then
    hosts_tmp="$(mktemp)"
    awk -v entry="${HOSTS_ENTRY}" '$0 != entry { print }' /etc/hosts >"${hosts_tmp}"
    sudo cp "${hosts_tmp}" /etc/hosts
    rm -f "${hosts_tmp}"
  fi
}
trap cleanup EXIT

if ! grep -qxF "${HOSTS_ENTRY}" /etc/hosts; then
  echo "${HOSTS_ENTRY}" | sudo tee -a /etc/hosts >/dev/null
fi

# Start the web-server and wait for it to be ready.
sudo python3 -m http.server 80 --bind 127.0.0.1 --directory . &
SERVER_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://go.podman.io/"; then
    break
  fi
  sleep 0.2
done

# Discover all vanity module directories and versioned parents.
# This is needed for recursive ** globbing.
shopt -s globstar nullglob

module_dirs=()
versioned_parents=()
for index_file in **/index.html; do
  module_dir="${index_file%/index.html}"

  if [[ -z "${module_dir}" || "${module_dir}" == "index.html" ]]; then
    continue
  fi

  module_dirs+=("${module_dir}")
  if [[ "${module_dir}" =~ /v[0-9]+$ ]]; then
    versioned_parents+=("${module_dir%/*}")
  fi
done

if [[ ${#module_dirs[@]} -eq 0 ]]; then
  echo "No vanity module directories discovered"
  exit 1
fi

# Create a temporary go module. The go get command needs it.
WORKDIR=$(mktemp -d)
cd "${WORKDIR}"
go mod init local.test/vanity

export GOINSECURE=go.podman.io
export GOPROXY=direct
export GOSUMDB=off

failures=0
for module_dir in "${module_dirs[@]}"; do
  # Skip parent module path when a versioned child path exists.
  if printf '%s\n' "${versioned_parents[@]}" | grep -qx "${module_dir}"; then
    continue
  fi

  module="go.podman.io/${module_dir}@main"
  echo "Testing ${module}"
  if ! go get -v "${module}"; then
    echo "FAILED: ${module}"
    failures=$((failures + 1))
  fi
done

if [[ ${failures} -gt 0 ]]; then
  echo "${failures} vanity import test(s) failed"
  exit 1
fi
