# Home Server & Kubernetes Cluster

Ev Kubernetes cluster'i + medya/dosya sunucusu. DevOps ogrenme ortami ve home server olarak kullanim.

## Donanim

| Node | Rol | IP | Ozellikler |
|------|-----|-----|------------|
| cnr-intel | Master + Worker | 192.168.1.120 | i5-7600K, 16GB RAM, 512GB SSD, RTX 3060 Ti |
| cnr-raspberry | Worker | 192.168.1.121 | Raspberry Pi 5, 8GB RAM, 256GB SD |

## Ag Yapisi

```
Internet
    |
    v
ZTE H3601P Router (192.168.1.1) -- Tek DHCP sunucusu
    |
    +-- TP-Link RE700X (192.168.1.100) -- WiFi bridge
    |
    +-- Zyxel VMG3312 (192.168.1.101) -- Switch modu
        |
        +-- cnr-intel (192.168.1.120)
        |   +-- Tailscale: 100.x.x.x
        |
        +-- cnr-raspberry (192.168.1.121)
            +-- Tailscale: 100.x.x.x
```

- DHCP araigi: 192.168.1.2-199
- MetalLB havuzu: 192.168.1.200-210
- Domain: *.home.railguncnr.com (Cloudflare DNS)

## Kurulu Bilesenler

### Kubernetes Altyapisi
| Bilesen | Aciklama |
|---------|----------|
| Kubernetes (kubeadm) | Cluster orkestrasyonu |
| Calico | CNI - Pod networking |
| Longhorn | Distributed block storage (2 replica) |
| MetalLB | Bare-metal LoadBalancer (192.168.1.200-210) |
| Tailscale | VPN - uzaktan erisim |

### DevOps Stack (Helmfile - `devops` namespace)
| Bilesen | URL |
|---------|-----|
| NGINX Ingress | LoadBalancer entry point |
| cert-manager | Let's Encrypt TLS (Cloudflare DNS-01) |
| external-dns | Cloudflare otomatik DNS |
| GitLab CE | gitlab.home.railguncnr.com |
| Harbor | harbor.home.railguncnr.com |
| ArgoCD | argocd.home.railguncnr.com |
| Prometheus | prometheus.home.railguncnr.com |
| Grafana | grafana.home.railguncnr.com |
| SonarQube | sonarqube.home.railguncnr.com |
| GitLab Runner | CI/CD job executor |
| metrics-server | kubectl top / HPA |

### Native Servisler (K8s Disinda - cnr-intel)
| Bilesen | Aciklama |
|---------|----------|
| Jellyfin | Medya streaming (RTX 3060 Ti NVENC) |
| Samba | Windows ag surucusu paylasimi |
| qBittorrent | Torrent web UI |
| Restic + B2 | Yedekleme (sadece 1TB kritik disk) |

## Disk Yapisi (cnr-intel)

```
/mnt/1tb/     -- Kritik veriler (fotograflar, projeler, belgeler)
               -- Restic + Backblaze B2 ile yedeklenir
/mnt/3tb/     -- Medya ve indirmeler
               -- Yedeklenmez
```

## Repo Yapisi

```
home-server/
+-- config.env                    # Tek konfigurasyon dosyasi (IP, versiyon, domain)
+-- README.md
+-- docs/
|   +-- 01-os-kurulum.md          # Ubuntu 24.04 kurulum rehberi
|   +-- 02-kubernetes-kurulum.md   # kubeadm cluster setup
|   +-- 03-helmfile-deploy.md      # DevOps stack deployment
+-- scripts/
|   +-- 01-common-setup.sh        # Node ortak setup (config.env'den okur)
|   +-- 02-master-init.sh         # Master node init (config.env'den okur)
|   +-- 03-worker-join.sh         # Worker node join (config.env'den okur)
+-- infrastructure/
|   +-- calico/calico.yaml        # Calico CNI manifest
|   +-- longhorn/                 # Longhorn storage values
+-- helmfile/
    +-- helmfile.yaml             # Helmfile orkestrasyon
    +-- values/                   # Servis bazli values dosyalari
    +-- manifests/                # Secrets ve ClusterIssuer
```

## Calico Notu

Calico'da `IP_AUTODETECTION_METHOD` ayari kritiktir:
```yaml
- name: IP_AUTODETECTION_METHOD
  value: "interface=eth0,eno1,enp.*"
```
Bu, Tailscale interface'inin (tailscale0) pod networking icin kullanilmasini engeller.

## Acma/Kapama Proseduru

### Kapatirken
```bash
kubectl drain cnr-raspberry --ignore-daemonsets --delete-emptydir-data
ssh cnr-raspberry "sudo shutdown now"
ssh cnr-intel "sudo shutdown now"
```

### Acarken
```bash
# 1. Intel'i ac, ~2 dk bekle
kubectl get nodes
# 2. Pi'yi ac
kubectl uncordon cnr-raspberry
```

## Hizli Baslangi

1. [OS Kurulumu](docs/01-os-kurulum.md) - Ubuntu 24.04 LTS her iki node'a
2. [Kubernetes Kurulumu](docs/02-kubernetes-kurulum.md) - kubeadm, Calico, MetalLB, Longhorn
3. [DevOps Stack](docs/03-helmfile-deploy.md) - `helmfile sync` ile tum stack
