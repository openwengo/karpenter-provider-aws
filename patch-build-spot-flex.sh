#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[patch-build-spot-flex] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Patch and build a Karpenter provider image with configurable spot-to-spot flexibility.

Usage:
  hack/patch-build-spot-flex.sh --tag <provider-tag> [options]

Required:
  --tag <tag>                         Provider tag to checkout (example: v1.8.6)

Options:
  --upstream-dir <dir>                Upstream core checkout dir (default: upstream/karpenter-core)
  --image <image:tag>                 Output docker image tag (default: karpenter-provider-aws:<tag>-patched)
  --skip-build                        Apply patches but skip docker build
  --force                             Allow dirty worktree and force checkout of tag
  --no-fetch                          Do not fetch tags/remotes before checkout
  -h, --help                          Show this help

What it does:
  1) Checks out the provider tag.
  2) Checks out matching upstream core based on go.mod (tag or pseudo-version commit).
  3) Applies core + provider patches for configurable spot-to-spot flexibility.
  4) Builds image with patching/Dockerfile.patched-controller (unless --skip-build).
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found"
}

insert_after_first_match() {
  local file="$1"
  local token="$2"
  local insert_text="$3"
  local tmp="${file}.tmp"

  awk -v tok="$token" -v ins="$insert_text" '
    { print }
    index($0, tok) > 0 && !done {
      print ins
      done = 1
    }
    END {
      if (!done) {
        exit 19
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "failed to insert into ${file}; token not found: ${token}"
  }
  mv "$tmp" "$file"
}

insert_before_first_match() {
  local file="$1"
  local token="$2"
  local insert_text="$3"
  local tmp="${file}.tmp"

  awk -v tok="$token" -v ins="$insert_text" '
    index($0, tok) > 0 && !done {
      print ins
      done = 1
    }
    { print }
    END {
      if (!done) {
        exit 19
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "failed to insert into ${file}; token not found: ${token}"
  }
  mv "$tmp" "$file"
}

patch_core_options() {
  local core_dir="$1"
  local f="${core_dir}/pkg/operator/options/options.go"
  [[ -f "$f" ]] || die "missing core file ${f}"

  if ! grep -q 'DefaultMinSpotToSpotConsolidationInstanceTypeFlexibility' "$f"; then
    insert_after_first_match "$f" 'MinValuesPolicyBestEffort MinValuesPolicy = "BestEffort"' $'\t// DefaultMinSpotToSpotConsolidationInstanceTypeFlexibility is the default minimum number of cheaper spot instance\n\t// type options required to perform single-node spot-to-spot consolidation.\n\tDefaultMinSpotToSpotConsolidationInstanceTypeFlexibility = 15'
  fi

  if ! grep -q 'MinSpotToSpotConsolidationInstanceTypeFlexibility int' "$f"; then
    insert_before_first_match "$f" 'IgnoreDRARequests' $'\tMinSpotToSpotConsolidationInstanceTypeFlexibility int'
  fi

  if ! grep -q 'min-spot-to-spot-consolidation-instance-type-flexibility' "$f"; then
    insert_before_first_match "$f" 'ignore-dra-requests' $'\tfs.IntVar(&o.MinSpotToSpotConsolidationInstanceTypeFlexibility, "min-spot-to-spot-consolidation-instance-type-flexibility", env.WithDefaultInt("MIN_SPOT_TO_SPOT_CONSOLIDATION_INSTANCE_TYPE_FLEXIBILITY", DefaultMinSpotToSpotConsolidationInstanceTypeFlexibility), "Minimum number of cheaper spot instance type options required to perform single-node spot-to-spot consolidation.")'
  fi

  if ! grep -q 'invalid MIN_SPOT_TO_SPOT_CONSOLIDATION_INSTANCE_TYPE_FLEXIBILITY' "$f"; then
    insert_before_first_match "$f" 'if o.CPURequests <= 0 {' $'\tif o.MinSpotToSpotConsolidationInstanceTypeFlexibility < 1 {\n\t\treturn fmt.Errorf("validating cli flags / env vars, invalid MIN_SPOT_TO_SPOT_CONSOLIDATION_INSTANCE_TYPE_FLEXIBILITY %d, must be greater than 0", o.MinSpotToSpotConsolidationInstanceTypeFlexibility)\n\t}'
  fi
}

patch_core_consolidation() {
  local core_dir="$1"
  local f="${core_dir}/pkg/controllers/disruption/consolidation.go"
  [[ -f "$f" ]] || die "missing core file ${f}"

  sed -i 's|const MinInstanceTypesForSpotToSpotConsolidation = 15|const MinInstanceTypesForSpotToSpotConsolidation = options.DefaultMinSpotToSpotConsolidationInstanceTypeFlexibility|' "$f"

  if ! grep -q 'minSpotToSpotConsolidationInstanceTypeFlexibility := options.FromContext(ctx).MinSpotToSpotConsolidationInstanceTypeFlexibility' "$f"; then
    insert_before_first_match "$f" '// Spot consolidation is turned off.' $'\tminSpotToSpotConsolidationInstanceTypeFlexibility := options.FromContext(ctx).MinSpotToSpotConsolidationInstanceTypeFlexibility\n\tif minSpotToSpotConsolidationInstanceTypeFlexibility < 1 {\n\t\tminSpotToSpotConsolidationInstanceTypeFlexibility = MinInstanceTypesForSpotToSpotConsolidation\n\t}\n'
  fi

  sed -i 's|< MinInstanceTypesForSpotToSpotConsolidation|< minSpotToSpotConsolidationInstanceTypeFlexibility|g' "$f"
  sed -i 's|MinInstanceTypesForSpotToSpotConsolidation, len(results.NewNodeClaims\[0\].InstanceTypeOptions)))...)|minSpotToSpotConsolidationInstanceTypeFlexibility, len(results.NewNodeClaims[0].InstanceTypeOptions)))...)|g' "$f"
  sed -i 's|{MinInstanceTypesForSpotToSpotConsolidation, minInstanceTypes}|{minSpotToSpotConsolidationInstanceTypeFlexibility, minInstanceTypes}|g' "$f"
  sed -i 's|, 0, MinInstanceTypesForSpotToSpotConsolidation)|, 0, minSpotToSpotConsolidationInstanceTypeFlexibility)|g' "$f"
}

patch_provider_go_mod() {
  local root="$1"
  local f="${root}/go.mod"
  [[ -f "$f" ]] || die "missing provider file ${f}"

  if grep -q '^replace sigs.k8s.io/karpenter => ' "$f"; then
    sed -i -E 's|^replace sigs.k8s.io/karpenter => .*|replace sigs.k8s.io/karpenter => ./upstream/karpenter-core|' "$f"
  else
    insert_after_first_match "$f" 'go ' $'\nreplace sigs.k8s.io/karpenter => ./upstream/karpenter-core'
  fi
}

patch_chart_values() {
  local root="$1"
  local f="${root}/charts/karpenter/values.yaml"
  [[ -f "$f" ]] || die "missing chart values file ${f}"

  if ! grep -q 'minSpotToSpotConsolidationInstanceTypeFlexibility:' "$f"; then
    insert_after_first_match "$f" 'minValuesPolicy:' $'  # -- Minimum number of cheaper spot instance type options required to perform single-node spot-to-spot consolidation.\n  minSpotToSpotConsolidationInstanceTypeFlexibility: 15'
  fi
}

patch_chart_deployment() {
  local root="$1"
  local f="${root}/charts/karpenter/templates/deployment.yaml"
  [[ -f "$f" ]] || die "missing chart template file ${f}"

  if ! grep -q 'MIN_SPOT_TO_SPOT_CONSOLIDATION_INSTANCE_TYPE_FLEXIBILITY' "$f"; then
    insert_before_first_match "$f" 'settings.clusterCABundle' $'          {{- with .Values.settings.minSpotToSpotConsolidationInstanceTypeFlexibility }}\n            - name: MIN_SPOT_TO_SPOT_CONSOLIDATION_INSTANCE_TYPE_FLEXIBILITY\n              value: "{{ tpl (toString .) $ }}"\n          {{- end }}'
  fi
}

patch_chart_readme() {
  local root="$1"
  local f="${root}/charts/karpenter/README.md"
  [[ -f "$f" ]] || return 0

  if ! grep -q 'settings.minSpotToSpotConsolidationInstanceTypeFlexibility' "$f"; then
    if grep -q 'settings.minValuesPolicy' "$f"; then
      insert_after_first_match "$f" 'settings.minValuesPolicy' '| settings.minSpotToSpotConsolidationInstanceTypeFlexibility | int | `15` | Minimum number of cheaper spot instance type options required to perform single-node spot-to-spot consolidation. |'
    else
      log "Skipping charts/karpenter/README.md patch; expected table row not found"
    fi
  fi
}

extract_core_version_from_provider_go_mod() {
  local root="$1"
  local core_version
  core_version="$(awk '$1 == "sigs.k8s.io/karpenter" { print $2; exit }' "${root}/go.mod")"
  [[ -n "${core_version}" ]] || die "unable to determine sigs.k8s.io/karpenter version from go.mod"
  printf '%s\n' "$core_version"
}

resolve_core_ref() {
  local core_version="$1"
  if [[ "$core_version" =~ -([0-9a-f]{12,})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$core_version"
  fi
}

TAG=""
UPSTREAM_DIR="upstream/karpenter-core"
IMAGE=""
SKIP_BUILD=false
FORCE=false
NO_FETCH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --upstream-dir)
      UPSTREAM_DIR="${2:-}"
      shift 2
      ;;
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --no-fetch)
      NO_FETCH=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$TAG" ]] || {
  usage
  die "--tag is required"
}

require_tool git
require_tool awk
require_tool sed

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ "$FORCE" == "false" ]] && [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty; use --force if you want to discard changes while checking out ${TAG}"
fi

if [[ "$NO_FETCH" == "false" ]]; then
  log "Fetching provider tags"
  git fetch --tags --force
fi

if [[ "$FORCE" == "true" ]]; then
  git checkout -f "$TAG"
else
  git checkout "$TAG"
fi
log "Checked out provider tag ${TAG}"

mkdir -p "$(dirname "$UPSTREAM_DIR")"
if [[ ! -d "${UPSTREAM_DIR}/.git" ]]; then
  log "Cloning upstream core into ${UPSTREAM_DIR}"
  git clone https://github.com/kubernetes-sigs/karpenter "$UPSTREAM_DIR"
fi

if [[ "$NO_FETCH" == "false" ]]; then
  log "Fetching upstream core refs"
  git -C "$UPSTREAM_DIR" fetch --tags --force origin
fi

CORE_VERSION="$(extract_core_version_from_provider_go_mod "$ROOT")"
CORE_REF="$(resolve_core_ref "$CORE_VERSION")"
log "Provider requires core version ${CORE_VERSION}; checking out upstream ref ${CORE_REF}"
git -C "$UPSTREAM_DIR" checkout -f "$CORE_REF"

log "Applying core patch"
patch_core_options "$UPSTREAM_DIR"
patch_core_consolidation "$UPSTREAM_DIR"

if command -v gofmt >/dev/null 2>&1; then
  gofmt -w \
    "${UPSTREAM_DIR}/pkg/operator/options/options.go" \
    "${UPSTREAM_DIR}/pkg/controllers/disruption/consolidation.go"
fi

log "Applying provider patches"
patch_provider_go_mod "$ROOT"
patch_chart_values "$ROOT"
patch_chart_deployment "$ROOT"
patch_chart_readme "$ROOT"

if [[ "$SKIP_BUILD" == "true" ]]; then
  log "Patches applied. Build skipped (--skip-build)."
  exit 0
fi

require_tool docker

GO_DIRECTIVE="$(awk '/^go / { print $2; exit }' go.mod)"
if [[ "$GO_DIRECTIVE" =~ ^([0-9]+\.[0-9]+) ]]; then
  GO_MAJOR_MINOR="${BASH_REMATCH[1]}"
else
  GO_MAJOR_MINOR="$GO_DIRECTIVE"
fi

if [[ -z "$IMAGE" ]]; then
  IMAGE="karpenter-provider-aws:${TAG}-patched"
fi

VERSION_NO_V="${TAG#v}"
LDFLAGS="-X=sigs.k8s.io/karpenter/pkg/operator.Version=${VERSION_NO_V}"

log "Building docker image ${IMAGE}"
docker build \
  -f ../karpenter-patching/Dockerfile.patched-controller \
  --build-arg GO_VERSION="${GO_MAJOR_MINOR}" \
  --build-arg LDFLAGS="${LDFLAGS}" \
  -t "${IMAGE}" \
  .

log "Done. Built image ${IMAGE}"
