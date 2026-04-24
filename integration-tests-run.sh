#!/usr/bin/env sh
# integration-tests/run.sh
#
# Okteto platform integration tests.
#
# Verifies that every core Okteto component is healthy and reachable so that
# user deployments can succeed.  The script is designed to run inside the Job
# container defined in chart/okteto/templates/integration-test-job.yaml.
#
# Exit codes
#   0 – all tests passed
#   1 – one or more tests failed
#
# Required environment variables (injected by the Helm Job template):
#   OKTETO_NAMESPACE          – Kubernetes namespace where Okteto is installed
#   OKTETO_RELEASE_NAME       – Helm release full-name prefix (e.g. "okteto")
#   OKTETO_SUBDOMAIN          – Wildcard subdomain (e.g. "dev.example.com")
#   OKTETO_API_ENDPOINT       – Internal ClusterIP URL for the Okteto API
#   OKTETO_BUILDKIT_ENDPOINT  – Internal URL for the BuildKit service
#   OKTETO_REGISTRY_ENDPOINT  – Public registry URL
#   OKTETO_FRONTEND_ENDPOINT  – Public frontend URL
#   OKTETO_WEBHOOK_ENDPOINT   – Internal mutation-webhook URL

set -eu

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── counters (global and per-section) ─────────────────────────────────────────
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

# Print a section header and reset per-section counters
section() {
  printf "\n${BOLD}%s${NC}\n" "────────────────────────────────────────────────"
  printf "${BOLD}  %s${NC}\n" "$1"
  printf "${BOLD}%s${NC}\n"   "────────────────────────────────────────────────"
  SECTION_PASS=0
  SECTION_FAIL=0
  SECTION_SKIP=0
}

# Print a section summary line after each section
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

# ── test helpers ──────────────────────────────────────────────────────────────

# kubectl_check_rollout <resource_type> <label_selector>
kubectl_check_rollout() {
  resource_type="$1"
  selector="$2"
  names=$(kubectl get "$resource_type" -n "$OKTETO_NAMESPACE" \
    -l "$selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [ -z "$names" ]; then
    skip "No ${resource_type} found with selector '${selector}'"
    return
  fi
  for name in $names; do
    # Strip release prefix and any trailing hash suffix for a readable label
    # e.g. "okteto-buildkit-67cc48be41" -> "buildkit"
    label=$(echo "$name" \
      | sed "s/^${OKTETO_RELEASE_NAME}-//" \
      | sed 's/-[a-f0-9]\{8,\}$//')
    if kubectl rollout status "$resource_type/$name" \
        -n "$OKTETO_NAMESPACE" --timeout=60s >/dev/null 2>&1; then
      pass "$label"
    else
      fail "$label  (rollout not complete)"
    fi
  done
}

# pods_ready <label_selector> <description>
pods_ready() {
  selector="$1"
  description="$2"
  not_ready=$(kubectl get pods -n "$OKTETO_NAMESPACE" \
    -l "$selector" \
    --field-selector='status.phase=Running' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.ready}{"\t"}{end}{"\n"}{end}' 2>/dev/null \
    | grep -v "true" | grep -v "^$" || true)
  if [ -z "$not_ready" ]; then
    pass "$description"
  else
    fail "$description  (one or more pods not ready)"
    printf "%s\n" "$not_ready"
  fi
}

# no_crashlooping <label_selector> <description>
no_crashlooping() {
  selector="$1"
  description="$2"
  crashers=$(kubectl get pods -n "$OKTETO_NAMESPACE" \
    -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\t"}{end}{"\n"}{end}' 2>/dev/null \
    | grep -i "CrashLoopBackOff\|Error\|OOMKilled" || true)
  if [ -z "$crashers" ]; then
    pass "$description"
  else
    fail "$description  (crash-looping pods detected)"
    printf "%s\n" "$crashers"
  fi
}

# http_check <description> <url> [expected_http_code]
http_check() {
  description="$1"
  url="$2"
  expected="${3:-200}"
  actual=$(curl -sk -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    fail "$description  (expected HTTP $expected, got HTTP $actual)"
  fi
}

# ── Test Suite ────────────────────────────────────────────────────────────────

printf "\n${BOLD}%s${NC}\n" "════════════════════════════════════════════════"
printf "${BOLD}  Okteto Platform Integration Tests${NC}\n"
printf "  Namespace  :  %s\n" "${OKTETO_NAMESPACE}"
printf "  Release    :  %s\n" "${OKTETO_RELEASE_NAME}"
printf "  Subdomain  :  %s\n" "${OKTETO_SUBDOMAIN}"
printf "${BOLD}%s${NC}\n\n" "════════════════════════════════════════════════"

INSTANCE_SELECTOR="app.kubernetes.io/instance=${OKTETO_RELEASE_NAME}"

# ── 1. Rollout Status ─────────────────────────────────────────────────────────
section "1. Rollout Status"
printf "  Checking all Deployments and StatefulSets have rolled out successfully\n\n"

kubectl_check_rollout deployment "$INSTANCE_SELECTOR"
kubectl_check_rollout statefulset "$INSTANCE_SELECTOR"

section_summary

# ── 2. Pod Readiness ──────────────────────────────────────────────────────────
section "2. Pod Readiness"
printf "  Checking all component pods have running, ready containers\n\n"

pods_ready "${INSTANCE_SELECTOR},app.kubernetes.io/component=api"              "API"
pods_ready "${INSTANCE_SELECTOR},app.kubernetes.io/component=buildkit"         "BuildKit"
pods_ready "${INSTANCE_SELECTOR},app.kubernetes.io/component=frontend"         "Frontend"
pods_ready "${INSTANCE_SELECTOR},app.kubernetes.io/component=mutation-webhook" "Mutation Webhook"
pods_ready "${INSTANCE_SELECTOR},app.kubernetes.io/component=registry"         "Registry"
pods_ready "app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller" "Ingress NGINX"

daemon_pods=$(kubectl get pods -n "$OKTETO_NAMESPACE" \
  -l "${INSTANCE_SELECTOR},app.kubernetes.io/component=daemon" \
  --field-selector='status.phase=Running' \
  -o name 2>/dev/null | wc -l)
if [ "$daemon_pods" -gt 0 ]; then
  pass "Daemon  (running on $daemon_pods node(s))"
else
  fail "Daemon  (no running daemon pods found)"
fi

section_summary

# ── 3. CrashLoop Check ────────────────────────────────────────────────────────
section "3. CrashLoop Check"
printf "  Checking no pods are stuck in CrashLoopBackOff or OOMKilled\n\n"

no_crashlooping "$INSTANCE_SELECTOR" "All Okteto components"

section_summary

# ── 4. HTTP Health Endpoints ──────────────────────────────────────────────────
section "4. HTTP Health Endpoints"
printf "  Checking each component responds on its health endpoint\n\n"

http_check "API  →  GET /healthz  (expect HTTP 200)" \
  "${OKTETO_API_ENDPOINT}/healthz" "200"

registry_code=$(curl -sk -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 --max-time 10 \
  "${OKTETO_REGISTRY_ENDPOINT}/v2/" 2>/dev/null || echo "000")
if [ "$registry_code" = "200" ] || [ "$registry_code" = "401" ]; then
  pass "Registry  →  GET /v2/  (got HTTP $registry_code — registry is up)"
else
  fail "Registry  →  GET /v2/  (expected HTTP 200 or 401, got HTTP $registry_code)"
fi

http_check "Frontend  →  GET /  (expect HTTP 200)" \
  "${OKTETO_FRONTEND_ENDPOINT}/" "200"

section_summary

# ── 5. BuildKit Reachability ──────────────────────────────────────────────────
section "5. BuildKit Reachability"
printf "  Checking the BuildKit service port is open and accepting connections\n\n"

buildkit_svc_ip=$(kubectl get svc "${OKTETO_RELEASE_NAME}-buildkit" \
  -n "$OKTETO_NAMESPACE" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -z "$buildkit_svc_ip" ] || [ "$buildkit_svc_ip" = "None" ]; then
  fail "BuildKit  (service not found or has no ClusterIP)"
else
  buildkit_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 \
    "https://${buildkit_svc_ip}:443" 2>/dev/null || echo "000")
  if [ "$buildkit_code" != "000" ]; then
    pass "BuildKit  →  port 443 reachable  (got HTTP $buildkit_code)"
  else
    fail "BuildKit  →  port 443 not reachable on $buildkit_svc_ip"
  fi
fi

section_summary

# ── 6. Mutation Webhook ───────────────────────────────────────────────────────
section "6. Mutation Webhook"
printf "  Checking the admission webhook is reachable over TLS\n\n"

webhook_code=$(curl -sk -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 --max-time 10 \
  "${OKTETO_WEBHOOK_ENDPOINT}/mutate" 2>/dev/null || echo "000")
if [ "$webhook_code" = "200" ] || [ "$webhook_code" = "400" ] || [ "$webhook_code" = "404" ]; then
  pass "Mutation Webhook  →  TLS reachable  (got HTTP $webhook_code)"
else
  fail "Mutation Webhook  →  not reachable  (expected HTTP 200/400/404, got HTTP $webhook_code)"
fi

section_summary

# ── 7. API Service ClusterIP ──────────────────────────────────────────────────
section "7. API Service ClusterIP"
printf "  Checking the API has a stable ClusterIP for in-cluster routing\n\n"

api_cluster_ip=$(kubectl get svc "${OKTETO_RELEASE_NAME}-api" \
  -n "$OKTETO_NAMESPACE" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "$api_cluster_ip" ] && [ "$api_cluster_ip" != "None" ]; then
  pass "API Service  →  ClusterIP $api_cluster_ip"
else
  fail "API Service  →  missing or headless (no ClusterIP)"
fi

section_summary

# ── 8. Registry Service Endpoints ────────────────────────────────────────────
section "8. Registry Service Endpoints"
printf "  Checking the Registry service has live pod endpoints for image push/pull\n\n"

registry_endpoints=$(kubectl get endpoints "${OKTETO_RELEASE_NAME}-registry" \
  -n "$OKTETO_NAMESPACE" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
if [ -n "$registry_endpoints" ]; then
  pass "Registry Service  →  active endpoints: $registry_endpoints"
else
  fail "Registry Service  →  no active endpoints (image push/pull will fail)"
fi

section_summary

# ── 9. Wildcard DNS ───────────────────────────────────────────────────────────
section "9. Wildcard DNS Resolution"
printf "  Checking the wildcard DNS record resolves for the subdomain\n\n"

test_hostname="healthcheck.${OKTETO_SUBDOMAIN}"
if nslookup "$test_hostname" >/dev/null 2>&1; then
  pass "Wildcard DNS  →  $test_hostname resolves"
else
  skip "Wildcard DNS  →  $test_hostname did not resolve (may be expected in-cluster)"
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
  printf "\n  ${RED}${BOLD}FAILED — the Okteto platform may not be fully operational.${NC}\n\n"
  exit 1
fi

printf "\n  ${GREEN}${BOLD}ALL TESTS PASSED — the Okteto platform is healthy.${NC}\n\n"
exit 0