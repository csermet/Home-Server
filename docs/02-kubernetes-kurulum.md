# Kubernetes Cluster Kurulumu (kubeadm)

## Onkosullar

- Her iki node'da Ubuntu 24.04 LTS kurulu
- SSH erisimi aktif
- Statik IP'ler atanmis (cnr-intel: 192.168.1.120, cnr-raspberry: 192.168.1.121)

---

## Adim 1: Ortak Setup (Her Iki Node)

Her iki node'da `scripts/01-common-setup.sh` scriptini calistir:

```bash
# Repo'yu node'a kopyala (config.env dahil)
scp -r . caner@cnr-intel:~/home-server/
scp -r . caner@cnr-raspberry:~/home-server/

# Her node'da hostname parametresiyle calistir
ssh cnr-intel "cd ~/home-server && chmod +x scripts/*.sh && sudo scripts/01-common-setup.sh cnr-intel"
ssh cnr-raspberry "cd ~/home-server && chmod +x scripts/*.sh && sudo scripts/01-common-setup.sh cnr-raspberry"
```

> NOT: Script `config.env` dosyasini repo kok dizininden okur. Bu yuzden tum repo kopyalanmali.

Script su islemleri yapar:
- Hostname ayarlama (hostnamectl)
- /etc/hosts guncelleme (her iki node'un IP/hostname'i)
- Swap kapatma
- Kernel modulleri yukleme (overlay, br_netfilter)
- Sysctl ayarlari (ip_forward, bridge-nf-call)
- containerd kurulumu (bagimliliklariyla birlikte)
- kubeadm, kubelet, kubectl kurulumu (v1.34)
- Tailscale kurulumu
- Longhorn onkosullari (open-iscsi, nfs-common)

---

## Adim 2: Master Node Init (cnr-intel)

```bash
ssh cnr-intel
cd ~/home-server
sudo scripts/02-master-init.sh
```

veya manuel:

```bash
# Cluster'i baslat
sudo kubeadm init \
  --control-plane-endpoint=cnr-intel \
  --apiserver-advertise-address=192.168.1.120 \
  --pod-network-cidr=10.244.0.0/16 \
  --node-name=cnr-intel

# kubeconfig ayarla
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Master node'un pod schedule edebilmesi icin taint kaldir
kubectl taint nodes cnr-intel node-role.kubernetes.io/control-plane:NoSchedule-
```

### Calico CNI Kur

```bash
kubectl apply -f infrastructure/calico/calico.yaml
```

> NOT: Calico config'de `IP_AUTODETECTION_METHOD: interface=eth0,eno1,enp.*` ayari var.
> Bu, Tailscale interface'inin (tailscale0) yerine fiziksel NIC'in kullanilmasini saglar.

Calico pod'larinin hazir olmasini bekle:
```bash
kubectl get pods -n kube-system -l k8s-app=calico-node -w
```

### MetalLB Kur

```bash
# MetalLB manifest'ini uygula
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml

# MetalLB pod'larinin hazir olmasini bekle
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# IP pool ve L2 advertisement (02-master-init.sh config.env'den otomatik olusturur)
```

### Longhorn Kur

```bash
# Longhorn onkosullari zaten 01-common-setup.sh ile kuruldu
# Helm ile kur
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --values infrastructure/longhorn/longhorn-values.yaml
```

### Join Token'i Al

```bash
# Worker node icin join komutu olustur
kubeadm token create --print-join-command
```

Bu komutu not al, cnr-raspberry'de kullanilacak.

---

## Adim 3: Worker Node Join (cnr-raspberry)

```bash
ssh cnr-raspberry

# Master'dan alinan join komutunu calistir
sudo kubeadm join cnr-intel:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --node-name=cnr-raspberry
```

---

## Adim 4: Dogrulama

Master node'da (cnr-intel):

```bash
# Node'lari kontrol et
kubectl get nodes
# Beklenen: cnr-intel Ready, cnr-raspberry Ready

# Tum pod'lari kontrol et
kubectl get pods -A
# Tum pod'lar Running olmali

# Calico durumu
kubectl get pods -n kube-system -l k8s-app=calico-node

# MetalLB durumu
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system

# Longhorn durumu
kubectl get pods -n longhorn-system
```

---

## Adim 5: Tailscale Baglantisi

Her iki node'da Tailscale'i bagla:
```bash
sudo tailscale up
```

Windows bilgisayardan uzaktan erisim icin kubeconfig'i kopyala:
```bash
# cnr-intel'den kubeconfig al
scp cnr-intel:~/.kube/config ~/.kube/config-home

# Tailscale IP'si ile kullanmak icin server adresini degistir
# config-home icinde server: https://100.x.x.x:6443 yap
```

---

## Sonraki Adim

Kubernetes cluster hazir olduktan sonra DevOps stack'ini deploy et.
Bkz: [03-helmfile-deploy.md](03-helmfile-deploy.md)
