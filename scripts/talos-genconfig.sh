#!/usr/bin/env bash
# Render Talos machine configs and a talosconfig with plain `talosctl gen config`.
#
# Inputs (all under talos/):
#   talenv.yaml          versions, contract, cluster name/endpoint, installer
#   talsecret.sops.yaml  SOPS-encrypted secrets bundle (`talosctl gen secrets` format)
#   patches/global/      patches applied to every node, in filename order
#   patches/controller/  patches applied to control plane nodes, in filename order
#   nodes/<host>.yaml    per-node patch (hostname, NIC, address, VIP), applied last
#
# Outputs (gitignored, under talos/clusterconfig/):
#   <clusterName>-<host>.yaml  one machine config per node
#   talosconfig                client config with every node as endpoint and node
#
# The decrypted secrets bundle only ever exists in a mode-600 temp file that is
# removed on exit.
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export ROOT_DIR="${ROOT_DIR:-$(git rev-parse --show-toplevel)}"
TALOS_DIR="${TALOS_DIR:-${ROOT_DIR}/talos}"
OUT_DIR="${OUT_DIR:-${TALOS_DIR}/clusterconfig}"

check_cli sops talosctl yq

env_file="${TALOS_DIR}/talenv.yaml"
secrets_file="${TALOS_DIR}/talsecret.sops.yaml"
[[ -f "${env_file}" ]] || log error "Missing env file" "file=${env_file}"
[[ -f "${secrets_file}" ]] || log error "Missing secrets bundle" "file=${secrets_file}"

talenv() {
    local value
    value="$(yq -r ".${1}" "${env_file}")"
    [[ -n "${value}" && "${value}" != "null" ]] || log error "Missing key in talenv.yaml" "key=${1}"
    printf '%s' "${value}"
}

cluster_name="$(talenv clusterName)"
cluster_endpoint="$(talenv clusterEndpoint)"
talos_version="$(talenv talosVersion)"
talos_contract="$(talenv talosContract)"
kubernetes_version="$(talenv kubernetesVersion)"
install_image="$(talenv installerImage):${talos_version}"
install_disk="$(talenv installDisk)"

shopt -s nullglob
node_files=("${TALOS_DIR}"/nodes/*.yaml)
global_patches=("${TALOS_DIR}"/patches/global/*.yaml)
controller_patches=("${TALOS_DIR}"/patches/controller/*.yaml)
shopt -u nullglob
(( ${#node_files[@]} > 0 )) || log error "No node files found" "dir=${TALOS_DIR}/nodes"

# Primary address of a node file: the first address on its LinkConfig.
node_ip() {
    yq -N -r 'select(.kind == "LinkConfig") | .addresses[0].address' "${1}" | head -n1 | cut -d/ -f1
}

secrets="$(mktemp)"
trap 'rm -f "${secrets}"' EXIT
chmod 600 "${secrets}"
sops --decrypt "${secrets_file}" > "${secrets}"

mkdir -p "${OUT_DIR}"

common_args=(
    "${cluster_name}" "${cluster_endpoint}"
    --with-secrets "${secrets}"
    --talos-version "${talos_contract}"
    --kubernetes-version "${kubernetes_version}"
    --install-image "${install_image}"
    --install-disk "${install_disk}"
    --with-docs=false
    --with-examples=false
    --force
)

patch_args=()
for patch in "${global_patches[@]}"; do
    patch_args+=(--config-patch "@${patch}")
done
for patch in "${controller_patches[@]}"; do
    patch_args+=(--config-patch-control-plane "@${patch}")
done

log info "Generating Talos config" "talos=${talos_version}" "contract=${talos_contract}" \
    "kubernetes=${kubernetes_version}" "nodes=${#node_files[@]}"

# Run talosctl quietly; it prints "generating PKI and tokens" even when reusing
# --with-secrets, which reads as alarming. Show its output only on failure.
quiet() {
    local output
    if ! output="$("$@" 2>&1)"; then
        printf "%s\n" "${output}" >&2
        log error "Command failed" "cmd=${1} ${2:-}"
    fi
}

node_ips=()
for node_file in "${node_files[@]}"; do
    host="$(basename "${node_file}" .yaml)"
    ip="$(node_ip "${node_file}")"
    [[ -n "${ip}" ]] || log error "No LinkConfig address in node file" "file=${node_file}"
    node_ips+=("${ip}")

    out="${OUT_DIR}/${cluster_name}-${host}.yaml"
    quiet talosctl gen config "${common_args[@]}" "${patch_args[@]}" \
        --config-patch "@${node_file}" \
        --output-types controlplane \
        --output "${out}"
    chmod 600 "${out}"

    quiet talosctl validate --mode metal --config "${out}"
    log info "Rendered node config" "node=${host}" "ip=${ip}" "file=${out#"${ROOT_DIR}/"}"
done

talosconfig="${OUT_DIR}/talosconfig"
quiet talosctl gen config "${common_args[@]}" --output-types talosconfig --output "${talosconfig}"
quiet talosctl --talosconfig "${talosconfig}" config endpoint "${node_ips[@]}"
quiet talosctl --talosconfig "${talosconfig}" config node "${node_ips[@]}"
chmod 600 "${talosconfig}"
log info "Rendered talosconfig" "file=${talosconfig#"${ROOT_DIR}/"}" "endpoints=${node_ips[*]}"
