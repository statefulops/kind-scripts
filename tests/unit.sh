#!/usr/bin/env bash
# Fast tests for the create-cluster scripts. No cluster or Docker needed:
# kind, helm, kubectl, aws and openssl are replaced by stub commands that log
# how they were called.
#
# Usage: tests/unit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS=(3node nfs s3 s3-with-ssl)
ALL_TOOLS=(kind helm kubectl aws openssl)

required_tools() {
  case "$1" in
    3node) echo "kind" ;;
    nfs) echo "kind helm" ;;
    s3 | s3-with-ssl) echo "kind helm kubectl aws openssl" ;;
    *) echo "unknown script $1" >&2; exit 2 ;;
  esac
}

# Commands the script should run against the stubs, one per line.
expected_calls() {
  case "$1" in
    3node) ;;
    nfs)
      echo "helm install my-release nfs-ganesha-server-and-external-provisioner/nfs-server-provisioner"
      ;;
    s3)
      echo "helm install rustfs rustfs/rustfs"
      echo "kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=rustfs"
      echo "aws --endpoint-url http://localhost:9000 s3 mb s3://my-kind-bucket"
      ;;
    s3-with-ssl)
      echo "helm install rustfs rustfs/rustfs"
      echo "kubectl patch deploy rustfs -n rustfs"
      echo "kubectl rollout status deploy/rustfs -n rustfs"
      echo "aws --no-verify-ssl --endpoint-url https://localhost:9000 s3 mb s3://my-kind-bucket"
      ;;
  esac
}

PASSED=0
FAILED=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL $1" >&2; if [ -n "${2:-}" ]; then sed 's/^/       /' <<<"$2" >&2; fi; }

# Build a bin dir holding only the basic utilities the scripts need, plus a
# stub for each tool named in the arguments.
make_sandbox() {
  local dir="$1"; shift
  rm -rf "$dir"
  mkdir -p "$dir"
  local util
  for util in cat mktemp rm; do
    ln -s "$(command -v "$util")" "$dir/$util"
  done
  local tool
  for tool in "$@"; do
    make_stub "$dir/$tool" "$tool"
  done
}

make_stub() {
  local path="$1" name="$2"
  cat > "$path" <<EOF
#!/bin/bash
echo "$name \$*" >> "\$CALL_LOG"
EOF
  case "$name" in
    kind)
      # Save the generated config so the test can inspect it.
      cat >> "$path" <<'EOF'
prev=""
for arg in "$@"; do
  if [ "$prev" = "--config" ]; then
    echo "$arg" > "$CALL_LOG.config-path"
    cat "$arg" > "$CALL_LOG.config"
  fi
  prev="$arg"
done
EOF
      ;;
    kubectl)
      cat >> "$path" <<'EOF'
case "$*" in
  "config current-context") echo "kind-test" ;;
  "get svc"*) echo "10.96.0.10" ;;
  *"apply -f -"*) cat > /dev/null ;;
esac
EOF
      ;;
    openssl)
      cat >> "$path" <<'EOF'
if [ "${1:-}" = "rand" ]; then echo "stub-password"; fi
EOF
      ;;
  esac
  chmod +x "$path"
}

# Run a script with PATH limited to the sandbox. Sets OUT and STATUS.
run_script() {
  local name="$1" sandbox="$2"; shift 2
  CALL_LOG="$WORK/$name.calls"
  rm -f "$CALL_LOG" "$CALL_LOG.config" "$CALL_LOG.config-path"
  touch "$CALL_LOG"
  set +e
  OUT="$(cd "$WORK" && CALL_LOG="$CALL_LOG" PATH="$sandbox" "$BASH" "$ROOT/$name/create-cluster.sh" "$@" 2>&1)"
  STATUS=$?
  set -e
}

for name in "${SCRIPTS[@]}"; do
  echo "$name"
  script="$ROOT/$name/create-cluster.sh"
  read -r -a required <<<"$(required_tools "$name")"
  default_version="$(sed -n 's/^DEFAULT_K8S_VERSION="\(.*\)"$/\1/p' "$script")"

  if "$BASH" -n "$script"; then
    pass "syntax is valid"
  else
    fail "syntax is valid"
  fi

  # --help prints usage and creates nothing.
  make_sandbox "$WORK/bin" "${ALL_TOOLS[@]}"
  run_script "$name" "$WORK/bin" --help
  if [ "$STATUS" -eq 1 ] && grep -q "^Usage:" <<<"$OUT" && [ ! -s "$CALL_LOG" ]; then
    pass "--help prints usage without running any tools"
  else
    fail "--help prints usage without running any tools" "exit=$STATUS"$'\n'"$OUT"
  fi

  # No tools installed: every required tool is reported, nothing runs.
  make_sandbox "$WORK/bin"
  run_script "$name" "$WORK/bin"
  expected="not installed or not on PATH: ${required[*]}"
  if [ "$STATUS" -eq 1 ] && grep -qF "$expected" <<<"$OUT"; then
    pass "reports all missing tools: ${required[*]}"
  else
    fail "reports all missing tools: ${required[*]}" "exit=$STATUS"$'\n'"$OUT"
  fi

  # One tool missing at a time: only that tool is reported.
  for missing in "${required[@]}"; do
    present=()
    for tool in "${ALL_TOOLS[@]}"; do
      if [ "$tool" != "$missing" ]; then present+=("$tool"); fi
    done
    make_sandbox "$WORK/bin" "${present[@]}"
    run_script "$name" "$WORK/bin"
    if [ "$STATUS" -eq 1 ] && grep -qF "not installed or not on PATH: $missing"$'\n' <<<"$OUT"$'\n' && [ ! -s "$CALL_LOG" ]; then
      pass "exits before doing anything when only $missing is missing"
    else
      fail "exits before doing anything when only $missing is missing" "exit=$STATUS"$'\n'"$OUT"
    fi
  done

  # All tools present, default arguments: runs to completion.
  make_sandbox "$WORK/bin" "${ALL_TOOLS[@]}"
  run_script "$name" "$WORK/bin"
  calls="$(cat "$CALL_LOG")"
  if [ "$STATUS" -eq 0 ]; then
    pass "runs to completion with all tools present"
  else
    fail "runs to completion with all tools present" "exit=$STATUS"$'\n'"$OUT"
  fi

  if grep -qE "^kind create cluster --config [^ ]+ --image kindest/node:${default_version}\$" <<<"$calls"; then
    pass "creates cluster with default image kindest/node:${default_version}"
  else
    fail "creates cluster with default image kindest/node:${default_version}" "$calls"
  fi

  config="$(cat "$CALL_LOG.config" 2>/dev/null || true)"
  zones_ok=1
  for zone in AZ-A AZ-B AZ-C; do
    grep -qF "topology.kubernetes.io/zone=${zone}" <<<"$config" || zones_ok=0
  done
  if [ "$(grep -c '^- role: control-plane' <<<"$config")" -eq 1 ] &&
     [ "$(grep -c '^- role: worker' <<<"$config")" -eq 3 ] &&
     [ "$zones_ok" -eq 1 ]; then
    pass "config has 1 control plane and 3 workers labelled AZ-A/B/C"
  else
    fail "config has 1 control plane and 3 workers labelled AZ-A/B/C" "$config"
  fi

  config_path="$(cat "$CALL_LOG.config-path" 2>/dev/null || true)"
  if [ -n "$config_path" ] && [ ! -e "$config_path" ]; then
    pass "removes the temporary config file"
  else
    fail "removes the temporary config file" "path: ${config_path:-<none>}"
  fi

  missing_calls=""
  while IFS= read -r call; do
    [ -z "$call" ] && continue
    grep -qF "$call" <<<"$calls" || missing_calls+="$call"$'\n'
  done <<<"$(expected_calls "$name")"
  if [ -z "$missing_calls" ]; then
    pass "runs the expected setup commands"
  else
    fail "runs the expected setup commands" "missing:"$'\n'"$missing_calls"$'\n'"got:"$'\n'"$calls"
  fi

  # Version and cluster name arguments are passed through to kind.
  run_script "$name" "$WORK/bin" v1.30.0 my-cluster
  if [ "$STATUS" -eq 0 ] &&
     grep -qE "^kind create cluster --config [^ ]+ --image kindest/node:v1.30.0 --name my-cluster\$" "$CALL_LOG"; then
    pass "passes version and cluster name arguments to kind"
  else
    fail "passes version and cluster name arguments to kind" "exit=$STATUS"$'\n'"$(cat "$CALL_LOG")"
  fi
done

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
