#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Worker Node Join Scripti
# Worker node uzerinde calistirilacak
#
# Kullanim:
#   sudo ./03-worker-join.sh --token <token> --discovery-token-ca-cert-hash sha256:<hash>
#
# Master'dan join komutunu almak icin:
#   ssh <master> 'kubeadm token create --print-join-command'
#
# config.env dosyasindan konfigurasyonu okur.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_DIR/config.env"

# -----------------------------------
# Config Dosyasini Oku
# -----------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  echo "HATA: config.env bulunamadi: $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

MASTER_HOSTNAME="${MASTER_NODE%%:*}"
MASTER_PORT="6443"

# Bu makinenin hostname'ini al
NODE_NAME="$(hostname)"

if [ $# -lt 2 ]; then
  echo "Kullanim: sudo $0 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
  echo ""
  echo "Join argmanlarini master node'dan al:"
  echo "  ssh $MASTER_HOSTNAME 'kubeadm token create --print-join-command'"
  exit 1
fi

echo "=== Worker Node Join ==="
echo "Master  : $MASTER_HOSTNAME:$MASTER_PORT"
echo "Bu Node : $NODE_NAME"
echo ""

kubeadm join "$MASTER_HOSTNAME:$MASTER_PORT" \
  --node-name="$NODE_NAME" \
  "$@"

echo ""
echo "=== Worker Node Join Tamamlandi ==="
echo ""
echo "Master node'da dogrula:"
echo "  kubectl get nodes"
