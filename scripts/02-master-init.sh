#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Master Node Kurulum Scripti
# Master node uzerinde calistirilacak
# Root olarak calistir: sudo ./02-master-init.sh
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

# Config'den degerleri parse et
MASTER_HOSTNAME="${MASTER_NODE%%:*}"
MASTER_IP="${MASTER_NODE##*:}"

echo "=== Kubernetes Master Node Kurulumu ==="
echo "Master      : $MASTER_HOSTNAME ($MASTER_IP)"
echo "Pod CIDR    : $POD_CIDR"
echo "MetalLB     : $METALLB_VERSION"
echo "MetalLB Pool: $METALLB_POOL_START - $METALLB_POOL_END"
echo ""

# -----------------------------------
# 1. kubeadm init
# -----------------------------------
echo "[1/6] kubeadm init calistiriliyor..."
kubeadm init \
  --control-plane-endpoint="$MASTER_HOSTNAME" \
  --apiserver-advertise-address="$MASTER_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --node-name="$MASTER_HOSTNAME"

# -----------------------------------
# 2. kubeconfig Ayarla
# -----------------------------------
echo "[2/6] kubeconfig ayarlaniyor..."
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

mkdir -p "$REAL_HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$REAL_HOME/.kube/config"
chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube/config"

export KUBECONFIG="$REAL_HOME/.kube/config"
echo "kubeconfig ayarlandi: $REAL_HOME/.kube/config"

# -----------------------------------
# 3. Control-plane Taint Kaldir
# -----------------------------------
echo "[3/6] Control-plane taint kaldiriliyor (master'a da pod schedule edilebilsin)..."
sudo -u "$REAL_USER" kubectl taint nodes "$MASTER_HOSTNAME" node-role.kubernetes.io/control-plane:NoSchedule- || true
echo "Taint kaldirildi."

# -----------------------------------
# 4. Calico CNI Kur
# -----------------------------------
echo "[4/6] Calico CNI kuruluyor..."
sudo -u "$REAL_USER" kubectl apply -f "$REPO_DIR/infrastructure/calico/calico.yaml"

echo "Calico pod'larinin olusmasini bekleniyor..."
until sudo -u "$REAL_USER" kubectl get pods -n kube-system -l k8s-app=calico-node 2>/dev/null | grep -q "calico"; do
  sleep 2
done
echo "Calico pod'lari olustu, hazir olmasi bekleniyor..."
sudo -u "$REAL_USER" kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=k8s-app=calico-node \
  --timeout=120s
echo "Calico hazir."

# -----------------------------------
# 5. MetalLB Kur
# -----------------------------------
echo "[5/6] MetalLB kuruluyor ($METALLB_VERSION)..."

sudo -u "$REAL_USER" kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"

echo "MetalLB pod'larinin olusmasini bekleniyor..."
until sudo -u "$REAL_USER" kubectl get pods -n metallb-system -l app=metallb 2>/dev/null | grep -q "metallb"; do
  sleep 2
done
echo "MetalLB pod'lari olustu, hazir olmasi bekleniyor..."
sudo -u "$REAL_USER" kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

# MetalLB IPAddressPool - config'den generate et
sudo -u "$REAL_USER" kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_POOL_START}-${METALLB_POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF
echo "MetalLB kuruldu. IP pool: $METALLB_POOL_START-$METALLB_POOL_END"

# -----------------------------------
# 6. Join Token Olustur
# -----------------------------------
echo ""
echo "[6/6] Worker join komutu olusturuluyor..."

JOIN_CMD=$(kubeadm token create --print-join-command)
TOKEN=$(echo "$JOIN_CMD" | grep -oP '(?<=--token )\S+')
HASH=$(echo "$JOIN_CMD" | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')

echo ""
echo "=============================================="
echo "WORKER JOIN KOMUTLARI:"
echo "=============================================="
for w in $WORKER_NODES; do
  W_HOSTNAME="${w%%:*}"
  echo ""
  echo "--- $W_HOSTNAME ---"
  echo "sudo kubeadm join $MASTER_HOSTNAME:6443 \\"
  echo "  --token $TOKEN \\"
  echo "  --discovery-token-ca-cert-hash $HASH \\"
  echo "  --node-name=$W_HOSTNAME"
done
echo ""
echo "=============================================="

# -----------------------------------
# Dogrulama
# -----------------------------------
echo ""
echo "=== Master Node Kurulumu Tamamlandi ==="
echo ""
echo "Node durumu:"
sudo -u "$REAL_USER" kubectl get nodes
echo ""
echo "Sistem pod'lari:"
sudo -u "$REAL_USER" kubectl get pods -A
echo ""
echo "Sonraki adimlar:"
echo "  1. Yukardaki join komutlarini worker node'larda calistir"
echo "  2. Longhorn'u kur (bkz: docs/02-kubernetes-kurulum.md)"
echo "  3. cd helmfile && helmfile sync"
