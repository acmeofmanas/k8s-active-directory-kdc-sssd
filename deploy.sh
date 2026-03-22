#!/bin/bash
# deploy.sh — Full deployment of dual Samba AD DCs + SSSD clients
# Usage: ./deploy.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wait_for_dc() {
    local ns=$1
    local label="app=samba-ad-dc"
    echo "  Waiting for DC in namespace ${ns} to be ready..."
    kubectl rollout status deployment/samba-ad-dc -n "${ns}" --timeout=300s
    # Extra wait for Samba to fully provision (keytab, users, SPNs)
    local pod
    pod=$(kubectl get pod -n "${ns}" -l "${label}" -o jsonpath='{.items[0].metadata.name}')
    local attempts=0
    until kubectl exec -n "${ns}" "${pod}" -- test -f /tmp/sssd.keytab 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "${attempts}" -gt 30 ]; then
            echo "  ERROR: keytab not found after 150s in ${ns}"
            exit 1
        fi
        echo "  Waiting for keytab export in ${ns}... (${attempts}/30)"
        sleep 5
    done
    echo "  DC in ${ns} is ready."
}

extract_keytab() {
    local ns=$1
    local tmpfile
    tmpfile=$(mktemp)
    local pod
    pod=$(kubectl get pod -n "${ns}" -l "app=samba-ad-dc" -o jsonpath='{.items[0].metadata.name}')
    echo "  Extracting keytab from ${pod} in ${ns}..."
    kubectl exec -n "${ns}" "${pod}" -- cat /tmp/sssd.keytab > "${tmpfile}"
    kubectl create secret generic sssd-keytab \
        -n "${ns}" \
        --from-file=sssd.keytab="${tmpfile}" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -f "${tmpfile}"
    echo "  Secret sssd-keytab created in ${ns}."
}

echo "==> Step 1: Creating namespaces..."
kubectl apply -f "${SCRIPT_DIR}/namespaces.yaml"

echo ""
echo "==> Step 2: Deploying Samba AD DCs..."
kubectl apply -f "${SCRIPT_DIR}/ad-east/samba-dc.yaml"
kubectl apply -f "${SCRIPT_DIR}/ad-west/samba-dc.yaml"

echo ""
echo "==> Step 3: Waiting for both DCs to provision (users, keytabs, SPNs)..."
wait_for_dc "ad-east"
wait_for_dc "ad-west"

echo ""
echo "==> Step 4: Extracting keytabs and creating Secrets..."
extract_keytab "ad-east"
extract_keytab "ad-west"

echo ""
echo "==> Step 5: Deploying SSSD clients..."
kubectl apply -f "${SCRIPT_DIR}/ad-east/sssd-client.yaml"
kubectl apply -f "${SCRIPT_DIR}/ad-west/sssd-client.yaml"

echo ""
echo "==> Step 6: Waiting for SSSD clients to be ready..."
kubectl rollout status deployment/sssd-client -n ad-east --timeout=300s
kubectl rollout status deployment/sssd-client -n ad-west --timeout=300s

echo ""
echo "======================================================"
echo " Deployment complete!"
echo ""
echo " Verify EAST:"
echo "   kubectl exec -n ad-east deploy/sssd-client -- getent passwd manas"
echo "   kubectl exec -n ad-east deploy/sssd-client -- id manas"
echo ""
echo " Verify WEST:"
echo "   kubectl exec -n ad-west deploy/sssd-client -- getent passwd manas"
echo "   kubectl exec -n ad-west deploy/sssd-client -- id manas"
echo "======================================================"
