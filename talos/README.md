# Talos

Machine configs for the three Talos nodes. They're rendered with plain
[`talosctl gen config`](https://www.talos.dev/latest/reference/cli/#talosctl-gen-config)
plus config patches. There's no third-party generator: [talhelper](https://github.com/budimanjojo/talhelper),
which this repo used before, was archived in August 2026.

## Layout

| Path | What it holds |
|---|---|
| `talenv.yaml` | Talos/Kubernetes versions (Renovate-managed), the config contract, cluster name and endpoint, installer image and disk |
| `talsecret.sops.yaml` | Cluster secrets bundle (CAs, tokens) in `talosctl gen secrets` format, encrypted with SOPS |
| `patches/global/` | Patches applied to every node |
| `patches/controller/` | Patches applied to control plane nodes (currently every node) |
| `nodes/<hostname>.yaml` | Per-node documents: hostname, NIC selector, address, route, VIP |
| `clusterconfig/` | **Generated and gitignored.** One machine config per node plus `talosconfig` |

`scripts/talos-genconfig.sh` combines them. For each file in `nodes/` it runs
`talosctl gen config` with the secrets bundle and the settings from `talenv.yaml`,
then applies patches in this order:

1. `patches/global/*.yaml`, in filename order
2. `patches/controller/*.yaml`, in filename order
3. `nodes/<hostname>.yaml`

It then validates the result with `talosctl validate --mode metal`. The decrypted
secrets are only ever written to a temporary mode-600 file, which is deleted when
the script exits.

Patches are [strategic merge patches](https://www.talos.dev/latest/talos-guides/configuration/patching/)
or additional config documents (`kind: ...`). Lists merge by appending, so a patch
can't remove an entry that a default already provides.

## Everyday tasks

All of these take a node's IP. The task finds the matching `nodes/*.yaml` by the
address on its `LinkConfig`.

```sh
task talos:generate-config                            # render clusterconfig/ (also runs before apply-node)
task talos:apply-node IP=10.100.50.29 DRY_RUN=true    # show what would change, apply nothing
task talos:apply-node IP=10.100.50.29                 # apply (MODE=auto by default)
task talos:upgrade-node IP=10.100.50.29               # install talosVersion from talenv.yaml and reboot
task talos:upgrade-k8s                                # roll the cluster to kubernetesVersion
```

`DRY_RUN=true` is the safe first step after editing a patch. It prints a diff of the
running config against the newly rendered one.

## Version contract

`talosContract` in `talenv.yaml` is passed as `--talos-version`. It decides which
defaults and document kinds the generated config uses, and it is **deliberately
separate from `talosVersion`**. A node running a newer Talos still accepts a config
written to an older contract, so the order is:

1. Raise `talosVersion` and roll the nodes with `talos:upgrade-node`.
2. Later, raise `talosContract`, run `generate-config`, and fix any conflicts.
3. Check each node with `apply-node ... DRY_RUN=true`, then apply.

### The v1.14 contract

Since v1.14 nearly all configuration lives in separate documents (`kind: ...`);
the v1alpha1 document keeps only `machine.*` basics (certSANs, disks, sysctls,
time, features) and `cluster.etcd`. Setting a field in v1alpha1 that a document
now owns makes `generate-config` fail with "already set in v1alpha1 config", so
patches must target the document:

| Old v1alpha1 field | Document |
|---|---|
| `machine.network.nameservers`, `disableSearchDomain` | `ResolverConfig` |
| `machine.kubelet` (`extraConfig`, `nodeIP`) | `KubeletConfig` (`config`), `KubeNodeConfig` (`nodeIP`) |
| `machine.files` (CRI part) | `CRICustomizationConfig` |
| `cluster.network` (subnets) / `cni: none` | `KubeNetworkConfig` / delete `KubeFlannelCNIConfig` |
| `cluster.apiServer` | `KubeAPIServerConfig`; OIDC flags → `KubeAuthenticationConfig` |
| `cluster.controllerManager`, `cluster.scheduler` | `KubeControllerManagerConfig`, `KubeSchedulerConfig` |
| `cluster.proxy.disabled`, `cluster.coreDNS.disabled` | `KubeProxyConfig`, `KubeCoreDNSConfig` (`enabled: false`) |
| `cluster.allowSchedulingOnControlPlanes` | delete the control-plane taint in `KubeNodeConfig` |

Delete a whole generated document with `$patch: delete` next to its
`apiVersion`/`kind`, or a single map key with `<key>: {$patch: delete}`.

`patches/global/security.yaml` pins two defaults that the 1.14 contract turns on,
`SecurityProfileConfig.workloadIsolation` and EPHEMERAL `mount.secure` (nosuid,nodev
on `/var`), to off. Isolation breaks Longhorn's access to the host's iscsid, and
nodev on `/var` breaks block-mode CSI volumes. Test either one on a single node
before enabling it.

## Adding a node

1. Copy one of `nodes/*.yaml` to `nodes/<hostname>.yaml` and change the hostname,
   MAC address and IP.
2. Run `task talos:generate-config` and check `clusterconfig/kubernetes-<hostname>.yaml`.
3. Boot the node into maintenance mode, then run
   `talosctl apply-config --insecure --nodes <ip> --file talos/clusterconfig/kubernetes-<hostname>.yaml`.

Every node is generated as a control plane node. Adding a worker would need
`--output-types worker` and a `patches/worker/` directory in `talos-genconfig.sh`.
