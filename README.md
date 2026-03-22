# Kubernetes Active Directory Lab

Two independent Samba 4 Active Directory Domain Controllers running in Kubernetes,
each with an SSSD client container authenticating via **Kerberos GSSAPI**.

## Architecture

```
Namespace: ad-east                      Namespace: ad-west
┌─────────────────────────────┐         ┌─────────────────────────────┐
│  samba-ad-dc (Deployment)   │         │  samba-ad-dc (Deployment)   │
│  Realm:  EAST.LOCAL         │         │  Realm:  WEST.LOCAL         │
│  Domain: EAST               │         │  Domain: WEST               │
│  Users:  manas, tapas,      │         │  Users:  manas, tapas,      │
│          bhavya, sssd-svc   │         │          bhavya, sssd-svc   │
│  Group:  users_grp          │         │  Group:  users_grp          │
│  Service: samba-ad-dc:389   │         │  Service: samba-ad-dc:389   │
└──────────────┬──────────────┘         └──────────────┬──────────────┘
               │ Kerberos GSSAPI                       │ Kerberos GSSAPI
               │ (keytab: sssd-svc)                    │ (keytab: sssd-svc)
┌──────────────▼──────────────┐         ┌──────────────▼──────────────┐
│  sssd-client (Deployment)   │         │  sssd-client (Deployment)   │
│  SSSD → LDAP + KRB5         │         │  SSSD → LDAP + KRB5         │
│  getent passwd / id manas   │         │  getent passwd / id manas   │
└─────────────────────────────┘         └─────────────────────────────┘
```

## Files

```
k8s-active-directory/
├── deploy.sh              # One-shot deployment script
├── namespaces.yaml        # Creates ad-east and ad-west namespaces
├── ad-east/
│   ├── samba-dc.yaml      # ConfigMap, Secret, Deployment, Service for EAST DC
│   └── sssd-client.yaml   # ConfigMap (sssd.conf, krb5.conf, start.sh), Deployment
└── ad-west/
    ├── samba-dc.yaml      # Same for WEST DC
    └── sssd-client.yaml   # Same for WEST
```

## Prerequisites

- Kubernetes cluster (minikube, kind, etc.) with `kubectl` configured
- Docker Hub login (`docker login`) if pulling `ubuntu:22.04` through a private mirror

## Deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

The script:
1. Creates namespaces
2. Deploys both Samba AD DCs (provisions domain, creates users, registers SPNs, exports keytab)
3. Waits for keytab to be ready, then creates `sssd-keytab` Secrets in each namespace
4. Deploys SSSD clients (mounts keytab + config from ConfigMap/Secret)

## Key Design Decisions

### GSSAPI Authentication
SSSD authenticates to AD via **Kerberos GSSAPI** (not simple LDAP bind).
- The DC exports a keytab for `sssd-svc@{REALM}` during first-time provisioning
- `deploy.sh` copies that keytab into a Kubernetes Secret (`sssd-keytab`)
- The SSSD client mounts the keytab at `/etc/sssd/sssd.keytab` (mode 0600)

### SPN Registration
Samba's DC hostname in Kubernetes is `dc1.samba-ad-dc.{namespace}.svc.cluster.local`
(pod FQDN = `{hostname}.{subdomain}.{namespace}.svc.cluster.local`).

The DC startup script registers:
```
ldap/dc1.samba-ad-dc.{namespace}.svc.cluster.local
host/dc1.samba-ad-dc.{namespace}.svc.cluster.local
```
These allow GSSAPI from both the DC itself and external clients.

### rdns = false
All `krb5.conf` files include `rdns = false` to prevent GSSAPI from doing a
reverse DNS lookup on the server IP. Without this, Kerberos canonicalizes the
server hostname via reverse DNS and may construct the wrong SPN.

### ConfigMap-mounted configs
`sssd.conf` and `krb5.conf` are mounted directly from a ConfigMap as volume files
(with `subPath`), rather than being written in the startup script. This allows
config changes without rebuilding the image.

## Verifying SSSD Works

```bash
# List AD users from EAST
kubectl exec -n ad-east deploy/sssd-client -- getent passwd

# Look up specific user
kubectl exec -n ad-east deploy/sssd-client -- id manas

# List groups
kubectl exec -n ad-east deploy/sssd-client -- getent group users_grp

# SSSD domain status
kubectl exec -n ad-east deploy/sssd-client -- sssctl domain-status east.local
```

## Accessing the AD DC

```bash
# Get an admin Kerberos ticket
kubectl exec -n ad-east deploy/samba-ad-dc -- bash -c \
  'echo "Admin@East1234!" | kinit Administrator@EAST.LOCAL && klist'

# List all users via GSSAPI ldapsearch
kubectl exec -n ad-east deploy/samba-ad-dc -- bash -c \
  'echo "Admin@East1234!" | kinit Administrator@EAST.LOCAL && \
   ldapsearch -H ldap://dc1.east.local -Y GSSAPI \
   -b "DC=east,DC=local" "(objectClass=user)" sAMAccountName cn'
```

## Credentials

| Account       | EAST password       | WEST password       |
|---------------|---------------------|---------------------|
| Administrator | Admin@East1234!     | Admin@West1234!     |
| sssd-svc      | SssdSvc@East1234!   | SssdSvc@West1234!   |
| manas/tapas/bhavya | User@East1234! | User@West1234!      |
