#!/usr/bin/env bash
# check-intel-gpu.sh — Verify Intel GPU visibility inside the OpenClaw container.
#
# Run this script inside a container launched with the intel-gpu Compose profile:
#
#   docker compose --profile intel-gpu exec openclaw-gateway-intel-gpu \
#     bash scripts/check-intel-gpu.sh
#
# Or from the host into a running container:
#
#   docker exec <container-name> bash /app/scripts/check-intel-gpu.sh
#
# Exit codes:
#   0 — GPU detected and all checks passed
#   1 — One or more checks failed; see output for details

set -euo pipefail

PASS=0
FAIL=0

_pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
_fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
_info() { echo "  [INFO] $*"; }

echo "==> OpenClaw Intel GPU check"
echo

# ── 1. /dev/dri directory ────────────────────────────────────────
echo "--- /dev/dri device nodes ---"
if [ -d /dev/dri ]; then
  _pass "/dev/dri directory exists"
  render_nodes="$(ls /dev/dri/renderD* 2>/dev/null || true)"
  card_nodes="$(ls /dev/dri/card* 2>/dev/null || true)"
  if [ -n "$render_nodes" ]; then
    for node in $render_nodes; do
      if [ -r "$node" ]; then
        _pass "$node is readable"
      else
        _fail "$node exists but is NOT readable — check group_add and RENDER_GID in .env"
      fi
    done
  else
    _fail "No /dev/dri/renderD* nodes found — GPU not passed through or /dev/dri not mounted"
  fi
  if [ -n "$card_nodes" ]; then
    for node in $card_nodes; do
      _info "$node present"
    done
  fi
else
  _fail "/dev/dri directory does not exist — mount /dev/dri or use the intel-gpu Compose profile"
fi
echo

# ── 2. OPENCLAW_GPU_BACKEND env var ──────────────────────────────
echo "--- OPENCLAW_GPU_BACKEND ---"
gpu_backend="${OPENCLAW_GPU_BACKEND:-}"
if [ -n "$gpu_backend" ]; then
  _pass "OPENCLAW_GPU_BACKEND=${gpu_backend}"
else
  _info "OPENCLAW_GPU_BACKEND is not set (optional; set to 'intel' to enable)"
fi
echo

# ── 3. vainfo (VA-API driver) ────────────────────────────────────
echo "--- VA-API (vainfo) ---"
if command -v vainfo >/dev/null 2>&1; then
  if vainfo 2>&1 | grep -qi "VA-API version"; then
    _pass "vainfo reports a working VA-API driver"
    vainfo 2>&1 | head -10 | sed 's/^/    /'
  else
    vainfo_out="$(vainfo 2>&1 || true)"
    _fail "vainfo ran but reported no driver — output: $vainfo_out"
  fi
else
  _info "vainfo not installed (build with --build-arg OPENCLAW_INSTALL_INTEL_GPU=1 to include it)"
fi
echo

# ── 4. clinfo (OpenCL) ───────────────────────────────────────────
echo "--- OpenCL (clinfo) ---"
if command -v clinfo >/dev/null 2>&1; then
  platform_count="$(clinfo --list 2>/dev/null | grep -c 'Platform' || true)"
  if [ "${platform_count:-0}" -gt 0 ]; then
    _pass "clinfo reports ${platform_count} OpenCL platform(s)"
    clinfo --list 2>/dev/null | head -20 | sed 's/^/    /'
  else
    _fail "clinfo found no OpenCL platforms — Intel OpenCL ICD may be missing or /dev/dri not readable"
  fi
else
  _info "clinfo not installed (build with --build-arg OPENCLAW_INSTALL_INTEL_GPU=1 to include it)"
fi
echo

# ── 5. Summary ───────────────────────────────────────────────────
echo "==> Result: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Troubleshooting:"
  echo "  • Build the image with Intel GPU support:"
  echo "      docker build --build-arg OPENCLAW_INSTALL_INTEL_GPU=1 -t openclaw:intel-gpu ."
  echo "  • Launch with the intel-gpu Compose profile:"
  echo "      docker compose --profile intel-gpu up openclaw-gateway-intel-gpu"
  echo "  • Check host group IDs and update RENDER_GID / VIDEO_GID in .env:"
  echo "      stat -c '%g' /dev/dri/renderD128   # RENDER_GID"
  echo "      stat -c '%g' /dev/dri/card0         # VIDEO_GID"
  echo "  • See docs/platforms/wsl-intel-arc.md for the full setup guide."
  exit 1
fi
