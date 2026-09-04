#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Charts whose CRDs are installed out-of-band, as "<namespace>/<name>" pairs.
# The chart reference and version are read from the Flux OCIRepository at
# kubernetes/apps/<namespace>/<name>/app/ocirepository.yaml, so Renovate keeps
# these in step with the running release and there is no second version to bump.
#
# Installing CRDs out-of-band keeps them present before Flux reconciles the
# workloads that reference them, and lets a CRD bump be applied without waiting
# for a Helm upgrade.
readonly CHART_CRDS=(
    "network/envoy-gateway"
)

# Render a chart's CRDs and apply them.
#
# Only `kind: CustomResourceDefinition` is applied. Upstream bundles ship other
# cluster-scoped objects alongside the CRDs -- the gateway-api bundle in the
# envoy-gateway chart also carries the
# safe-upgrades.gateway.networking.k8s.io ValidatingAdmissionPolicy and its
# binding, which rejects experimental-channel CRDs landing on standard-channel
# ones and would freeze every later CRD update. Those objects are deliberately
# not installed here.
#
# Server-side apply is used rather than Helm's CRD replace policy: replace is a
# delete followed by a create, which drops and recreates objects that reference
# each other and races their validation. Apply patches in place instead.
function apply_chart_crds() {
    log debug "Applying chart CRDs"

    for entry in "${CHART_CRDS[@]}"; do
        local namespace="${entry%%/*}"
        local name="${entry##*/}"
        local ocirepository="${ROOT_DIR}/kubernetes/apps/${namespace}/${name}/app/ocirepository.yaml"

        if [[ ! -f "${ocirepository}" ]]; then
            log error "File does not exist" "file=${ocirepository}"
        fi

        local chart version
        chart="$(yq -e '.spec.url' "${ocirepository}")"
        version="$(yq -e '.spec.ref.tag' "${ocirepository}")"

        if [[ -z "${chart}" || -z "${version}" ]]; then
            log error "Could not resolve chart reference" "release=${entry}"
        fi

        # shellcheck disable=SC2086
        if helm template "${name}" "${chart}" --version "${version}" \
                --namespace "${namespace}" --include-crds --no-hooks 2>/dev/null \
            | yq ea -e 'select(.kind == "CustomResourceDefinition")' \
            | kubectl apply --server-side --force-conflicts --filename - &>/dev/null;
        then
            log info "Chart CRDs applied" "release=${entry}" "version=${version}"
        else
            log error "Failed to apply chart CRDs" "release=${entry}" "version=${version}"
        fi
    done
}

function main() {
    check_cli helm kubectl yq

    apply_chart_crds

    log info "Chart CRDs are up-to-date"
}

main "$@"
