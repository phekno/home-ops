# 🏠 Home Operations

My home Kubernetes cluster running on Talos Linux, managed declaratively with Flux GitOps. This cluster powers my home lab infrastructure, including media streaming, home automation, databases, monitoring, and more.

## 📊 Cluster Overview

- **Cluster Name**: kubernetes
- **Domain**: phekno.io
- **Nodes**: 3x control plane nodes (all capable of running workloads)
- **Kubernetes Version**: Managed via Talos
- **CNI**: Cilium with eBPF datapath
- **Gateway**: Envoy Gateway with Gateway API
- **GitOps**: Flux CD
- **Secrets**: External Secrets Operator + 1Password

### Node Configuration

| Node   | IP           | Role           | MAC Address       |
|--------|--------------|----------------|-------------------|
| k8s-0  | 10.100.50.29 | Control Plane  | bc:24:11:7b:d7:ad |
| k8s-1  | 10.100.50.36 | Control Plane  | bc:24:11:0e:29:e6 |
| k8s-2  | 10.100.50.49 | Control Plane  | bc:24:11:cd:94:29 |

**Virtual IP**: 10.100.50.150 (HA control plane)

### Network Architecture

```
                    Internet
                        │
                        │ Cloudflare Tunnel
                        │ (flux-webhook.phekno.io)
                        ▼
            ┌───────────────────────┐
            │   Cloudflare DNS      │
            │   (*.phekno.io)       │
            └───────────────────────┘
                        │
            ┌───────────┴───────────┐
            │                       │
    ┌───────▼──────┐        ┌──────▼──────┐
    │ envoy-external│        │envoy-internal│
    │ 10.100.50.151 │        │10.100.50.152 │
    │  (Public)     │        │  (Internal)  │
    └───────┬───────┘        └──────┬───────┘
            │                       │
            │   Gateway API         │
            │   (HTTPRoute)         │
            │                       │
    ┌───────▼───────────────────────▼────────┐
    │     Kubernetes Services               │
    │  (Plex, Jellyfin, Home Assistant,    │
    │   Grafana, Longhorn, etc.)           │
    └──────────────────────────────────────┘
```

**Key IPs:**
- Kubernetes API (VIP): `10.100.50.150`
- External Gateway: `10.100.50.151` (public services)
- Internal Gateway: `10.100.50.152` (internal services)
- Node Network: `10.100.50.0/24`
- Pod CIDR: `10.42.0.0/16`
- Service CIDR: `10.43.0.0/16`

## ✨ Features & Components

### Core Infrastructure

- **[Talos Linux](https://github.com/siderolabs/talos)**: Immutable, API-driven Kubernetes OS
- **[Flux CD](https://github.com/fluxcd/flux2)**: GitOps continuous delivery
- **[Cilium](https://github.com/cilium/cilium)**: Advanced eBPF-based CNI with BGP control plane
- **[Envoy Gateway](https://gateway.envoyproxy.io/)**: Modern Gateway API implementation (replaces ingress-nginx)
- **[Cert-Manager](https://github.com/cert-manager/cert-manager)**: Automated TLS certificate management
- **[Spegel](https://github.com/spegel-org/spegel)**: Distributed container image registry
- **[Reloader](https://github.com/stakater/Reloader)**: Automatic restart on ConfigMap/Secret changes

### Storage Solutions

- **[Longhorn](https://github.com/longhorn/longhorn)**: Distributed block storage with S3 backups
  - 3x replica count
  - Backup to Cloudflare R2
  - Storage class: `longhorn` (default)

### Databases & Caching

- **[CloudNativePG](https://cloudnative-pg.io/)**: High-availability PostgreSQL operator
  - 3-instance HA cluster
  - Automated backups to Cloudflare R2
  - PgAdmin management UI
- **[Dragonfly](https://www.dragonflydb.io/)**: Redis-compatible in-memory datastore
  - 3 replicas in cluster mode
  - High-performance caching layer

### Networking & External Access

- **[Envoy Gateway](https://gateway.envoyproxy.io/)**: Two gateways for traffic management
  - `envoy-external` (10.100.50.151): Public-facing services
  - `envoy-internal` (10.100.50.152): Internal-only services
  - HTTP/3, Brotli compression, TLS termination
- **[External-DNS](https://github.com/kubernetes-sigs/external-dns)**: Dual DNS automation
  - Cloudflare: Public DNS records
  - UniFi: Internal network DNS
- **[Cloudflare Tunnel](https://github.com/cloudflare/cloudflared)**: Secure external access without port forwarding

### Observability

- **[Prometheus Stack](https://github.com/prometheus-community/helm-charts)**: Metrics collection and alerting
  - Prometheus, Grafana, AlertManager
  - ServiceMonitor autodiscovery
- **[Victoria-Logs](https://github.com/VictoriaMetrics/VictoriaMetrics)**: Log aggregation
- **[Fluent-Bit](https://github.com/fluent/fluent-bit)**: Log collection and forwarding
- **[Gatus](https://github.com/TwiN/gatus)**: Uptime monitoring and status page
- **[UnPoller](https://github.com/unpoller/unpoller)**: UniFi network metrics

### Secret Management

- **[External Secrets Operator](https://github.com/external-secrets/external-secrets)**: Sync secrets from 1Password to Kubernetes
- **[SOPS](https://github.com/getsops/sops)**: Encrypted secrets in Git

### Applications

**Media & Entertainment:**
- Plex, Jellyfin, Jellyseerr
- Sabnzbd, Prowlarr, Radarr, Sonarr
- ROMM (ROM manager)

**Home Automation:**
- Home Assistant

**Gaming:**
- Minecraft (survival server with mc-router)

**Utilities:**
- PgAdmin (PostgreSQL management)
- Echo (testing service)

### 🌐 Service Access

Quick reference for accessing deployed services:

| Service | URL | Gateway | Description |
|---------|-----|---------|-------------|
| Grafana | `grafana.phekno.io` | Internal | Metrics visualization |
| Prometheus | `prometheus.phekno.io` | Internal | Metrics collection |
| AlertManager | `alertmanager.phekno.io` | Internal | Alert management |
| Longhorn | `longhorn.phekno.io` | Internal | Storage management |
| PgAdmin | `pgadmin.phekno.io` | Internal | PostgreSQL management |
| LLDAP | `lldap.phekno.io` | Internal | LDAP user management (planned) |
| Authelia | `auth.phekno.io` | Internal | SSO portal (planned) |
| Plex | `plex.phekno.io` | External | Media streaming |
| Jellyfin | `jellyfin.phekno.io` | External | Media streaming |
| Home Assistant | `home-assistant.phekno.io` | External | Home automation |
| Flux Webhook | `flux-webhook.phekno.io` | External | GitOps webhook receiver |
| Echo | `echo.phekno.io` | External | Testing service |

### Development & Automation

- **[mise](https://mise.jdx.dev/)**: Development environment manager
- **[Renovate](https://www.mend.io/renovate)**: Automated dependency updates
- **[GitHub Actions](https://github.com/features/actions)**: CI/CD workflows
- **[flux-local](https://github.com/allenporter/flux-local)**: Local Flux testing and diffing

## 🚀 Quick Start

This cluster is already deployed and operational. For operational tasks, see the sections below.

### Prerequisites

Ensure you have the following tools installed locally:

```sh
# Install mise for tool management
# See: https://mise.jdx.dev/getting-started.html

# Trust and install tools
mise trust
pip install pipx
mise install
```

This will install: kubectl, talosctl, flux, cilium, helm, kubectl, k9s, and other required CLI tools.

## 🔧 Cluster Operations

### ✅ Health Checks

**Check Cilium status:**
```sh
cilium status
```

**Check Flux status:**
```sh
flux check
flux get sources git -A
flux get ks -A
flux get hr -A
```

📍 _Run `task reconcile` to force Flux to sync your Git repository state_

**Check Gateway status:**
```sh
kubectl get gateway -n network
kubectl get httproute -A
```

**Check Envoy Gateway connectivity:**
```sh
# Internal gateway (10.100.50.152)
curl -k https://10.100.50.152

# External gateway (10.100.50.151)
curl -k https://10.100.50.151
```

**Check certificates:**
```sh
kubectl get certificates -A
kubectl -n cert-manager describe certificates
```

**Check storage:**
```sh
# Longhorn
kubectl get volumes -n longhorn-system
kubectl get pvc -A
```

### 🌐 Networking

#### Gateway API (Envoy Gateway)

This cluster uses **Envoy Gateway** with Gateway API instead of traditional Ingress resources.

**Two gateways available:**
- **envoy-internal** (10.100.50.152): For internal-only services
  - Use parentRef: `name: envoy-internal, namespace: network`
- **envoy-external** (10.100.50.151): For publicly accessible services
  - Use parentRef: `name: envoy-external, namespace: network`

**Example HTTPRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
spec:
  hostnames: ["my-app.phekno.io"]
  parentRefs:
    - name: envoy-internal  # or envoy-external
      namespace: network
      sectionName: https
  rules:
    - backendRefs:
        - name: my-app-service
          port: 80
```

#### DNS Configuration

**External DNS** automatically manages DNS records:
- **Cloudflare**: Public DNS for external access
- **UniFi**: Internal network DNS integration

HTTPRoutes with appropriate gateway references automatically get DNS entries created.

#### GitHub Webhook

Flux can reconcile immediately on git push via webhook at `https://flux-webhook.phekno.io`.

**Get webhook path:**
```sh
kubectl -n flux-system get receiver github-webhook -o jsonpath='{.status.webhookPath}'
```

Webhook is configured in GitHub repository settings to send push events.

### 💾 Backups

**PostgreSQL** (CloudNativePG):
- Automated backups to Cloudflare R2: `s3://phekno-home-k8s-pg/`
- Retention: Managed by CloudNativePG backup policies
- Recovery: Use CloudNativePG recovery procedures

**Longhorn**:
- Backup target: `s3://phekno-longhorn-backup@us-east-1/`
- Manual backups: Via Longhorn UI at `longhorn.phekno.io`
- Scheduled snapshots: Configured per-volume

**Configuration**:
- All cluster configuration is version controlled in Git
- Secrets managed via External Secrets Operator + 1Password
- SOPS-encrypted secrets for sensitive GitOps data

## 💥 Cluster Reset

> [!WARNING]
> This will completely destroy the cluster and all data. Ensure backups are current before proceeding.

Reset nodes back to maintenance mode:
```sh
task talos:reset
```

## 🛠️ Talos and Kubernetes Maintenance

### ⚙️ Updating Talos node configuration

> [!TIP]
> Ensure you have updated `talconfig.yaml` and any patches with your updated configuration. In some cases you **not only need to apply the configuration but also upgrade talos** to apply new configuration.

```sh
# (Re)generate the Talos config
task talos:generate-config
# Apply the config to the node
task talos:apply-node IP=? MODE=?
# e.g. task talos:apply-node IP=10.10.10.10 MODE=auto
```

### ⬆️ Updating Talos and Kubernetes versions

> [!TIP]
> Ensure the `talosVersion` and `kubernetesVersion` in `talenv.yaml` are up-to-date with the version you wish to upgrade to.

```sh
# Upgrade node to a newer Talos version
task talos:upgrade-node IP=?
# e.g. task talos:upgrade-node IP=10.10.10.10
```

```sh
# Upgrade cluster to a newer Kubernetes version
task talos:upgrade-k8s
# e.g. task talos:upgrade-k8s
```

## 🤖 Renovate

[Renovate](https://www.mend.io/renovate) is a tool that automates dependency management. It is designed to scan your repository around the clock and open PRs for out-of-date dependencies it finds. Common dependencies it can discover are Helm charts, container images, GitHub Actions and more! In most cases merging a PR will cause Flux to apply the update to your cluster.

To enable Renovate, click the 'Configure' button over at their [Github app page](https://github.com/apps/renovate) and select your repository. Renovate creates a "Dependency Dashboard" as an issue in your repository, giving an overview of the status of all updates. The dashboard has interactive checkboxes that let you do things like advance scheduling or reattempt update PRs you closed without merging.

The base Renovate configuration in your repository can be viewed at [.renovaterc.json5](.renovaterc.json5). By default it is scheduled to be active with PRs every weekend, but you can [change the schedule to anything you want](https://docs.renovatebot.com/presets-schedule), or remove it if you want Renovate to open PRs immediately.

## 🐛 Debugging

Below is a general guide on trying to debug an issue with an resource or application. For example, if a workload/resource is not showing up or a pod has started but in a `CrashLoopBackOff` or `Pending` state. These steps do not include a way to fix the problem as the problem could be one of many different things.

1. Check if the Flux resources are up-to-date and in a ready state:

   📍 _Run `task reconcile` to force Flux to sync your Git repository state_

    ```sh
    flux get sources git -A
    flux get ks -A
    flux get hr -A
    ```

2. Do you see the pod of the workload you are debugging:

    ```sh
    kubectl -n <namespace> get pods -o wide
    ```

3. Check the logs of the pod if its there:

    ```sh
    kubectl -n <namespace> logs <pod-name> -f
    ```

4. If a resource exists try to describe it to see what problems it might have:

    ```sh
    kubectl -n <namespace> describe <resource> <name>
    ```

5. Check the namespace events:

    ```sh
    kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
    ```

Resolving problems that you have could take some tweaking of your YAML manifests in order to get things working, other times it could be a external factor like permissions on a NFS server. If you are unable to figure out your problem see the support sections below.

## 📚 Documentation

Additional documentation is available in the [`docs/`](./docs/) directory:

- **[Authelia + LLDAP Integration](./docs/authelia-lldap-integration.md)**: Guide for implementing forward authentication with Envoy Gateway

### 🧩 Kustomize Components

Reusable components are available in [`kubernetes/components/`](./kubernetes/components/):

- **[ext-auth](./kubernetes/components/ext-auth/)**: Add external authentication to any HTTPRoute
- **[common](./kubernetes/components/common/)**: Common resources (secrets, namespace)
- **[gatus](./kubernetes/components/gatus/)**: Add uptime monitoring endpoint
- **[volsync](./kubernetes/components/volsync/)**: Add volume backup/replication

See individual component READMEs for usage instructions.

## 👉 Community Support

Questions or need help? Great resources:
- [Home Operations Discord](https://discord.gg/home-operations) - `#support` and `#flux` channels
- [Kubernetes Homelab Reddit](https://reddit.com/r/kubernetes) and [r/selfhosted](https://reddit.com/r/selfhosted)
- Individual project documentation (see links in Features section above)

## 🎯 Future Enhancements

Potential improvements and additions:

- **Authentication**: Implement Authelia + LLDAP for centralized SSO (see [docs](./docs/authelia-lldap-integration.md))
- **Monitoring**: Expand observability with additional ServiceMonitors
- **Backups**: Implement automated testing of backup restoration procedures
- **GitOps**: Add automated testing with flux-local
- **Security**: Implement NetworkPolicies for pod-to-pod traffic control
- **Service Mesh**: Consider Cilium service mesh features for advanced traffic management

## 🔗 Useful Resources

- **[Kubesearch](https://kubesearch.dev)**: Search Flux HelmReleases across GitHub/GitLab repositories
- **[Gateway API Documentation](https://gateway-api.sigs.k8s.io/)**: Official Gateway API reference
- **[Envoy Gateway Documentation](https://gateway.envoyproxy.io/)**: Envoy Gateway guides and API reference
- **[Talos Linux Documentation](https://www.talos.dev/)**: Talos OS documentation and guides
- **[Flux Documentation](https://fluxcd.io/flux/)**: Flux CD documentation

## 🙌 Inspiration & References

This cluster was initially based on the excellent [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template).

**Other great homelab projects:**
- [onedr0p/home-ops](https://github.com/onedr0p/home-ops) - onedr0p's personal home operations cluster
- [khuedoan/homelab](https://github.com/khuedoan/homelab) - Fully automated homelab from empty disk to running services
- [ricsanfre/pi-cluster](https://github.com/ricsanfre/pi-cluster) - Pi Kubernetes cluster automated with Ansible and FluxCD
- [bjw-s/home-ops](https://github.com/bjw-s/home-ops) - bjw-s home operations using Flux

## 🤝 Acknowledgments

- **[onedr0p](https://github.com/onedr0p)** for the cluster-template and app-template Helm chart
- **[bjw-s](https://github.com/bjw-s)** for the app-template Helm chart
- The **Home Operations Discord** community for support and inspiration
