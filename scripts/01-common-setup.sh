#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Node Ortak Kurulum Scripti
# Ubuntu 24.04 LTS - Her iki node'da calistirilacak
#
# Kullanim:
#   sudo ./01-common-setup.sh <hostname>
#   Ornek: sudo ./01-common-setup.sh cnr-intel
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
  echo "Repo kok dizininde config.env dosyasini olusturun."
  exit 1
fi

source "$CONFIG_FILE"

# -----------------------------------
# Parametre Kontrolu
# -----------------------------------
# Master bilgilerini parse et
MASTER_HOSTNAME="${MASTER_NODE%%:*}"
MASTER_IP="${MASTER_NODE##*:}"

# Tum node'lari listele (hostnamecheck icin)
ALL_HOSTNAMES="$MASTER_HOSTNAME"
for w in $WORKER_NODES; do
  ALL_HOSTNAMES="$ALL_HOSTNAMES ${w%%:*}"
done

if [ $# -lt 1 ]; then
  echo "Kullanim: sudo $0 <hostname>"
  echo ""
  echo "config.env'de tanimli node'lar:"
  echo "  Master : $MASTER_HOSTNAME ($MASTER_IP)"
  for w in $WORKER_NODES; do
    echo "  Worker : ${w%%:*} (${w##*:})"
  done
  exit 1
fi

TARGET_HOSTNAME="$1"

# Hostname'in config'de tanimli olup olmadigini kontrol et
FOUND=false
for h in $ALL_HOSTNAMES; do
  if [ "$h" = "$TARGET_HOSTNAME" ]; then
    FOUND=true
    break
  fi
done

if [ "$FOUND" = false ]; then
  echo "HATA: '$TARGET_HOSTNAME' config.env'de tanimli degil."
  echo "Tanimli hostname'ler: $ALL_HOSTNAMES"
  exit 1
fi

echo "=== Kubernetes Node Ortak Kurulum ==="
echo "Hostname    : $TARGET_HOSTNAME"
echo "Kubernetes  : $K8S_VERSION"
echo "Config      : $CONFIG_FILE"
echo ""

# -----------------------------------
# 1. Hostname Ayarla
# -----------------------------------
echo "[1/9] Hostname ayarlaniyor..."
hostnamectl set-hostname "$TARGET_HOSTNAME"
echo "Hostname '$TARGET_HOSTNAME' olarak ayarlandi."

# -----------------------------------
# 2. /etc/hosts Dosyasini Guncelle
# -----------------------------------
echo "[2/9] /etc/hosts guncelleniyor..."

if ! grep -q "$MASTER_HOSTNAME" /etc/hosts; then
  {
    echo ""
    echo "# Kubernetes Cluster Nodes"
    echo "$MASTER_IP  $MASTER_HOSTNAME"
    for w in $WORKER_NODES; do
      W_HOSTNAME="${w%%:*}"
      W_IP="${w##*:}"
      echo "$W_IP  $W_HOSTNAME"
    done
  } >> /etc/hosts
  echo "/etc/hosts guncellendi."
else
  echo "/etc/hosts zaten guncel."
fi

# -----------------------------------
# 3. Swap Kapat
# -----------------------------------
echo "[3/9] Swap kapatiliyor..."
swapoff -a
sed -i '/[[:space:]]swap[[:space:]]/ s/^\(.*\)$/#\1/' /etc/fstab
echo "Swap kapatildi."

# -----------------------------------
# 4. Kernel Modulleri
# -----------------------------------
echo "[4/9] Kernel modulleri yukleniyor..."
modprobe overlay
modprobe br_netfilter

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
echo "Kernel modulleri yuklendi."

# -----------------------------------
# 5. Sysctl Ayarlari (IP Forwarding)
# -----------------------------------
echo "[5/9] Sysctl ayarlari yapiliyor..."
cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null 2>&1
echo "Sysctl ayarlari tamamlandi."

# -----------------------------------
# 6. containerd Kurulumu
# -----------------------------------
echo "[6/9] containerd kuruluyor..."

# containerd bagimliliklari
apt-get update -qq
apt-get install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates

# Docker GPG key ekle
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Docker repo ekle (arch otomatik: amd64 veya arm64)
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y containerd.io

# containerd yapilandirma: SystemdCgroup aktif et
containerd config default | tee /etc/containerd/config.toml > /dev/null 2>&1
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
echo "containerd kuruldu ve yapilandirildi."

# -----------------------------------
# 7. kubeadm, kubelet, kubectl Kurulumu
# -----------------------------------
echo "[7/9] Kubernetes bilesenleri kuruluyor ($K8S_VERSION)..."

# Kubernetes GPG key
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/k8s.gpg

# Kubernetes repo
echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | \
  tee /etc/apt/sources.list.d/k8s.list

apt-get update -qq
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
echo "kubeadm, kubelet, kubectl kuruldu ($K8S_VERSION)."

# -----------------------------------
# 8. Tailscale Kurulumu
# -----------------------------------
if [ "$INSTALL_TAILSCALE" = "true" ]; then
  echo "[8/9] Tailscale kuruluyor..."
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "Tailscale kuruldu. Baglanmak icin: sudo tailscale up"
else
  echo "[8/9] Tailscale kurulumu atlanıyor (INSTALL_TAILSCALE=false)"
fi

# -----------------------------------
# 9. Longhorn Onkosullari
# -----------------------------------
echo "[9/9] Longhorn onkosullari kuruluyor..."
apt-get install -y open-iscsi nfs-common
systemctl enable --now iscsid
echo "Longhorn onkosullari kuruldu."

# -----------------------------------
# Ozet
# -----------------------------------
echo ""
echo "=== Kurulum Tamamlandi ==="
echo "Hostname        : $TARGET_HOSTNAME"
echo "Kubernetes      : $K8S_VERSION"
echo "containerd      : $(containerd --version 2>/dev/null | awk '{print $3}' || echo 'kurulu')"
echo "kubeadm         : $(kubeadm version -o short 2>/dev/null || echo 'kurulu')"
echo ""
echo "Sonraki adim:"
echo "  Master ($MASTER_HOSTNAME): sudo ./02-master-init.sh"
echo "  Worker: kubeadm join komutu (master'dan alinacak)"
