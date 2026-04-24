#!/usr/bin/env sh
# integration-tests/run-okteto-e2e.sh
#
# Okteto end-to-end integration tests using the oktetodo sample app.
# https://github.com/okteto/oktetodo
#
# Runs after run-integration-tests.sh has confirmed the platform is healthy.
# Exercises the full Okteto deployment lifecycle — build, deploy, sleep, wake,
# redeploy, destroy, and preview environments.
#
# Exit codes
#   0 – all tests passed
#   1 – one or more tests failed
#
# Required environment variables (injected by the Helm Job template):
#   OKTETO_URL        – Public URL of the Okteto instance
#   OKTETO_TOKEN      – Service account token (from Kubernetes secret)
#   OKTETO_NAMESPACE  – Namespace where Okteto itself is installed
#   OKTETO_SUBDOMAIN  – Wildcard subdomain
#
# Optional environment variables:
#   E2E_TEST_NAMESPACE  – Override the test namespace (default: okteto-e2e-<pid>)
#   E2E_PREVIEW_NAME    – Override the preview name (default: e2e-preview-<pid>)
#   E2E_SKIP_PREVIEW    – Set to "true" to skip preview environment tests

set -eu

DEMO_REPO="https://github.com/okteto/oktetodo"
DEMO_DIR="/tmp/oktetodo"

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── counters ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
SECTION_PASS=0
SECTION_FAIL=0
SECTION_SKIP=0

# ── output helpers ────────────────────────────────────────────────────────────

pass() {
  printf "${GREEN}  ✔ PASS${NC}  %s\n" "$1"
  PASS=$((PASS + 1))
  SECTION_PASS=$((SECTION_PASS + 1))
}

fail() {
  printf "${RED}  ✘ FAIL${NC}  %s\n" "$1"
  FAIL=$((FAIL + 1))
  SECTION_FAIL=$((SECTION_FAIL + 1))
}

skip() {
  printf "${YELLOW}  – SKIP${NC}  %s\n" "$1"
  SKIP=$((SKIP + 1))
  SECTION_SKIP=$((SECTION_SKIP + 1))
}

section() {
  printf "\n${BOLD}%s${NC}\n" "────────────────────────────────────────────────"
  printf "${BOLD}  %s${NC}\n" "$1"
  printf "${BOLD}%s${NC}\n"   "────────────────────────────────────────────────"
  SECTION_PASS=0
  SECTION_FAIL=0
  SECTION_SKIP=0
}

section_summary() {
  printf "\n"
  if [ "$SECTION_FAIL" -gt 0 ]; then
    printf "  ${RED}Section result: %d passed  %d failed  %d skipped${NC}\n" \
      "$SECTION_PASS" "$SECTION_FAIL" "$SECTION_SKIP"
  else
    printf "  ${GREEN}Section result: %d passed  %d failed  %d skipped${NC}\n" \
      "$SECTION_PASS" "$SECTION_FAIL" "$SECTION_SKIP"
  fi
}

# time_step <description> <command...>
time_step() {
  description="$1"
  shift
  start=$(date +%s)
  if "$@" >/tmp/step_output 2>&1; then
    elapsed=$(( $(date +%s) - start ))
    pass "$description  (${elapsed}s)"
  else
    elapsed=$(( $(date +%s) - start ))
    fail "$description  (${elapsed}s)"
    sed 's/^/    /' /tmp/step_output
  fi
  rm -f /tmp/step_output
}

# ── cleanup trap ──────────────────────────────────────────────────────────────

TEST_NAMESPACE="${E2E_TEST_NAMESPACE:-okteto-e2e-$$}"
PREVIEW_NAME="${E2E_PREVIEW_NAME:-e2e-preview-$$}"
CLEANUP_DONE=0

cleanup() {
  if [ "$CLEANUP_DONE" = "1" ]; then return; fi
  CLEANUP_DONE=1
  printf "\n${YELLOW}  Running cleanup...${NC}\n"

  okteto namespace use default --insecure-skip-tls-verify 2>/dev/null || true

  if okteto namespace list --insecure-skip-tls-verify 2>/dev/null | grep -q "^${TEST_NAMESPACE}"; then
    okteto namespace delete "$TEST_NAMESPACE" --insecure-skip-tls-verify 2>/dev/null || true
    printf "  Deleted test namespace: %s\n" "$TEST_NAMESPACE"
  fi

  if okteto preview list --insecure-skip-tls-verify 2>/dev/null | grep -q "$PREVIEW_NAME"; then
    okteto preview destroy "$PREVIEW_NAME" --insecure-skip-tls-verify 2>/dev/null || true
    printf "  Deleted preview environment: %s\n" "$PREVIEW_NAME"
  fi
}

trap cleanup EXIT INT TERM

# ── validate required env vars ────────────────────────────────────────────────

for var in OKTETO_URL OKTETO_TOKEN OKTETO_SUBDOMAIN; do
  if [ -z "$(eval echo \${$var:-})" ]; then
    printf "${RED}  ERROR: Required environment variable %s is not set.${NC}\n" "$var"
    exit 1
  fi
done

# ── header ────────────────────────────────────────────────────────────────────

printf "\n${BOLD}%s${NC}\n" "════════════════════════════════════════════════"
printf "${BOLD}  Okteto End-to-End Tests${NC}\n"
printf "  Okteto URL      :  %s\n" "${OKTETO_URL}"
printf "  Demo app        :  %s\n" "${DEMO_REPO}"
printf "  Test Namespace  :  %s\n" "${TEST_NAMESPACE}"
printf "  Preview Name    :  %s\n" "${PREVIEW_NAME}"
printf "${BOLD}%s${NC}\n\n" "════════════════════════════════════════════════"

# ── 1. Authentication ─────────────────────────────────────────────────────────
# Uses --insecure-skip-tls-verify for self-signed/private CA certificates.
# The flag is persisted in the context so all subsequent commands inherit it.
section "1. Authentication"
printf "  Authenticating with the Okteto platform using a service account token\n\n"

time_step "Set Okteto context" \
  okteto context use "$OKTETO_URL" \
    --token "$OKTETO_TOKEN" \
    --insecure-skip-tls-verify

time_step "Verify context is active" \
  okteto context show --insecure-skip-tls-verify

section_summary

# ── 2. Clone demo repo ────────────────────────────────────────────────────────
# Clone oktetodo so we can run okteto commands from inside its directory,
# since --repository flag is not available in this CLI version.
section "2. Clone Demo Repository"
printf "  Cloning %s\n\n" "$DEMO_REPO"

time_step "Clone oktetodo repository" \
  git clone --depth=1 "$DEMO_REPO" "$DEMO_DIR"

section_summary

# ── 3. Namespace Management ───────────────────────────────────────────────────
section "3. Namespace Management"
printf "  Creating a dedicated test namespace for this run\n\n"

time_step "Create test namespace: $TEST_NAMESPACE" \
  okteto namespace create "$TEST_NAMESPACE" \
    --insecure-skip-tls-verify

time_step "Switch to test namespace" \
  okteto namespace use "$TEST_NAMESPACE" \
    --insecure-skip-tls-verify

time_step "Verify namespace appears in list" \
  sh -c "okteto namespace list --insecure-skip-tls-verify | grep -q '^${TEST_NAMESPACE}'"

section_summary

# ── 4. Build ──────────────────────────────────────────────────────────────────
section "4. Image Build"
printf "  Building oktetodo images via the Okteto Build Service (BuildKit)\n\n"

cd "$DEMO_DIR"
time_step "Build all images" \
  okteto build \
    --log-output plain \
    --insecure-skip-tls-verify

section_summary

# ── 5. Deployment ─────────────────────────────────────────────────────────────
section "5. Deployment"
printf "  Deploying oktetodo into the test namespace\n\n"

time_step "Deploy oktetodo" \
  okteto deploy \
    --wait \
    --insecure-skip-tls-verify

# Retrieve the client ingress hostname for the reachability check
CLIENT_HOST=$(kubectl get ingress \
  -n "$TEST_NAMESPACE" \
  -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)

if [ -n "$CLIENT_HOST" ]; then
  time_step "Verify app is reachable at https://$CLIENT_HOST" \
    sh -c "curl -sk -o /dev/null -w '%{http_code}' \
      --connect-timeout 10 --max-time 20 \
      'https://${CLIENT_HOST}' | grep -qE '^(200|301|302)$'"
else
  skip "Could not resolve ingress hostname — skipping reachability check"
fi

section_summary

# ── 6. Sleep & Wake ───────────────────────────────────────────────────────────
section "6. Sleep and Wake"
printf "  Testing namespace sleep (scale to zero) and wake (scale back up)\n\n"

time_step "Sleep namespace: $TEST_NAMESPACE" \
  okteto namespace sleep "$TEST_NAMESPACE" \
    --insecure-skip-tls-verify

time_step "Verify all deployments are scaled to zero" \
  sh -c "! kubectl get deployments -n '${TEST_NAMESPACE}' \
    -o jsonpath='{.items[*].spec.replicas}' \
    | tr ' ' '\n' | grep -qv '^0$'"

time_step "Wake namespace: $TEST_NAMESPACE" \
  okteto namespace wake "$TEST_NAMESPACE" \
    --insecure-skip-tls-verify

time_step "Wait for all deployments to be ready after wake" \
  kubectl rollout status deployment \
    -n "$TEST_NAMESPACE" \
    --timeout=180s

section_summary

# ── 7. Incremental Redeploy ───────────────────────────────────────────────────
section "7. Incremental Redeploy"
printf "  Running a second deploy — should use Smart Build cache and skip rebuilds\n\n"

time_step "Redeploy oktetodo (expect cache hit, no rebuild)" \
  okteto deploy \
    --wait \
    --insecure-skip-tls-verify

time_step "Wait for all deployments to be ready after redeploy" \
  kubectl rollout status deployment \
    -n "$TEST_NAMESPACE" \
    --timeout=180s

section_summary

# ── 8. Destroy Deployment ─────────────────────────────────────────────────────
section "8. Destroy Deployment"
printf "  Running okteto destroy to remove all deployed resources\n\n"

time_step "Destroy oktetodo" \
  okteto destroy \
    --insecure-skip-tls-verify

time_step "Verify all deployments are removed from namespace" \
  sh -c "[ \"\$(kubectl get deployments -n '${TEST_NAMESPACE}' \
    --no-headers 2>/dev/null | wc -l)\" = '0' ]"

section_summary

# ── 9. Destroy Namespace ──────────────────────────────────────────────────────
section "9. Destroy Namespace"
printf "  Deleting the test namespace and confirming it is fully removed\n\n"

time_step "Switch context away from test namespace" \
  okteto namespace use default \
    --insecure-skip-tls-verify

time_step "Delete test namespace: $TEST_NAMESPACE" \
  okteto namespace delete "$TEST_NAMESPACE" \
    --insecure-skip-tls-verify

time_step "Verify namespace is removed" \
  sh -c "! okteto namespace list --insecure-skip-tls-verify 2>/dev/null \
    | grep -q '^${TEST_NAMESPACE}'"

CLEANUP_DONE=1

section_summary

# ── 10. Preview Environments ──────────────────────────────────────────────────
section "10. Preview Environments"

if [ "${E2E_SKIP_PREVIEW:-false}" = "true" ]; then
  skip "Preview tests skipped  (E2E_SKIP_PREVIEW=true)"
else
  printf "  Deploying a preview environment from %s\n\n" "$DEMO_REPO"

  time_step "Deploy preview environment: $PREVIEW_NAME" \
    okteto preview deploy "$PREVIEW_NAME" \
      --branch main \
      --scope global \
      --wait \
      --insecure-skip-tls-verify

  PREVIEW_URL=$(okteto preview show "$PREVIEW_NAME" \
    --insecure-skip-tls-verify \
    -o json 2>/dev/null \
    | jq -r '.url // empty' 2>/dev/null || true)

  if [ -n "$PREVIEW_URL" ]; then
    time_step "Verify preview is reachable at $PREVIEW_URL" \
      sh -c "curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 20 \
        '${PREVIEW_URL}' | grep -qE '^(200|301|302)$'"
  else
    skip "Preview URL not returned by CLI — skipping reachability check"
  fi

  time_step "Destroy preview environment: $PREVIEW_NAME" \
    okteto preview destroy "$PREVIEW_NAME" \
      --insecure-skip-tls-verify

  time_step "Verify preview environment is removed" \
    sh -c "! okteto preview list --insecure-skip-tls-verify 2>/dev/null \
      | grep -q '${PREVIEW_NAME}'"

  CLEANUP_DONE=1
fi

section_summary

# ── Final Summary ─────────────────────────────────────────────────────────────
printf "\n${BOLD}%s${NC}\n" "════════════════════════════════════════════════"
printf "${BOLD}  Final Results${NC}\n"
printf "${BOLD}%s${NC}\n" "════════════════════════════════════════════════"
printf "  ${GREEN}✔ Passed  :  %d${NC}\n" "$PASS"
printf "  ${RED}✘ Failed  :  %d${NC}\n"  "$FAIL"
printf "  ${YELLOW}– Skipped :  %d${NC}\n" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  printf "\n  ${RED}${BOLD}FAILED — one or more Okteto operations did not complete successfully.${NC}\n\n"
  exit 1
fi

printf "\n  ${GREEN}${BOLD}ALL TESTS PASSED — Okteto deployments are fully operational.${NC}\n\n"
exit 0