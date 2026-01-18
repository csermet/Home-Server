# Ev Kubernetes Cluster

## Donanım

| Makine | Rol | IP | Özellikler |
|--------|-----|-----|------------|
| cnr-intel | Master + Worker | 192.168.1.105 | i5-7600K, 16GB RAM, 512GB SSD |
| cnr-raspberry | Worker | 192.168.1.104 | Raspberry Pi 5, 8GB RAM, 256GB SD |

## Kurulu Bileşenler

| Bileşen | Versiyon | Açıklama |
|---------|----------|----------|
| Kubernetes | v1.34.3 | kubeadm ile kurulum |
| Calico | v3.31.3 | CNI (Network) |
| Longhorn | v1.10.1 | Storage (replica: 2) |
| MetalLB | v0.15.3 | LoadBalancer IP havuzu (192.168.1.200-210) |
| NGINX Ingress | v2.4.1 | Ingress Controller (F5/NGINX Inc.) |
| metrics-server | latest | Kaynak izleme (kubectl top) |
| Tailscale | - | VPN (dış erişim) |

## Ağ Yapısı

```
İnternet
    │
    ▼
Ev Router (192.168.1.1)
    │
    ├── cnr-intel (192.168.1.105)
    │   └── Tailscale: 100.x.x.x
    │
    └── cnr-raspberry (192.168.1.104)
        └── Tailscale: 100.x.x.x
```

## Calico Konfigürasyonu

### Sorun
Calico varsayılan olarak Tailscale interface'ini (100.x.x.x) algılıyordu. Bu, pod'lar arası iletişimin bozulmasına neden oluyordu.

### Çözüm
`calico.yaml` dosyasında `IP_AUTODETECTION_METHOD` eklendi:

```yaml
- name: IP_AUTODETECTION_METHOD
  value: "interface=eth0,eno1,enp.*"
```

Bu ayar Calico'ya sadece fiziksel ethernet interface'lerini kullanmasını söyler. Tailscale interface'i (tailscale0) görmezden gelinir.

### Dosya Konumu
- `calico.yaml` - Düzenlenmiş Calico manifest'i (satır ~7189)

## Storage (Longhorn)

- Her iki node'da da storage aktif
- Default Replica Count: 2 (Intel + Pi'de yedekli)
- Data Locality: best-effort (pod neredeyse oradan okur)
- Intel: ~474GB SSD
- Pi: ~233GB SD kart
- Longhorn UI: `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`

## Dış Erişim (Tailscale)

Tailscale VPN ile herhangi bir yerden kubectl erişimi:

1. Mac'te Tailscale kurulu ve aynı hesaba bağlı
2. kubeconfig `~/.kube/config-home` konumunda
3. `KUBECONFIG` ortam değişkeni ayarlı

```bash
export KUBECONFIG=~/.kube/config:~/.kube/config-home
kubectl config use-context kubernetes-admin@kubernetes
```

## Açma/Kapama Prosedürü

### Kapatırken
```bash
# 1. Worker'ı drain et
kubectl drain cnr-raspberry --ignore-daemonsets --delete-emptydir-data

# 2. Pi'yi kapat
ssh cnr-raspberry "sudo shutdown now"

# 3. Intel'i kapat
ssh cnr-intel "sudo shutdown now"
```

### Açarken
```bash
# 1. Önce Intel'i aç
# 2. Bekle (~2 dk), kontrol et
kubectl get nodes

# 3. Pi'yi aç
# 4. Worker'ı uncordon et
kubectl uncordon cnr-raspberry
```

## Faydalı Komutlar

```bash
# Node durumu
kubectl get nodes

# Tüm pod'lar
kubectl get pods -A

# Longhorn durumu
kubectl -n longhorn-system get pods

# Calico durumu
kubectl -n kube-system get pods -l k8s-app=calico-node

# Tailscale IP'leri
tailscale status
```

## Dosya Yapısı

```
Home-Server/
├── README.md          # Bu dosya
├── calico.yaml        # Düzenlenmiş Calico manifest
├── nginx-ingress/     # NGINX Ingress Helm chart (source)
└── ...
```

## Kalan Yapılacaklar (To-Do)

| Sıra | Görev | Açıklama |
|------|-------|----------|
| 1 | cert-manager | Let's Encrypt SSL sertifikaları |
| 2 | external-dns | Cloudflare otomatik DNS güncellemesi |
| 3 | Modem port forward | 80/443 → 192.168.1.200 yönlendirmesi |
| 4 | Dış erişim testi | Domain üzerinden erişim kontrolü |
| 5 | ArgoCD | GitOps kurulumu |
| 6 | Prometheus + Grafana | Monitoring ve dashboard |
| 7 | Harbor | Container registry (opsiyonel) |

## Notlar

- Ingress IP: 192.168.1.200 (MetalLB tarafından atandı)
- DHCP aralığı: 192.168.1.2-199 (modemde ayarlandı)
- MetalLB aralığı: 192.168.1.200-210
- Domain: *.k8s.railguncnr.com (Cloudflare'de)
