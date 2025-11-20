# External Authentication Component

This Kustomize component adds external authentication (via Authelia) to any application's HTTPRoute.

## Prerequisites

- Authelia must be deployed in the `security` namespace
- Authelia service must be available at `authelia.security.svc.cluster.local:9091`
- Application must use an HTTPRoute (Gateway API)

## Usage

Add this component to your app's `kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
components:
  - ../../../components/ext-auth  # Adjust path as needed
resources:
  - ./helmrelease.yaml
```

### Important

The component uses `${APP}` variable substitution which expects:
- An HTTPRoute named `${APP}` to exist in the same namespace
- The SecurityPolicy will be named `${APP}-auth`

For apps using the bjw-s app-template with `route:` configured, the HTTPRoute name will match the HelmRelease name by default.

## Example

For an app like Grafana in the `monitoring` namespace:

1. **Directory structure:**
   ```
   kubernetes/apps/monitoring/grafana/app/
   ├── kustomization.yaml
   └── helmrelease.yaml
   ```

2. **kustomization.yaml:**
   ```yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: monitoring
   components:
     - ../../../components/ext-auth
   resources:
     - ./helmrelease.yaml
   ```

3. **helmrelease.yaml** (excerpt):
   ```yaml
   metadata:
     name: grafana
   spec:
     values:
       route:
         main:
           hostnames: ["grafana.phekno.io"]
           parentRefs:
             - name: envoy-internal
               namespace: network
   ```

This will create:
- HTTPRoute: `grafana` (from HelmRelease)
- SecurityPolicy: `grafana-auth` (from component)

The SecurityPolicy will automatically attach to the `grafana` HTTPRoute and require Authelia authentication.

## Access Control

Configure which users/groups can access the application in Authelia's ConfigMap:

```yaml
access_control:
  rules:
    - domain: grafana.phekno.io
      policy: one_factor
      subject:
        - "group:admins"
        - "group:monitoring"
```

## Removing Authentication

To remove authentication from an app, simply remove the component from its `kustomization.yaml`.
