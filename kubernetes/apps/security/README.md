# Security Namespace

This namespace contains authentication and identity management services for the cluster.

## Services

### LLDAP
Lightweight LDAP directory for user and group management.

- **URL**: https://lldap.phekno.io
- **Service**: `lldap.security.svc.cluster.local`
- **Ports**:
  - HTTP UI: 17170
  - LDAP: 389
- **Base DN**: `dc=phekno,dc=io`
- **Storage**: 1Gi Longhorn PVC

**Default Structure**:
- Users: `ou=people,dc=phekno,dc=io`
- Groups: `ou=groups,dc=phekno,dc=io`
- Admin user: `uid=admin,ou=people,dc=phekno,dc=io`

### Authelia
Single sign-on and authentication portal with multi-factor authentication support.

- **URL**: https://auth.phekno.io
- **Service**: `authelia.security.svc.cluster.local:9091`
- **Replicas**: 2 (HA)
- **Database**: PostgreSQL (CloudNativePG in `db` namespace)
- **LDAP Backend**: LLDAP
- **Session Storage**: PostgreSQL
- **Metrics**: Exposed on port 9959 (ServiceMonitor configured)

## Prerequisites

Before deploying, you must create secrets in 1Password:

### 1. LLDAP Secret (`lldap`)

Create a 1Password item named `lldap` with the following fields:

```
jwt_secret: <random 64-char hex string>
admin_password: <strong admin password>
```

Generate secrets:
```bash
# JWT secret (64 hex chars)
openssl rand -hex 32

# Admin password (strong random password)
openssl rand -base64 32
```

### 2. Authelia Secret (`authelia`)

Create a 1Password item named `authelia` with the following fields:

```
jwt_secret: <random 64-char hex string>
session_secret: <random 64-char hex string>
storage_encryption_key: <random 64-char hex string>
ldap_password: <same as LLDAP admin_password>
db_password: <database password for authelia user>
db_superuser_password: <postgres superuser password>
```

Generate secrets:
```bash
# JWT, session, and encryption secrets
openssl rand -hex 32  # Run 3 times for each secret
```

**Note**: The `ldap_password` should match the LLDAP `admin_password`. The database passwords should match your PostgreSQL configuration.

## Deployment Order

Flux will automatically deploy in the correct order based on dependencies:

1. **LLDAP** - Deployed first (depends on external-secrets)
2. **Authelia** - Deployed after LLDAP and CloudNativePG

## Initial Setup

### 1. Create Users and Groups in LLDAP

After LLDAP is deployed, access the web UI at https://lldap.phekno.io:

1. Login with `admin` and the password from 1Password
2. Create groups:
   - `admins` - Full cluster access with 2FA
   - `users` - Standard user access
   - `monitoring` - Access to monitoring services
3. Create users and assign to groups
4. Configure email addresses for password reset

### 2. Configure Access Control in Authelia

Access control rules are defined in `authelia/app/configmap.yaml`. Default rules:

- **Bypass** (no auth): `auth.phekno.io`, `echo.phekno.io`
- **2FA required** (admins only): Grafana, Prometheus, AlertManager, Longhorn
- **1FA required**: All other `*.phekno.io` services

To modify rules, edit the ConfigMap and commit changes.

### 3. Protect Services

To add authentication to a service, add the `ext-auth` component to its kustomization:

```yaml
# Example: kubernetes/apps/monitoring/grafana/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
components:
  - ../../../components/ext-auth  # Add this line
resources:
  - ./helmrelease.yaml
```

See [ext-auth component documentation](../../../components/ext-auth/README.md) for details.

## Testing

### Test LLDAP

```bash
# Test LDAP connectivity
kubectl run -it --rm ldapsearch --image=alpine/openldap-client --restart=Never -- \
  ldapsearch -x -H ldap://lldap.security.svc.cluster.local:389 \
  -D "uid=admin,ou=people,dc=phekno,dc=io" \
  -w "YOUR_ADMIN_PASSWORD" \
  -b "dc=phekno,dc=io" \
  "(objectClass=person)"
```

### Test Authelia

```bash
# Check health
kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl -s http://authelia.security.svc.cluster.local:9091/api/health

# Check metrics
kubectl port-forward -n security svc/authelia 9959:9959
curl http://localhost:9959/metrics
```

### Test Authentication Flow

1. Access a protected service (e.g., https://grafana.phekno.io)
2. Should redirect to https://auth.phekno.io
3. Login with LLDAP credentials
4. Should redirect back to Grafana with session cookie
5. Subsequent requests should not require re-authentication

## Troubleshooting

### LLDAP won't start

```bash
# Check pod logs
kubectl logs -n security -l app.kubernetes.io/name=lldap

# Check PVC
kubectl get pvc -n security

# Check external secret
kubectl get externalsecret -n security lldap
kubectl describe externalsecret -n security lldap
```

### Authelia won't start

```bash
# Check init container (database creation)
kubectl logs -n security -l app.kubernetes.io/name=authelia -c init-db

# Check main container
kubectl logs -n security -l app.kubernetes.io/name=authelia -c app

# Check PostgreSQL connection
kubectl exec -it -n security deploy/authelia -c app -- \
  nc -zv postgres-rw.db.svc.cluster.local 5432
```

### Authentication not working

```bash
# Check SecurityPolicy
kubectl get securitypolicy -A

# Check HTTPRoute has the policy
kubectl describe httproute -n <namespace> <app>

# Check Authelia logs for auth decisions
kubectl logs -n security -l app.kubernetes.io/name=authelia -c app | grep -i auth
```

## References

- [Authelia Documentation](https://www.authelia.com/)
- [LLDAP Documentation](https://github.com/lldap/lldap)
- [Full Integration Guide](../../../docs/authelia-lldap-integration.md)
