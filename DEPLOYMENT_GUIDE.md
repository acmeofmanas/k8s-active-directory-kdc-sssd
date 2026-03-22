# Deployment and Testing Guide

## Overview

This guide walks through deploying two independent Samba Active Directory Domain Controllers
(EAST.LOCAL and WEST.LOCAL) in Kubernetes, each paired with an SSSD client that authenticates
via Kerberos GSSAPI. All user/group lookups on the SSSD client side flow through the AD DC.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Kubernetes cluster | 1.24+ | minikube, kind, or any cluster |
| kubectl | any | configured and pointing at your cluster |
| gh (GitHub CLI) | any | only needed if re-cloning this repo |
| Cluster nodes | privileged pods allowed | containers run with `privileged: true` |

### Minikube (recommended for local testing)

```bash
# 3-node cluster with Docker driver
minikube start --driver=docker --nodes=3 --cpus=2 --memory=3g
```

---

## Step 1 — Clone the Repo

```bash
gh repo clone acmeofmanas/k8s-active-directory-kdc-sssd
cd k8s-active-directory-kdc-sssd
```

---

## Step 2 — Deploy Everything (Automated)

```bash
chmod +x deploy.sh
./deploy.sh
```

The script does the following in order:

1. Creates namespaces `ad-east` and `ad-west`
2. Deploys Samba AD DCs in both namespaces
3. Waits for each DC to fully provision (domain, users, SPNs, keytab)
4. Copies the `sssd-svc` keytab from each DC pod into a Kubernetes Secret (`sssd-keytab`)
5. Deploys SSSD client containers (which mount the keytab Secret)
6. Waits for SSSD clients to reach Running state

Expected duration: **3–5 minutes** (dominated by `apt-get` inside the DC containers).

---

## Step 3 — Verify the DCs are Healthy

```bash
# Check all pods are Running
kubectl get pods -n ad-east
kubectl get pods -n ad-west
```

Expected output:
```
NAME                           READY   STATUS    RESTARTS
samba-ad-dc-<hash>             1/1     Running   0
sssd-client-<hash>             1/1     Running   0
```

Confirm the DC has a working domain:

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- \
  samba-tool domain info 127.0.0.1
```

Expected: output includes `Forest` and `Domain` lines for `EAST.LOCAL`.

---

## Step 4 — Verify Kerberos Authentication on the DC

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- bash -c '
  echo "Admin@East1234!" | kinit Administrator@EAST.LOCAL
  klist
'
```

Expected: a Kerberos TGT for `Administrator@EAST.LOCAL` with a valid expiry.

---

## Step 5 — Verify GSSAPI ldapsearch from the DC Pod

This confirms the DC's LDAP service is queryable via Kerberos and all users are present.

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- bash -c '
  echo "Admin@East1234!" | kinit Administrator@EAST.LOCAL
  ldapsearch \
    -H ldap://dc1.east.local \
    -Y GSSAPI \
    -b "DC=east,DC=local" \
    "(objectClass=user)" sAMAccountName 2>&1 \
    | grep sAMAccountName
'
```

Expected users: `Administrator`, `krbtgt`, `Guest`, `sssd-svc`, `manas`, `tapas`, `bhavya`.

Repeat for WEST:

```bash
kubectl exec -n ad-west deploy/samba-ad-dc -- bash -c '
  echo "Admin@West1234!" | kinit Administrator@WEST.LOCAL
  ldapsearch \
    -H ldap://dc1.west.local \
    -Y GSSAPI \
    -b "DC=west,DC=local" \
    "(objectClass=user)" sAMAccountName 2>&1 \
    | grep sAMAccountName
'
```

---

## Step 6 — Verify SSSD Client Syncs Users from AD

```bash
# List all AD users visible via NSS
kubectl exec -n ad-east deploy/sssd-client -- getent passwd

# Look up a specific user
kubectl exec -n ad-east deploy/sssd-client -- id manas

# List all groups
kubectl exec -n ad-east deploy/sssd-client -- getent group

# Verify users_grp membership
kubectl exec -n ad-east deploy/sssd-client -- getent group users_grp
```

Expected `id manas` output:
```
uid=<number>(manas) gid=<number> groups=<number>(manas),<number>(users_grp)
```

---

## Step 7 — Check SSSD Domain Status

```bash
kubectl exec -n ad-east deploy/sssd-client -- \
  sssctl domain-status east.local
```

Expected: `Online status: Online`

---

## Common Operations

### Add a New User to AD

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- \
  samba-tool user create newuser 'NewUser@East1234!'
```

Then force SSSD to refresh its cache on the client:

```bash
kubectl exec -n ad-east deploy/sssd-client -- \
  sss_cache -E
kubectl exec -n ad-east deploy/sssd-client -- \
  id newuser
```

### Add a User to a Group

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- \
  samba-tool group addmembers users_grp newuser
```

### List All SPNs on the DC

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- \
  samba-tool spn list 'DC1$'
```

### Reset a User Password

```bash
kubectl exec -n ad-east deploy/samba-ad-dc -- \
  samba-tool user setpassword manas --newpassword='NewPass@1234!'
```

---

## Troubleshooting

### Pod stuck in CrashLoopBackOff

Check startup logs:

```bash
kubectl logs -n ad-east deploy/sssd-client --previous
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `No worthy mechs found` | `libsasl2-modules-gssapi-mit` missing | Already included in YAML; rebuild pod |
| `Server not found in Kerberos database` | GSSAPI reverse-DNS resolved wrong hostname | `rdns = false` is in krb5.conf; verify ConfigMap |
| `Cannot find KDC` | krb5.conf KDC points to DNS name that doesn't resolve | krb5.conf uses explicit service DNS; check DC pod is Running |
| `keytab not found` | deploy.sh ran before DC finished provisioning | Re-run `./deploy.sh` — it waits for keytab automatically |

### SSSD not returning users (getent returns nothing)

```bash
# Check SSSD is running inside the client pod
kubectl exec -n ad-east deploy/sssd-client -- pgrep -a sssd

# Force cache invalidation
kubectl exec -n ad-east deploy/sssd-client -- sss_cache -E

# Check SSSD logs
kubectl logs -n ad-east deploy/sssd-client | tail -50
```

### Kerberos clock skew error

Kerberos requires clocks to be within 5 minutes. In minikube:

```bash
# Check node time
minikube ssh -- date
date
```

If skewed, restart minikube or sync clocks.

### Re-deploy from scratch

```bash
kubectl delete namespace ad-east ad-west
kubectl apply -f namespaces.yaml
./deploy.sh
```

---

## Architecture Notes

### Why GSSAPI instead of simple LDAP bind?

Samba 4 by default requires either TLS or GSSAPI for LDAP operations. Simple bind over
plain LDAP is rejected. GSSAPI with a keytab is the correct enterprise approach and mirrors
how real Linux systems join Active Directory domains.

### Why rdns = false?

When GSSAPI connects to `samba-ad-dc.ad-east.svc.cluster.local`, it normally:
1. Forward-resolves the name to the Kubernetes ClusterIP
2. Reverse-resolves the IP to get the "canonical" hostname
3. Constructs the SPN from the canonical hostname

In Kubernetes, the reverse DNS of a pod IP gives the pod FQDN
(`dc1.samba-ad-dc.ad-east.svc.cluster.local`), not the service name. This causes GSSAPI
to look for `ldap/dc1.samba-ad-dc.ad-east.svc.cluster.local@EAST.LOCAL`, which may not be
registered. Setting `rdns = false` skips the reverse lookup and uses the hostname as provided.

### Keytab flow

```
DC startup script
  └─ samba-tool domain exportkeytab /tmp/sssd.keytab --principal sssd-svc@EAST.LOCAL
        │
deploy.sh (after DC ready)
  └─ kubectl exec ... cat /tmp/sssd.keytab > local file
  └─ kubectl create secret generic sssd-keytab --from-file=sssd.keytab=...
        │
sssd-client pod
  └─ volume mount: Secret sssd-keytab → /etc/sssd/sssd.keytab (mode 0600)
  └─ SSSD uses keytab for GSSAPI bind to LDAP
```
