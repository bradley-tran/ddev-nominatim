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
  assert_output --partial "nominatim-ui"

  # Wait for Nominatim to become ready if still importing
  echo "# Waiting for Nominatim status endpoint to return OK..." >&3
  count=0
  while [ $count -lt 90 ]; do
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

  # Wait for Nominatim UI to become ready
  echo "# Waiting for Nominatim UI to become ready..." >&3
  count=0
  while [ $count -lt 30 ]; do
    if ddev exec -s nominatim-ui wget -qO- http://127.0.0.1/ >/dev/null 2>&1; then
      break
    fi
    sleep 2
    count=$((count + 1))
  done

  # Wait for DDEV router to route Nominatim UI
  count=0
  while [ $count -lt 30 ]; do
    if curl -sf --resolve "${PROJNAME}.ddev.site:8765:127.0.0.1" "http://${PROJNAME}.ddev.site:8765/" >/dev/null 2>&1; then
      break
    fi
    sleep 2
    count=$((count + 1))
  done

  # Verify Nominatim UI web interface responds via host/DDEV router
  run curl -sf --resolve "${PROJNAME}.ddev.site:8765:127.0.0.1" "http://${PROJNAME}.ddev.site:8765/"
  assert_success
  assert_output --partial "search.html"

  # Verify Nominatim UI search.html page
  run curl -sf --resolve "${PROJNAME}.ddev.site:8765:127.0.0.1" "http://${PROJNAME}.ddev.site:8765/search.html"
  assert_success
  assert_output --partial "Nominatim"

  # Verify Nominatim UI reverse proxies /api/status to Nominatim API
  run curl -sf --resolve "${PROJNAME}.ddev.site:8765:127.0.0.1" "http://${PROJNAME}.ddev.site:8765/api/status"
  assert_success
  assert_output --partial "OK"

  # Verify Nominatim UI reverse proxies /api/search to Nominatim API
  run curl -sf --resolve "${PROJNAME}.ddev.site:8765:127.0.0.1" "http://${PROJNAME}.ddev.site:8765/api/search?q=avenue+pasteur&format=json"
  assert_success
  assert_output --partial "Pasteur"

  # Verify custom nominatim command works
  run ddev nominatim --version
  assert_success
  assert_output --partial "Nominatim version"

  run ddev nominatim status
  assert_success
  assert_output --partial "OK"

  # Verify custom nominatim-ui command help works
  run ddev nominatim-ui --help
  assert_success
  assert_output --partial "Launch a browser with Nominatim UI"
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

@test "install from directory with NOMINATIM_PBF_PATH" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run curl -sfL "https://download.geofabrik.de/europe/monaco-latest.osm.pbf" -o monaco.osm.pbf
  assert_success
  run ddev dotenv set .ddev/.env.nominatim --nominatim-pbf-path="monaco.osm.pbf"
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

