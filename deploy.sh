#!/bin/bash
# deploy.sh — Full deployment of dual Samba AD DCs + SSSD clients
# Usage: ./deploy.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wait_for_dc() {
    local ns=$1
    echo "  Waiting for DC in namespace ${ns} to be ready..."
    kubectl rollout status deployment/samba-ad-dc -n "${ns}" --timeout=300s
    local pod
    pod=$(kubectl get pod -n "${ns}" -l "app=samba-ad-dc" -o jsonpath='{.items[0].metadata.name}')
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
    local src_ns=$1      # namespace where the DC lives
    local dest_ns=$2     # namespace where the Secret is created
    local secret_name=$3 # name for the K8s Secret
    local tmpfile
    tmpfile=$(mktemp)
    local pod
    pod=$(kubectl get pod -n "${src_ns}" -l "app=samba-ad-dc" -o jsonpath='{.items[0].metadata.name}')
    echo "  Extracting keytab from ${pod} (${src_ns}) → Secret '${secret_name}' in ${dest_ns}..."
    kubectl exec -n "${src_ns}" "${pod}" -- cat /tmp/sssd.keytab > "${tmpfile}"
    kubectl create secret generic "${secret_name}" \
        -n "${dest_ns}" \
        --from-file=sssd.keytab="${tmpfile}" \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -f "${tmpfile}"
    echo "  Done: Secret '${secret_name}' in ${dest_ns}."
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
# Each DC's keytab in its own namespace (used by the single-domain SSSD client in ad-west)
extract_keytab "ad-east" "ad-east" "sssd-keytab"
extract_keytab "ad-west" "ad-west" "sssd-keytab"

# Cross-namespace: west keytab also placed in ad-east for the multi-domain SSSD client
extract_keytab "ad-west" "ad-east" "sssd-keytab-west"

echo ""
echo "==> Step 5: Deploying SSSD clients..."
# ad-east: multi-domain client (syncs EAST.LOCAL + WEST.LOCAL)
kubectl apply -f "${SCRIPT_DIR}/ad-east/sssd-client.yaml"
# ad-west: single-domain client (syncs WEST.LOCAL only)
kubectl apply -f "${SCRIPT_DIR}/ad-west/sssd-client.yaml"

echo ""
echo "==> Step 6: Waiting for SSSD clients to be ready..."
kubectl rollout status deployment/sssd-client -n ad-east --timeout=300s
kubectl rollout status deployment/sssd-client -n ad-west --timeout=300s

echo ""
echo "======================================================"
echo " Deployment complete!"
echo ""
echo " Multi-domain client (ad-east) — syncs EAST + WEST:"
echo "   kubectl exec -n ad-east deploy/sssd-client -- getent passwd"
echo "   kubectl exec -n ad-east deploy/sssd-client -- id manas"
echo "   kubectl exec -n ad-east deploy/sssd-client -- sssctl domain-status east.local"
echo "   kubectl exec -n ad-east deploy/sssd-client -- sssctl domain-status west.local"
echo ""
echo " Single-domain client (ad-west) — syncs WEST only:"
echo "   kubectl exec -n ad-west deploy/sssd-client -- getent passwd"
echo "   kubectl exec -n ad-west deploy/sssd-client -- id manas"
echo "======================================================"
