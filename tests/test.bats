#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=bradley-tran/ddev-nominatim

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site --default-container-timeout=300
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # Verify container is running and listed by DDEV
  run ddev describe
  assert_success
  assert_output --partial "nominatim"

  # Wait for Nominatim to become healthy if still importing
  echo "# Waiting for Nominatim status endpoint to return OK..." >&3
  count=0
  while [ $count -lt 30 ]; do
    if ddev exec -s nominatim curl -sf http://localhost:8080/status >/dev/null 2>&1; then
      break
    fi
    sleep 2
    count=$((count + 1))
  done

  # Verify the /status endpoint returns OK from inside the container
  run ddev exec -s nominatim curl -sf http://localhost:8080/status
  assert_success
  assert_output --partial "OK"

  # Verify web container can reach Nominatim internally
  run ddev exec curl -sf http://nominatim:8080/status
  assert_success
  assert_output --partial "OK"

  # Query the search API for Monaco data from web container
  run ddev exec curl -sf "http://nominatim:8080/search?q=avenue+pasteur&format=json"
  assert_success
  assert_output --partial "Pasteur"

  # Query the status endpoint via host/DDEV router
  run curl -sf --resolve "${PROJNAME}.ddev.site:8980:127.0.0.1" "http://${PROJNAME}.ddev.site:8980/status"
  assert_success
  assert_output --partial "OK"

  # Query the search API via host/DDEV router
  run curl -sf --resolve "${PROJNAME}.ddev.site:8980:127.0.0.1" "http://${PROJNAME}.ddev.site:8980/search?q=avenue+pasteur&format=json"
  assert_success
  assert_output --partial "Pasteur"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
