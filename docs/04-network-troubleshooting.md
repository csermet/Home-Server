# Kubernetes Network Sorunları, Çözümleri ve Yeni Node Ekleme Rehberi

## Cluster Bilgileri

| Node | Donanım | IP | Interface | OS |
|------|---------|----|-----------|----|
| cnr-intel (control-plane) | i5-7600K, 16GB RAM | 192.168.1.120 | `enp0s31f6` | Ubuntu 24.04 |
| cnr-raspberry (worker) | RPi 5, 8GB RAM | 192.168.1.121 | `eth0` | Ubuntu 24.04 |

- **CNI**: Calico v3.31.4 (IPIP mode)
- **kube-proxy**: IPVS mode
- **Load Balancer**: MetalLB v0.15.3 (L2 mode, pool: 192.168.1.200-210)
- **Pod CIDR**: 10.244.0.0/16

---

## Yaşanan Sorunlar ve Çözümleri

### 1. Calico Yanlış IP Seçimi (En Kritik Sorun)

#### Belirti
- Node'lar arası pod iletişimi yok (IPIP tunnel çalışmıyor)
- Bir node'daki pod, diğer node'daki pod'a ping atamıyor
- DNS çözümlemesi çalışmıyor (CoreDNS farklı node'da ise)
- Service'lere erişilemiyor

#### Teşhis
```bash
# Her node'un Calico IP annotation'ını kontrol et
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.projectcalico\.org/IPv4Address}{"\n"}{end}'

# Doğru IP'ler olmalı:
# cnr-intel: 192.168.1.120/24
# cnr-raspberry: 192.168.1.121/24
```

#### Kök Neden
Calico'nun IP autodetection mekanizması yanlış interface'lerden IP seçiyordu:

| Yanlış IP | Nereden Geldi | Neden Sorunlu |
|-----------|---------------|---------------|
| `192.168.1.200` (Intel) | `kube-ipvs0` interface | kube-proxy IPVS mode, MetalLB VIP'lerini bu sanal interface'e bağlar |
| `192.168.1.8` (Raspberry) | `wlan0` interface | WiFi "kapalı" olsa bile interface'de IP kalabiliyor |
| `100.x.x.x` | `tailscale0` interface | Tailscale VPN IP'si |

#### Denenen Ama Başarısız Olan Yöntemler

**1. `cidr=192.168.1.0/24` yöntemi:**
- Neden çalışmadı: `kube-ipvs0` interface'inde `192.168.1.200/32` var, bu da `192.168.1.0/24` CIDR'a uyuyor
- Calico bazen kube-ipvs0'dan VIP'i seçiyordu

**2. `interface=eth.*` yöntemi:**
- Neden çalışmadı: Intel'in interface adı `enp0s31f6`, `eth0` değil
- Her donanımda interface adı farklı olabiliyor

**3. `interface=eth.*|enp.*` yöntemi:**
- Çalışabilir ama her yeni donanımda interface adını eklemeyi gerektiriyor
- Geleceğe dönük değil

#### Doğru Çözüm: `skip-interface`
```bash
kubectl set env daemonset/calico-node -n kube-system \
  IP_AUTODETECTION_METHOD="skip-interface=kube-ipvs0,tailscale0,docker0,br-.*,tunl0,wlan.*"
```

Bu yöntem "hangi interface'i kullan" yerine "hangi interface'leri KULLANMA" der:
- `kube-ipvs0` → IPVS sanal interface (MetalLB VIP'leri burada)
- `tailscale0` → Tailscale VPN
- `docker0` → Docker bridge (varsa)
- `br-.*` → Docker/container bridge'leri
- `tunl0` → Calico'nun kendi tunnel interface'i
- `wlan.*` → WiFi interface'leri (kapalı olsa bile IP tutabilir)

Geri kalan fiziksel ethernet interface'i (ne adı olursa olsun) otomatik seçilir.

#### Doğrulama
```bash
# Calico pod'larının restart etmesini bekle
kubectl get pods -n kube-system -l k8s-app=calico-node -w

# Annotation'ları kontrol et
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.projectcalico\.org/IPv4Address}{"\n"}{end}'

# Cross-node pod iletişimini test et (Intel'deki pod'dan Raspberry'deki pod'a)
kubectl exec -it <intel-pod> -- ping <raspberry-pod-ip>
kubectl exec -it <raspberry-pod> -- ping <intel-pod-ip>
```

---

### 2. kubelet Node IP Yanlış

#### Belirti
- `kubectl get nodes -o wide` komutunda INTERNAL-IP yanlış görünüyor
- metrics-server `FailedDiscoveryCheck` hatası veriyor

#### Çözüm
Her node'da `/etc/default/kubelet` dosyasını düzenle:

**cnr-intel:**
```
KUBELET_EXTRA_ARGS=--node-ip=192.168.1.120
```

**cnr-raspberry:**
```
KUBELET_EXTRA_ARGS=--node-ip=192.168.1.121
```

Sonra kubelet'i restart et:
```bash
sudo systemctl restart kubelet
```

---

### 3. MetalLB IPAddressPool Eksik

#### Belirti
- LoadBalancer type Service'ler `<pending>` durumunda kalıyor
- nginx-ingress external IP alamıyor

#### Çözüm
```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.200-192.168.1.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
```
```bash
kubectl apply -f metallb-pool.yaml
```

---

### 4. Cloudflare Tunnel Redirect Loop ve 504 Hataları

#### Belirti 1: ERR_TOO_MANY_REDIRECTS
- **Neden**: Tunnel backend `http://192.168.1.200` olarak yapılandırılmış
- nginx HTTP'yi HTTPS'e yönlendiriyor → sonsuz döngü
- **Çözüm**: Backend'i `https://` olarak ayarla + `noTLSVerify: true`

#### Belirti 2: 504 Gateway Timeout
- **Neden 1**: cloudflared pod'u MetalLB external IP'ye erişemiyor (pod içinden dış IP'ye gidiş sorunlu olabilir)
- **Çözüm**: Kubernetes internal service DNS kullan:
  ```
  https://nginx-ingress-ingress-nginx-controller.devops.svc.cluster.local:443
  ```

- **Neden 2**: Calico IPIP tunnel bozuk olduğu için cloudflared pod'u (bir node'da) nginx pod'una (diğer node'da) erişemiyor
- **Çözüm**: Calico IP autodetection fix'i (yukarıdaki #1)

---

### 5. iptables flush Yapma!

#### Kural
```
ASLA `sudo iptables --flush` YAPMA!
```

- kube-proxy (IPVS mode) ve Calico kendi iptables kurallarını yönetir
- Flush yapılırsa tüm service routing ve pod networking bozulur
- Düzeltmek için tüm node'ların restart edilmesi veya K8s'in sıfırdan kurulması gerekebilir

---

## Yeni Node Eklerken Network Checklist

Cluster'a yeni bir makina (örn. `cnr-newnode`, IP: `192.168.1.122`) eklerken network sorunu yaşamamak için:

### kubeadm join'dan ÖNCE

- [ ] **1. Statik IP ata** — DHCP kullanma, IP değişirse IPIP tunnel bozulur
  ```bash
  # /etc/netplan/ altındaki yaml'da statik IP ayarla
  ```

- [ ] **2. `/etc/default/kubelet` dosyasında node IP'yi zorla belirt**
  ```
  KUBELET_EXTRA_ARGS=--node-ip=192.168.1.122
  ```
  > Bunu ATLAMADAN yap! kubelet yanlış interface'den IP seçerse `kubectl get nodes -o wide` yanlış INTERNAL-IP gösterir ve metrics-server bozulur.

### kubeadm join'dan SONRA

- [ ] **3. Calico'nun doğru IP'yi seçtiğini kontrol et**
  ```bash
  kubectl get node cnr-newnode -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4Address}'
  # 192.168.1.122/24 olmalı — başka bir şey görüyorsan SORUN VAR
  ```
  Yanlışsa manuel düzelt:
  ```bash
  kubectl annotate node cnr-newnode projectcalico.org/IPv4Address=192.168.1.122/24 --overwrite
  kubectl delete pod -n kube-system -l k8s-app=calico-node --field-selector spec.nodeName=cnr-newnode
  ```

- [ ] **4. Yeni node'da sorunlu interface var mı kontrol et**
  ```bash
  # Yeni node'da çalıştır:
  ip -4 addr show | grep -v "127.0.0.1"
  ```
  Calico'yu yanıltabilecek interface'ler:
  - `wlan*` — WiFi kapalı olsa bile IP tutabilir
  - `kube-ipvs0` — IPVS mode'da MetalLB VIP'leri burada (join'dan sonra oluşur)
  - `tailscale0` — Tailscale VPN kuruluysa
  - `docker0`, `br-*` — Docker kuruluysa

  Yeni bir sorunlu interface varsa `skip-interface` listesine ekle:
  ```bash
  kubectl set env daemonset/calico-node -n kube-system \
    IP_AUTODETECTION_METHOD="skip-interface=kube-ipvs0,tailscale0,docker0,br-.*,tunl0,wlan.*,<yeni-interface>"
  ```
  > **DİKKAT**: Bu komut TÜM node'lardaki calico-node pod'larını restart eder. Mevcut pod iletişimi kısa süre kesilir.

- [ ] **5. Cross-node pod iletişimini test et**
  ```bash
  kubectl run test-ping --image=busybox --rm -it --restart=Never -- sh
  # Diğer node'lardaki pod IP'lerine ping at
  ping <diger-node-pod-ip>
  # DNS test
  nslookup kubernetes.default.svc.cluster.local
  ```
  Ping gitmiyorsa → Calico annotation'ı yanlış veya skip-interface eksik (adım 3-4'e dön)

### Sorun Giderme Komutları

```bash
# Calico durumu
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide

# Node IP annotation'ları
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.projectcalico\.org/IPv4Address}{"\n"}{end}'

# Calico autodetection ayarı
kubectl get daemonset calico-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool | grep -A2 IP_AUTODETECTION

# IPIP tunnel durumu
sudo calicoctl node status  # (calicoctl kuruluysa)

# kube-ipvs0 üzerindeki IP'ler (bu IP'ler Calico'yu yanıltabilir)
ip addr show kube-ipvs0

# Pod log'ları
kubectl logs -n kube-system -l k8s-app=calico-node --tail=50
kubectl logs -n kube-system -l k8s-app=calico-node -c install-cni --tail=50
```

---

## Özet: Altın Kurallar

1. **Her node'da `/etc/default/kubelet` ile `--node-ip` ayarla** - kubelet'in doğru IP'yi raporlaması için
2. **Calico'da `skip-interface` kullan** - `cidr` veya `interface` güvenilmez
3. **`iptables --flush` YAPMA** - cluster networking'i tamamen bozar
4. **MetalLB pool'u tanımlamayı unutma** - yoksa LoadBalancer service'ler çalışmaz
5. **WiFi interface'ine dikkat** - kapalı olsa bile IP tutabilir, Calico'yu yanıltır
6. **kube-ipvs0'a dikkat** - IPVS mode'da tüm service IP'leri bu interface'e bağlanır
7. **Node ekledikten sonra mutlaka Calico annotation kontrol et**
8. **Cross-node pod ping testi yap** - IPIP tunnel çalışıyor mu doğrula
