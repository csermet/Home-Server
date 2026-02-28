# Ev Gider Bölüştürme Uygulaması - Altyapı ve Deployment Rehberi

Bu doküman, uygulamayı geliştirecek AI session'a mevcut Kubernetes altyapısını ve uygulamanın nasıl deploy edileceğini açıklar.

---

## Mevcut Altyapı Özeti

### Cluster
- **2 node Kubernetes cluster** (kubeadm, v1.34.5)
  - `cnr-intel`: i5-7600K, 16GB RAM, Ubuntu 24.04, **amd64**
  - `cnr-raspberry`: Raspberry Pi 5, 8GB RAM, Ubuntu 24.04, **arm64**
- Her iki node'da da pod schedule edilebilir (control-plane taint kaldırılmış)

### Ağ ve Erişim
- **Domain**: `*.railguncnr.com` (Cloudflare DNS)
- **TLS**: Cloudflare Origin CA wildcard sertifikası (`wildcard-tls` secret'ı, `devops` namespace'inde)
- **Ingress Controller**: nginx-ingress (IngressClass: `nginx`, default)
- **External Access**: Cloudflare Tunnel — modemde port açılmadan dışarıdan erişim sağlanıyor
- **Load Balancer**: MetalLB (L2 mode, 192.168.1.200-210)

### Mevcut Servisler ve URL'leri
| Servis | URL | Namespace |
|--------|-----|-----------|
| Grafana | `grafana.railguncnr.com` | devops |
| ArgoCD | `argocd.railguncnr.com` | devops |
| Harbor | `harbor.railguncnr.com` | devops |

### Storage
- **Longhorn** distributed storage (default StorageClass)
- PVC oluşturulduğunda Longhorn otomatik olarak volume sağlar
- `defaultReplicaCount: 2` (her volume 2 node'da replike)

---

## Uygulama İçin Deployment Gereksinimleri

### 1. Container Image

**Multi-arch image (amd64 + arm64) build et** veya **nodeSelector ile amd64'e sabitle**.

Her iki node'da da çalışabilmesi için multi-arch önerilir:
```dockerfile
# Dockerfile içinde multi-arch uyumlu base image kullan
FROM node:22-alpine  # veya python:3.12-slim, golang:1.23-alpine vb.
```

Eğer sadece amd64 hedeflenecekse deployment'a ekle:
```yaml
nodeSelector:
  kubernetes.io/arch: amd64
```

### 2. Namespace

Uygulama `devops` namespace'inde veya yeni bir namespace'de çalışabilir. Yeni namespace tercih edilirse helmfile manifests chart'ına eklenebilir veya ayrı oluşturulabilir.

### 3. Ingress Tanımı

Mevcut pattern'a uygun Ingress örneği:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gider-app
  namespace: devops  # veya kendi namespace'i
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - gider.railguncnr.com
      secretName: wildcard-tls   # mevcut wildcard sertifika
  rules:
    - host: gider.railguncnr.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gider-app
                port:
                  number: 80
```

> **Not**: `wildcard-tls` secret'ı şu an sadece `devops` ve `longhorn-system` namespace'lerinde var. Farklı namespace kullanılacaksa secret o namespace'e de kopyalanmalı (veya helmfile manifests chart'ına eklenmeli).

### 4. Veritabanı

Seçenekler:
- **PostgreSQL** — Helm chart ile ayrı deploy veya uygulama içi SQLite
- **SQLite** — PVC ile persistent, en basit seçenek, tek pod uygulaması için yeterli
- Cluster'da zaten Harbor'ın internal PostgreSQL'i var ama paylaşılmamalı

PVC örneği (SQLite veya dosya tabanlı DB için):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gider-app-data
  namespace: devops
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
```

### 5. Deployment Örneği (Tam)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gider-app
  namespace: devops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gider-app
  template:
    metadata:
      labels:
        app: gider-app
    spec:
      containers:
        - name: gider-app
          image: harbor.railguncnr.com/library/gider-app:latest
          ports:
            - containerPort: 3000  # uygulama portu
          volumeMounts:
            - name: data
              mountPath: /app/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: gider-app-data
---
apiVersion: v1
kind: Service
metadata:
  name: gider-app
  namespace: devops
spec:
  selector:
    app: gider-app
  ports:
    - port: 80
      targetPort: 3000
```

### 6. Container Registry

Harbor mevcut: `harbor.railguncnr.com`

Image push workflow:
```bash
# Login
docker login harbor.railguncnr.com

# Build & tag
docker build -t harbor.railguncnr.com/library/gider-app:latest .

# Push
docker push harbor.railguncnr.com/library/gider-app:latest
```

Kubernetes'in Harbor'dan image çekebilmesi için imagePullSecret gerekebilir (Harbor public project kullanılmıyorsa).

---

## Cloudflare Tunnel — Otomatik Erişim

`*.railguncnr.com` wildcard CNAME ile Cloudflare Tunnel'a yönlendirilmiş. Yeni bir subdomain (örn. `gider.railguncnr.com`) için:

1. Ingress oluştur (yukarıdaki örnek)
2. **DNS kaydı eklemeye gerek yok** — wildcard CNAME zaten tüm subdomain'leri tunnel'a yönlendiriyor
3. Cloudflare SSL mode: Full (Origin CA sertifikası kullanılıyor)

Yani sadece Ingress oluşturmak yeterli, uygulama otomatik olarak dışarıdan erişilebilir olur.

---

## Önemli Kısıtlamalar

1. **arm64 uyumluluk**: Raspberry Pi node'u arm64. Eğer uygulama arm64 desteklemiyorsa `nodeSelector: kubernetes.io/arch: amd64` kullan
2. **Kaynak limitleri**: Cluster toplam 16GB (Intel) + 8GB (Raspberry). Harbor, GitLab gibi servisler çalışıyor — resources request/limit belirle
3. **Tek replica önerilir**: Küçük cluster, stateful uygulama için 1 replica yeterli
4. **PVC ReadWriteOnce**: Longhorn RWO destekler, birden fazla pod aynı PVC'yi aynı anda kullanamaz

---

## Özet Checklist

Uygulamayı cluster'a deploy etmek için:

- [ ] Dockerfile yaz (multi-arch veya amd64)
- [ ] Container image build et ve `harbor.railguncnr.com/library/gider-app:latest` olarak push et
- [ ] Kubernetes manifest'leri oluştur: Deployment, Service, PVC, Ingress
- [ ] Ingress host: `gider.railguncnr.com`, TLS secret: `wildcard-tls`
- [ ] `kubectl apply -f` ile deploy et
- [ ] `gider.railguncnr.com` adresinden erişimi doğrula
