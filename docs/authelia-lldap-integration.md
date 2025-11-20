# Authelia + LLDAP Integration with Envoy Gateway

## Overview

This document describes how to integrate Authelia and LLDAP with Envoy Gateway to provide centralized authentication and authorization for services in your home-ops Kubernetes cluster.

### What is Authelia?

[Authelia](https://www.authelia.com/) is an open-source authentication and authorization server providing single sign-on (SSO) and two-factor authentication (2FA) for your applications. It acts as a forward authentication proxy, integrating with reverse proxies and API gateways to protect web applications.

**Key Features:**
- Single Sign-On (SSO) portal
- Multi-factor authentication (TOTP, WebAuthn, Security Keys)
- Fine-grained access control rules
- Session management
- LDAP/Active Directory backend support
- Low resource footprint

### What is LLDAP?

[LLDAP](https://github.com/lldap/lldap) (Light LDAP) is a lightweight LDAP implementation written in Rust, designed for small-scale deployments like home labs and small businesses.

**Key Features:**
- Full LDAP v3 protocol support
- Web-based user management UI
- Low resource requirements (~50MB RAM)
- User and group management
- Simple deployment and configuration
- No complex schema requirements

### Why Use This Integration?

**Benefits:**
- **Centralized Authentication**: Single user directory (LLDAP) for all services
- **Enhanced Security**: Add MFA to any application, even those without native support
- **Access Control**: Group-based access policies per application
- **Audit Trail**: Centralized authentication logging
- **User Management**: Simple web UI for managing users and groups
- **SSO Experience**: Users authenticate once, access multiple services

## Architecture

### Component Interaction Flow

```
┌─────────┐
│  User   │
└────┬────┘
     │
     │ 1. Request (https://app.phekno.io)
     ▼
┌─────────────────────┐
│  Envoy Gateway      │
│  (envoy-internal)   │
└──────┬──────────────┘
       │
       │ 2. ext_authz check
       │    (SecurityPolicy)
       ▼
┌──────────────────┐
│    Authelia      │◄──────┐
│  (Port 9091)     │       │
└──────┬───────────┘       │
       │                   │
       │ 3. Session Check  │ 5. Cache Result
       │    (Is user       │
       │     logged in?)   │
       ▼                   │
┌──────────────────┐       │
│  Session Store   │       │
│  (PostgreSQL/    │       │
│   Redis)         │       │
└──────────────────┘       │
       │                   │
       │ 4. Verify Credentials (if needed)
       │    & Get Group Membership
       ▼                   │
┌──────────────────┐       │
│      LLDAP       │───────┘
│  (Port 389)      │
└──────────────────┘
       │
       │ 6. Auth Decision + Headers
       ▼
┌─────────────────────┐
│  Envoy Gateway      │
│  Forwards to        │
│  Backend Service    │
└─────────────────────┘
```

### Authentication Flow Details

1. **User Request**: User accesses protected service (e.g., `grafana.phekno.io`)
2. **Envoy ext_authz**: Gateway checks with Authelia via gRPC (configured by SecurityPolicy)
3. **Session Validation**: Authelia checks if user has valid session
   - **If valid session exists**: Return OK + user headers → proceed to backend
   - **If no session**: Redirect to Authelia login portal (`auth.phekno.io`)
4. **Authentication** (when no session):
   - User enters credentials on Authelia portal
   - Authelia queries LLDAP to verify username/password
   - Authelia checks user's group memberships in LLDAP
5. **Authorization**: Authelia evaluates access control rules
   - Check if user/group has permission for requested resource
   - Apply any additional policies (IP allowlists, time-based rules, etc.)
6. **Session Creation**: If auth succeeds, create encrypted session cookie
7. **Redirect**: User redirected back to original URL with session cookie
8. **Subsequent Requests**: Session cookie allows access without re-authentication

## Prerequisites

From your existing home-ops infrastructure:

- **Envoy Gateway**: v1.5.3+ with Gateway API v1 support ✓
- **PostgreSQL**: CloudNativePG cluster for Authelia session storage ✓
- **Storage Class**: Longhorn for persistent volumes ✓
- **External Secrets**: For managing sensitive credentials ✓
- **Flux CD**: For GitOps deployment ✓
- **DNS**: External DNS or manual DNS entries for auth portal ✓

**New Components Needed:**
- LLDAP deployment
- Authelia deployment
- SecurityPolicy CRDs for protected routes
- Secrets for Authelia and LLDAP

## Deployment Architecture

### Recommended Namespace Structure

```
auth/
├── lldap/
│   ├── helmrelease.yaml
│   ├── pvc.yaml
│   └── externalsecret.yaml
├── authelia/
│   ├── helmrelease.yaml
│   ├── configmap.yaml
│   └── externalsecret.yaml
└── policies/
    ├── grafana-auth-policy.yaml
    ├── longhorn-auth-policy.yaml
    └── ...
```

## Configuration Examples

### 1. LLDAP Deployment

**HelmRelease Example** (`kubernetes/apps/security/lldap/app/helmrelease.yaml`):

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: lldap
  namespace: security
spec:
  interval: 30m
  chart:
    spec:
      chart: app-template
      version: 3.x  # Use appropriate version
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
  values:
    controllers:
      main:
        containers:
          main:
            image:
              repository: ghcr.io/lldap/lldap
              tag: v0.5.0
            env:
              TZ: America/Chicago
              LLDAP_LDAP_PORT: "389"
              LLDAP_HTTP_PORT: "17170"
              LLDAP_LDAP_BASE_DN: "dc=phekno,dc=io"
            envFrom:
              - secretRef:
                  name: lldap-secret
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: 17170
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: 17170

    service:
      main:
        ports:
          http:
            port: 17170
          ldap:
            port: 389

    route:
      main:
        enabled: true
        hostnames: ["lldap.phekno.io"]
        parentRefs:
          - name: envoy-internal
            namespace: network
            sectionName: https

    persistence:
      data:
        enabled: true
        type: persistentVolumeClaim
        storageClass: longhorn
        accessMode: ReadWriteOnce
        size: 1Gi
        globalMounts:
          - path: /data
```

**ExternalSecret for LLDAP** (`kubernetes/apps/security/lldap/app/externalsecret.yaml`):

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: lldap-secret
  namespace: security
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect  # Adjust to your secret store
  target:
    name: lldap-secret
    template:
      engineVersion: v2
      data:
        LLDAP_JWT_SECRET: "{{ .jwt_secret }}"
        LLDAP_LDAP_USER_PASS: "{{ .admin_password }}"
        LLDAP_LDAP_USER_DN: "admin"
  dataFrom:
    - extract:
        key: lldap  # 1Password item name
```

### 2. Authelia Deployment

**ConfigMap** (`kubernetes/apps/security/authelia/app/configmap.yaml`):

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: authelia-config
  namespace: security
data:
  configuration.yml: |
    theme: auto
    server:
      host: 0.0.0.0
      port: 9091
      path: ""
      asset_path: ""
      enable_pprof: false
      enable_expvars: false

    log:
      level: info
      format: text

    telemetry:
      metrics:
        enabled: true
        address: tcp://0.0.0.0:9959
        buffers:
          read: 4096
          write: 4096

    totp:
      disable: false
      issuer: phekno.io
      algorithm: sha1
      digits: 6
      period: 30
      skew: 1
      secret_size: 32

    webauthn:
      disable: false
      display_name: Phekno Auth
      attestation_conveyance_preference: indirect
      user_verification: preferred
      timeout: 60s

    authentication_backend:
      password_reset:
        disable: false
      refresh_interval: 5m
      ldap:
        implementation: custom
        url: ldap://lldap.security.svc.cluster.local:389
        timeout: 5s
        start_tls: false
        base_dn: dc=phekno,dc=io
        username_attribute: uid
        additional_users_dn: ou=people
        users_filter: (&({username_attribute}={input})(objectClass=person))
        additional_groups_dn: ou=groups
        groups_filter: (member={dn})
        group_name_attribute: cn
        mail_attribute: mail
        display_name_attribute: displayName
        user: uid=admin,ou=people,dc=phekno,dc=io

    session:
      name: authelia_session
      domain: phekno.io
      same_site: lax
      expiration: 1h
      inactivity: 5m
      remember_me_duration: 1M

    regulation:
      max_retries: 3
      find_time: 2m
      ban_time: 5m

    storage:
      postgres:
        host: postgres-rw.database.svc.cluster.local
        port: 5432
        database: authelia
        schema: public
        username: authelia
        timeout: 5s

    notifier:
      disable_startup_check: true
      filesystem:
        filename: /config/notification.txt

    access_control:
      default_policy: deny
      rules:
        # Authelia portal itself
        - domain: auth.phekno.io
          policy: bypass

        # Public services (no auth required)
        - domain: echo.phekno.io
          policy: bypass

        # Admin-only services
        - domain:
            - grafana.phekno.io
            - longhorn.phekno.io
            - prometheus.phekno.io
            - alertmanager.phekno.io
          policy: two_factor
          subject:
            - "group:admins"

        # Authenticated users (any valid user)
        - domain:
            - "*.phekno.io"
          policy: one_factor
```

**HelmRelease** (`kubernetes/apps/security/authelia/app/helmrelease.yaml`):

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: authelia
  namespace: security
spec:
  interval: 30m
  chart:
    spec:
      chart: app-template
      version: 3.x
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
  values:
    controllers:
      main:
        replicas: 2  # For high availability
        strategy: RollingUpdate
        annotations:
          reloader.stakater.com/auto: "true"

        initContainers:
          init-db:
            image:
              repository: ghcr.io/home-operations/postgres-init
              tag: 18.1
            envFrom:
              - secretRef:
                  name: authelia-secret

        containers:
          main:
            image:
              repository: ghcr.io/authelia/authelia
              tag: 4.38.16
            args:
              - --config=/config/configuration.yml
            env:
              TZ: America/Chicago
              AUTHELIA_SERVER_DISABLE_HEALTHCHECK: "false"
            envFrom:
              - secretRef:
                  name: authelia-secret
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/health
                    port: 9091
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/health
                    port: 9091
            resources:
              requests:
                cpu: 10m
                memory: 128Mi
              limits:
                memory: 256Mi

    service:
      main:
        controller: main
        ports:
          http:
            port: 9091
          metrics:
            port: 9959

    route:
      main:
        enabled: true
        hostnames: ["auth.phekno.io"]
        parentRefs:
          - name: envoy-internal
            namespace: network
            sectionName: https

    serviceMonitor:
      main:
        enabled: true
        endpoints:
          - port: metrics
            scheme: http
            path: /metrics
            interval: 1m

    persistence:
      config:
        enabled: true
        type: configMap
        name: authelia-config
        globalMounts:
          - path: /config/configuration.yml
            subPath: configuration.yml
            readOnly: true
```

**ExternalSecret for Authelia** (`kubernetes/apps/security/authelia/app/externalsecret.yaml`):

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: authelia-secret
  namespace: security
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: authelia-secret
    template:
      engineVersion: v2
      data:
        # PostgreSQL init container
        INIT_POSTGRES_DBNAME: authelia
        INIT_POSTGRES_HOST: postgres-rw.database.svc.cluster.local
        INIT_POSTGRES_USER: authelia
        INIT_POSTGRES_PASS: "{{ .db_password }}"
        INIT_POSTGRES_SUPER_PASS: "{{ .db_superuser_password }}"

        # Authelia config
        AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD: "{{ .ldap_password }}"
        AUTHELIA_JWT_SECRET: "{{ .jwt_secret }}"
        AUTHELIA_SESSION_SECRET: "{{ .session_secret }}"
        AUTHELIA_STORAGE_ENCRYPTION_KEY: "{{ .storage_encryption_key }}"
        AUTHELIA_STORAGE_POSTGRES_PASSWORD: "{{ .db_password }}"
  dataFrom:
    - extract:
        key: authelia
```

### 3. Using the External Authentication Kustomize Component

This cluster uses a **Kustomize component** to add authentication to applications. This provides a reusable, DRY approach that's easy to apply to any app.

**Component Location**: `kubernetes/components/ext-auth/`

The component automatically creates a SecurityPolicy that:
- References the central Authelia service in the `security` namespace
- Attaches to the app's HTTPRoute
- Uses the `${APP}` variable for dynamic naming

#### Adding Authentication to an Application

**Before** (app without authentication):

```yaml
# kubernetes/apps/monitoring/grafana/app/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
resources:
  - ./helmrelease.yaml
```

**After** (app with authentication):

```yaml
# kubernetes/apps/monitoring/grafana/app/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
components:
  - ../../../components/ext-auth  # Add this line
resources:
  - ./helmrelease.yaml
```

That's it! The component will:
1. Create a SecurityPolicy named `grafana-auth`
2. Attach it to the `grafana` HTTPRoute
3. Configure ext_authz to use Authelia

#### How It Works

The component uses Kustomize variable substitution with `${APP}`:

```yaml
# kubernetes/components/ext-auth/securitypolicy.yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ${APP}-auth
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: ${APP}  # Matches the HelmRelease name
  extAuth:
    grpc:
      backendRef:
        name: authelia
        namespace: security
        port: 9091
```

For apps using the bjw-s app-template with `route:` configured, the HTTPRoute name automatically matches the HelmRelease name.

#### Multiple Apps Example

Protect multiple services by adding the component to each:

```yaml
# Grafana
kubernetes/apps/monitoring/grafana/app/kustomization.yaml:
  components: [../../../components/ext-auth]

# Longhorn
kubernetes/apps/longhorn-system/longhorn/app/kustomization.yaml:
  components: [../../../components/ext-auth]

# PgAdmin
kubernetes/apps/db/pgadmin/app/kustomization.yaml:
  components: [../../../components/ext-auth]
```

#### Removing Authentication

To remove authentication from an app, simply delete the `components:` section from its `kustomization.yaml`.

#### Alternative: Gateway-Level Authentication

For securing everything by default, you can apply a SecurityPolicy directly to the gateway:

```yaml
# kubernetes/apps/network/envoy-gateway/policies/internal-auth.yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: internal-gateway-auth
  namespace: network
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: envoy-internal
  extAuth:
    grpc:
      backendRef:
        name: authelia
        namespace: security
        port: 9091
```

Then configure Authelia to bypass specific routes (like the auth portal itself) via access control rules (see next section).

## Access Control Rules

### LLDAP User and Group Setup

1. **Create Groups** (via LLDAP web UI at `lldap.phekno.io`):
   - `admins` - Full access to all services
   - `users` - Standard user access
   - `monitoring` - Access to monitoring services only
   - `media` - Access to media services (Plex, Jellyfin, etc.)

2. **Create Users**:
   - Add users via LLDAP UI
   - Assign to appropriate groups
   - Set email addresses for password reset

3. **Example User Structure**:
   ```
   ou=people,dc=phekno,dc=io
   ├── uid=admin (memberOf: admins)
   ├── uid=john (memberOf: users, monitoring)
   └── uid=jane (memberOf: users, media)

   ou=groups,dc=phekno,dc=io
   ├── cn=admins
   ├── cn=users
   ├── cn=monitoring
   └── cn=media
   ```

### Authelia Access Control Examples

**Basic Rules**:

```yaml
access_control:
  default_policy: deny  # Deny by default, explicit allow

  rules:
    # Public/bypass routes
    - domain: auth.phekno.io
      policy: bypass

    - domain:
        - echo.phekno.io
        - status.phekno.io
      policy: bypass

    # Admin-only with 2FA
    - domain:
        - grafana.phekno.io
        - prometheus.phekno.io
        - alertmanager.phekno.io
        - longhorn.phekno.io
      policy: two_factor
      subject:
        - "group:admins"

    # Monitoring group access (1FA only)
    - domain:
        - grafana.phekno.io
      policy: one_factor
      subject:
        - "group:monitoring"

    # Media services
    - domain:
        - plex.phekno.io
        - jellyfin.phekno.io
      policy: one_factor
      subject:
        - "group:media"
        - "group:admins"

    # Catch-all for authenticated users
    - domain: "*.phekno.io"
      policy: one_factor
```

**Advanced Rules with Networks**:

```yaml
access_control:
  default_policy: deny
  networks:
    - name: internal
      networks:
        - 10.0.0.0/8
        - 192.168.0.0/16
    - name: vpn
      networks:
        - 10.100.0.0/16

  rules:
    # Admin services: Require 2FA unless on internal network
    - domain:
        - grafana.phekno.io
        - longhorn.phekno.io
      policy: one_factor
      subject:
        - "group:admins"
      networks:
        - internal

    - domain:
        - grafana.phekno.io
        - longhorn.phekno.io
      policy: two_factor
      subject:
        - "group:admins"
```

**Per-Resource Rules**:

```yaml
access_control:
  rules:
    # Allow read-only access to Grafana dashboards
    - domain: grafana.phekno.io
      policy: one_factor
      resources:
        - "^/api/dashboards.*$"
      subject:
        - "group:monitoring"

    # Require admin for Grafana admin pages
    - domain: grafana.phekno.io
      policy: two_factor
      resources:
        - "^/admin.*$"
      subject:
        - "group:admins"
```

## Testing and Verification

### 1. Verify LLDAP Deployment

```bash
# Check LLDAP pod status
kubectl get pods -n auth -l app.kubernetes.io/name=lldap

# Check LLDAP logs
kubectl logs -n auth -l app.kubernetes.io/name=lldap

# Test LDAP connection from within cluster
kubectl run -it --rm ldapsearch --image=alpine/openldap-client --restart=Never -- \
  ldapsearch -x -H ldap://lldap.security.svc.cluster.local:389 \
  -D "uid=admin,ou=people,dc=phekno,dc=io" \
  -w "YOUR_ADMIN_PASSWORD" \
  -b "dc=phekno,dc=io" \
  "(objectClass=person)"

# Access LLDAP web UI
open https://lldap.phekno.io
```

### 2. Verify Authelia Deployment

```bash
# Check Authelia pod status
kubectl get pods -n auth -l app.kubernetes.io/name=authelia

# Check Authelia logs
kubectl logs -n auth -l app.kubernetes.io/name=authelia

# Test Authelia health endpoint
kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl -s http://authelia.security.svc.cluster.local:9091/api/health

# Access Authelia portal
open https://auth.phekno.io
```

### 3. Verify SecurityPolicy

```bash
# Check SecurityPolicy status
kubectl get securitypolicy -A

# Describe specific policy
kubectl describe securitypolicy grafana-auth -n monitoring

# Check if policy is accepted
kubectl get securitypolicy grafana-auth -n monitoring -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# Should output: True
```

### 4. Test Authentication Flow

**Manual Test**:

1. **Clear browser cookies** for `*.phekno.io`
2. **Access protected service**: Navigate to `https://grafana.phekno.io`
3. **Expect redirect**: Should redirect to `https://auth.phekno.io`
4. **Login**: Use LLDAP credentials
5. **Verify redirect**: Should redirect back to Grafana
6. **Check session**: Session cookie should be set for `.phekno.io`
7. **Test SSO**: Access another protected service (e.g., Longhorn) - should not require re-authentication

**Check Envoy Gateway Logs**:

```bash
# Get Envoy Gateway pod
ENVOY_POD=$(kubectl get pods -n envoy-gateway-system -l control-plane=envoy-gateway -o jsonpath='{.items[0].metadata.name}')

# Watch logs for ext_authz calls
kubectl logs -n envoy-gateway-system $ENVOY_POD -f | grep ext_authz
```

**Check Authelia Logs**:

```bash
# Watch Authelia authentication attempts
kubectl logs -n auth -l app.kubernetes.io/name=authelia -f | grep -E 'authentication|authorization'
```

### 5. Test Access Control

**Test different user groups**:

```bash
# Test admin user (should access everything with 2FA)
# Test monitoring user (should only access monitoring services)
# Test unauthorized user (should be denied)
```

**Verify headers passed to backend**:

Deploy a debug service that prints headers:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: header-inspector
  namespace: default
spec:
  containers:
  - name: inspector
    image: mendhak/http-https-echo:latest
    ports:
    - containerPort: 8080
```

Then check what headers Authelia passes through:
- `Remote-User`: Username
- `Remote-Name`: Display name
- `Remote-Email`: Email address
- `Remote-Groups`: Comma-separated groups

## Troubleshooting

### Common Issues

#### 1. Redirect Loop (auth.phekno.io keeps redirecting)

**Symptoms**: Browser keeps redirecting between service and auth portal

**Causes**:
- Authelia portal (`auth.phekno.io`) has SecurityPolicy applied to it
- Session domain mismatch

**Solutions**:
```yaml
# Ensure Authelia portal HTTPRoute has no SecurityPolicy
# OR ensure SecurityPolicy bypasses auth.phekno.io

# In authelia config, verify:
access_control:
  rules:
    - domain: auth.phekno.io
      policy: bypass  # Critical!
```

#### 2. "502 Bad Gateway" on protected routes

**Symptoms**: Protected routes return 502 error

**Causes**:
- Authelia service not reachable
- Wrong namespace/service name in SecurityPolicy
- Authelia not responding on port 9091

**Diagnosis**:
```bash
# Test Authelia service from within cluster
kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
  curl -v http://authelia.security.svc.cluster.local:9091/api/health

# Check SecurityPolicy backendRef
kubectl get securitypolicy -A -o yaml | grep -A 5 backendRef

# Check Authelia logs for errors
kubectl logs -n auth -l app.kubernetes.io/name=authelia
```

**Solutions**:
- Verify service name: `kubectl get svc -n auth`
- Verify Authelia is healthy: Check pod status and logs
- Verify SecurityPolicy references correct namespace

#### 3. LDAP Authentication Failures

**Symptoms**: Login fails with "Invalid credentials" even with correct password

**Causes**:
- Wrong LDAP bind DN
- Wrong base DN
- LLDAP not reachable
- User filter doesn't match

**Diagnosis**:
```bash
# Check Authelia can reach LLDAP
kubectl exec -it -n auth deployment/authelia -- \
  wget -O- http://lldap.security.svc.cluster.local:389

# Test LDAP bind from Authelia pod
kubectl exec -it -n auth deployment/authelia -- sh
# Then inside pod:
ldapsearch -x -H ldap://lldap.security.svc.cluster.local:389 \
  -D "uid=admin,ou=people,dc=phekno,dc=io" \
  -w "ADMIN_PASSWORD" \
  -b "dc=phekno,dc=io"

# Check Authelia logs for LDAP errors
kubectl logs -n auth -l app.kubernetes.io/name=authelia | grep -i ldap
```

**Solutions**:
- Verify LDAP configuration in Authelia ConfigMap
- Verify LLDAP admin password in secret
- Check LLDAP base DN matches Authelia config

#### 4. Session Expires Immediately

**Symptoms**: User must re-authenticate on every request

**Causes**:
- Session cookie not being set
- Cookie domain mismatch
- PostgreSQL session storage issue

**Diagnosis**:
```bash
# Check browser developer tools → Application → Cookies
# Should see: authelia_session cookie for .phekno.io

# Check Authelia session config
kubectl get cm -n auth authelia-config -o yaml | grep -A 10 session:

# Check PostgreSQL connectivity
kubectl exec -it -n auth deployment/authelia -- \
  psql postgresql://authelia:PASSWORD@postgres-rw.database.svc.cluster.local:5432/authelia -c "\dt"
```

**Solutions**:
```yaml
# Verify session config:
session:
  domain: phekno.io  # Must match your domain
  same_site: lax     # Not 'strict'
  expiration: 1h
```

#### 5. 2FA Not Working

**Symptoms**: TOTP codes rejected, or WebAuthn fails

**Causes**:
- Clock skew between Authelia and TOTP app
- TOTP secret not properly stored
- WebAuthn not configured correctly

**Solutions**:
```yaml
# Adjust TOTP skew in Authelia config:
totp:
  skew: 1  # Allow 1 time period before/after

# Ensure proper storage backend for secrets
storage:
  postgres:  # Don't use filesystem in production
    host: postgres-rw.database.svc.cluster.local
```

#### 6. Access Control Rules Not Applied

**Symptoms**: User has access when they shouldn't, or vice versa

**Causes**:
- Rule order incorrect (first match wins)
- Group membership not synced from LDAP
- Default policy too permissive

**Diagnosis**:
```bash
# Check Authelia logs for authorization decisions
kubectl logs -n auth -l app.kubernetes.io/name=authelia | grep authorization

# Verify user's group memberships in LLDAP
# Via LLDAP web UI or:
kubectl exec -it -n auth deployment/lldap -- \
  ldapsearch -x -H ldap://localhost:389 \
  -D "uid=admin,ou=people,dc=phekno,dc=io" \
  -w "PASSWORD" \
  -b "ou=people,dc=phekno,dc=io" \
  "(uid=USERNAME)" memberOf
```

**Solutions**:
- Reorder rules (most specific first, default last)
- Verify group attribute in Authelia LDAP config: `group_name_attribute: cn`
- Check group filter: `groups_filter: (member={dn})`

### Debug Mode

Enable debug logging in Authelia:

```yaml
# In authelia ConfigMap
log:
  level: debug  # Change from 'info'
  format: text
```

Then restart Authelia:
```bash
kubectl rollout restart deployment/authelia -n auth
```

### Health Checks

```bash
# Check all components
kubectl get pods -n auth
kubectl get svc -n auth
kubectl get httproute -n auth
kubectl get securitypolicy -A

# Check Authelia metrics (if ServiceMonitor configured)
kubectl port-forward -n auth svc/authelia 9959:9959
curl http://localhost:9959/metrics
```

## Security Considerations

### 1. Secrets Management

- **Never commit secrets** to Git - use External Secrets Operator
- **Rotate secrets regularly**:
  - LLDAP admin password
  - Authelia JWT secret
  - Authelia session secret
  - Authelia storage encryption key
- **Use strong, random secrets**:
  ```bash
  # Generate secrets:
  openssl rand -hex 32  # For JWT, session, encryption keys
  ```

### 2. TLS/HTTPS

- **Always use HTTPS** for Authelia portal
- **Enable HSTS headers** in Envoy Gateway ClientTrafficPolicy
- **Consider mTLS** between Envoy and Authelia for additional security:
  ```yaml
  spec:
    extAuth:
      grpc:
        backendRef:
          name: authelia
        backendSettings:
          tls:
            caCertRefs:
              - name: authelia-ca
                kind: ConfigMap
  ```

### 3. Access Control Best Practices

- **Default deny policy**: Start with `default_policy: deny`
- **Principle of least privilege**: Grant minimum required access
- **Use groups** instead of individual users in rules
- **Enable 2FA for admin services**
- **Consider network-based rules** for additional security layers

### 4. Rate Limiting

Protect against brute force attacks:

```yaml
# In Authelia config:
regulation:
  max_retries: 3        # Max failed login attempts
  find_time: 2m         # Time window to count retries
  ban_time: 5m          # How long to ban after max_retries
```

### 5. Session Security

```yaml
session:
  name: authelia_session
  domain: phekno.io
  same_site: lax        # Prevents CSRF
  secure: true          # Only over HTTPS (auto-detected)
  expiration: 1h        # Session lifetime
  inactivity: 5m        # Logout after inactivity
  remember_me_duration: 1M  # "Remember me" duration
```

### 6. Database Security

- **Use strong PostgreSQL passwords**
- **Limit network access** to PostgreSQL (internal cluster only)
- **Enable encryption at rest** for Longhorn volumes
- **Regular backups** of Authelia database

### 7. Monitoring and Alerting

- **Monitor failed authentication attempts**
- **Alert on unusual access patterns**
- **Track session creation rates**
- **Monitor Authelia availability** (critical service)

```yaml
# Example Prometheus alert
- alert: AutheliaHighFailedLogins
  expr: rate(authelia_authentication_failed_total[5m]) > 0.1
  for: 5m
  annotations:
    summary: High rate of failed login attempts
```

### 8. Backup and Recovery

**Critical data to backup**:
- LLDAP data volume (users and groups)
- Authelia PostgreSQL database (sessions, 2FA secrets)
- Authelia configuration and secrets

**Recovery procedure**:
1. Restore LLDAP data volume
2. Restore Authelia database from CloudNativePG backup
3. Reapply Authelia and LLDAP manifests
4. Users may need to re-authenticate

### 9. Network Policies

Consider implementing Kubernetes NetworkPolicies:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: authelia-network-policy
  namespace: security
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: authelia
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from Envoy Gateway only
    - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: envoy-gateway-system
      ports:
      - protocol: TCP
        port: 9091
  egress:
    # Allow to LLDAP
    - to:
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: lldap
      ports:
      - protocol: TCP
        port: 389
    # Allow to PostgreSQL
    - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: database
      ports:
      - protocol: TCP
        port: 5432
    # Allow DNS
    - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
      ports:
      - protocol: UDP
        port: 53
```

## Performance Optimization

### 1. Redis Session Storage (Optional)

For better performance than PostgreSQL sessions:

```yaml
# Add Redis deployment
# Then update Authelia config:
session:
  redis:
    host: redis.security.svc.cluster.local
    port: 6379
    database_index: 0
```

### 2. Authelia Replicas

Run multiple Authelia replicas for high availability:

```yaml
controllers:
  main:
    replicas: 2  # Or 3 for higher availability
    strategy: RollingUpdate
```

### 3. Connection Pooling

```yaml
storage:
  postgres:
    host: postgres-rw.database.svc.cluster.local
    port: 5432
    database: authelia
    max_open_conns: 25
    max_idle_conns: 5
```

### 4. Caching

Authelia caches LDAP queries by default:

```yaml
authentication_backend:
  ldap:
    refresh_interval: 5m  # How often to refresh user data from LDAP
```

## Migration Strategy

If you're adding auth to existing services:

### Phase 1: Deploy Infrastructure
1. Deploy LLDAP
2. Create users and groups in LLDAP
3. Deploy Authelia
4. Test Authelia portal login

### Phase 2: Test with Non-Critical Service
1. Apply SecurityPolicy to test service (e.g., Echo)
2. Verify authentication flow works
3. Test different users and groups
4. Verify SSO works across services

### Phase 3: Gradual Rollout
1. Start with internal-only services (envoy-internal gateway)
2. Apply SecurityPolicy to monitoring services
3. Apply to admin tools (Longhorn, etc.)
4. Finally, consider external services if desired

### Phase 4: Fine-Tune
1. Adjust session timeouts
2. Configure MFA for admin services
3. Set up proper access control rules
4. Enable monitoring and alerting

### Rollback Plan
If issues occur:
```bash
# Remove SecurityPolicy from affected service
kubectl delete securitypolicy <policy-name> -n <namespace>

# Service will be immediately accessible without auth
# This doesn't affect Authelia or LLDAP deployments
```

## Maintenance

### Regular Tasks

**Weekly**:
- Review failed authentication logs
- Check Authelia and LLDAP resource usage

**Monthly**:
- Review and update access control rules
- Audit user and group memberships
- Check for Authelia updates

**Quarterly**:
- Rotate secrets (JWT, session, encryption keys)
- Review and test backup/recovery procedures
- Update Authelia and LLDAP to latest stable versions

### Updating Authelia

```bash
# Update HelmRelease image tag
# Flux will automatically roll out the update

# Monitor rollout
kubectl rollout status deployment/authelia -n auth

# Verify health
kubectl get pods -n auth
kubectl logs -n auth -l app.kubernetes.io/name=authelia
```

### Updating LLDAP

```bash
# Same process as Authelia
# LLDAP updates are typically backwards compatible
# Check LLDAP release notes for breaking changes
```

## References

### Official Documentation
- **Authelia**: https://www.authelia.com/
  - Envoy Integration: https://www.authelia.com/integration/proxies/envoy/
  - LDAP Backend: https://www.authelia.com/configuration/first-factor/ldap/
- **LLDAP**: https://github.com/lldap/lldap
- **Envoy Gateway**: https://gateway.envoyproxy.io/
  - SecurityPolicy: https://gateway.envoyproxy.io/latest/api/extension_types/#securitypolicy
- **Gateway API**: https://gateway-api.sigs.k8s.io/

### Community Resources
- Authelia Discord: https://discord.authelia.com
- LLDAP Discussions: https://github.com/lldap/lldap/discussions
- r/selfhosted: https://reddit.com/r/selfhosted

### Example Implementations
- Awesome Authelia: https://github.com/authelia/awesome-authelia
- Home-ops examples: Search GitHub for "authelia lldap kubernetes"

---

**Document Version**: 1.0
**Last Updated**: 2025-11-20
**Author**: Claude Code
**Environment**: home-ops Kubernetes cluster with Envoy Gateway 1.5.3
