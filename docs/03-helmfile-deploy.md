# DevOps Stack Deployment (Helmfile)

## Onkosullar

- Kubernetes cluster calisir durumda (2 node Ready)
- Calico, MetalLB, Longhorn kurulu
- Helm ve Helmfile kurulu

### Helm ve Helmfile Kurulumu (cnr-intel)

```bash
# Helm kur
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Helmfile kur
wget https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz
tar xzf helmfile_linux_amd64.tar.gz
sudo mv helmfile /usr/local/bin/
rm helmfile_linux_amd64.tar.gz

# Helmfile diff plugin (gerekli)
helm plugin install https://github.com/databus23/helm-diff
```

---

## Cloudflare API Token

cert-manager ve external-dns icin Cloudflare API token gerekli.

1. [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens) > API Tokens
2. "Create Token" > "Edit zone DNS" template'ini kullan
3. Permissions:
   - Zone - DNS - Edit
   - Zone - Zone - Read
4. Zone Resources: railguncnr.com
5. Token'i kaydet

`helmfile/manifests/templates/cloudflare-api-secret.yaml` dosyasinda token'i guncelle:
```yaml
# CLOUDFLARE_API_TOKEN degerini kendi token'inla degistir
```

---

## GitLab Sifreleri

`helmfile/manifests/templates/gitlab-secrets.yaml` icinde:
- GitLab root sifreni belirle

`helmfile/manifests/templates/gitlab-runner-secret.yaml` icinde:
- GitLab kurulduktan sonra runner registration token'i buraya eklenecek

---

## Deployment

### cert-manager CRDs (ilk seferde gerekli)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
```

### Helmfile Sync

```bash
cd helmfile/
helmfile sync
```

Bu komut sirasiyla su release'leri kurar:
1. metrics-server (kube-system)
2. manifests (devops) - secrets
3. cert-manager (cert-manager)
4. external-dns (devops)
5. nginx-ingress (devops)
6. gitlab, prometheus, argocd, sonarqube (devops) - paralel
7. grafana (devops) - prometheus'a bagimli
8. harbor (devops)
9. gitlab-runner (devops) - gitlab'e bagimli

### Durum Kontrol

```bash
# Tum release'lerin durumu
helmfile status

# devops namespace pod'lari
kubectl get pods -n devops

# cert-manager pod'lari
kubectl get pods -n cert-manager

# Ingress listesi
kubectl get ingress -n devops

# TLS sertifikalari
kubectl get certificates -n devops
```

---

## Servis Erisimleri

| Servis | URL |
|--------|-----|
| ArgoCD | https://argocd.home.railguncnr.com |
| GitLab | https://gitlab.home.railguncnr.com |
| Grafana | https://grafana.home.railguncnr.com |
| Prometheus | https://prometheus.home.railguncnr.com |
| Harbor | https://harbor.home.railguncnr.com |
| SonarQube | https://sonarqube.home.railguncnr.com |

> NOT: Servislere erisim icin DNS kayitlarinin Cloudflare'da olusturulmus olmasi
> veya external-dns'in otomatik olusturmasi gerekir.
> Yerel agdan erisim icin /etc/hosts veya router DNS override kullanilabilir.

---

## Sorun Giderme

### Pod baslamiyor
```bash
kubectl describe pod <pod-name> -n devops
kubectl logs <pod-name> -n devops
```

### TLS sertifikasi alinmiyor
```bash
kubectl describe certificate -n devops
kubectl describe certificaterequest -n devops
kubectl logs -n cert-manager -l app=cert-manager
```

### Ingress calismiyorsa
```bash
kubectl get svc -n devops nginx-ingress-ingress-nginx-controller
# EXTERNAL-IP 192.168.1.200 olmali (MetalLB'den)
```

### Tek bir release'i yeniden kur
```bash
helmfile -l name=gitlab sync
```
