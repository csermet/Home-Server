# Ubuntu 24.04 LTS Server Kurulumu

## Node Bilgileri

| Node | Hostname | IP | Donanim |
|------|----------|----|---------|
| Intel | cnr-intel | 192.168.1.120 | i5-7600K, 16GB RAM, 512GB SSD, RTX 3060 Ti |
| RPi | cnr-raspberry | 192.168.1.121 | Raspberry Pi 5, 8GB RAM, 256GB SD |

---

## cnr-intel (Intel Makine)

### 1. ISO Hazirla

Ubuntu 24.04 LTS Server ISO'yu indir:
```
https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso
```

USB'ye yaz (Windows'ta Rufus veya Etcher kullan):
- GPT partition scheme
- UEFI boot

### 2. Kurulum Ayarlari

- **Language**: English
- **Keyboard**: Turkish Q (veya tercihine gore)
- **Network**: DHCP (sonra router'dan static IP reservation yapilacak)
- **Storage**: Use entire disk (512GB SSD)
  - LVM'i kaldir veya minimal tut (basitlik icin)
- **Profile**:
  - Your name: `caner`
  - Server name: `cnr-intel`
  - Username: `caner`
  - Password: (guclu sifre sec, NOT ET)
- **SSH**: Install OpenSSH server (kurulum sirasinda sec)
- **Featured snaps**: Hicbir sey secme

### 3. Ilk Boot Sonrasi

```bash
# Sistemi guncelle
sudo apt update && sudo apt upgrade -y

# Gerekli temel araclar
sudo apt install -y curl wget git vim net-tools htop

# Hostname dogrula
hostnamectl

# IP adresini kontrol et
ip addr show
```

### 4. ZTE Router'da DHCP Reservation

ZTE H3601P (192.168.1.1) admin paneline gir:
1. LAN > DHCP ayarlari
2. cnr-intel icin MAC adresi ile 192.168.1.120 reservation ekle
3. Makineyi yeniden baslat ve IP'yi dogrula

---

## cnr-raspberry (Raspberry Pi 5)

### 1. Image Hazirla

Raspberry Pi Imager kullan:
1. OS: **Ubuntu Server 24.04 LTS (64-bit)**
2. Storage: SD kart sec
3. Settings (disi simgesi):
   - Hostname: `cnr-raspberry`
   - Enable SSH (password authentication)
   - Username: `caner`
   - Password: (NOT ET)
   - WiFi: Yapilandirma - Ethernet kullanilacak
   - Locale: Europe/Istanbul

### 2. Ilk Boot

SD karti tak, ethernet kablosunu bagla, guc ver.

```bash
# SSH ile baglan (router'dan IP'yi bul veya)
ssh caner@cnr-raspberry.local

# Guncelle
sudo apt update && sudo apt upgrade -y

# Temel araclar
sudo apt install -y curl wget git vim net-tools htop linux-modules-extra-raspi
```

### 3. ZTE Router'da DHCP Reservation

1. cnr-raspberry icin MAC adresi ile 192.168.1.121 reservation ekle
2. Yeniden baslat ve IP dogrula

---

## Her Iki Node Icin Ortak

### SSH Key Kurulumu (Windows'tan)

Windows terminal'de:
```powershell
# SSH key olustur (yoksa)
ssh-keygen -t ed25519 -C "caner@homelab"

# Key'i node'lara kopyala
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh caner@192.168.1.120 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh caner@192.168.1.121 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### SSH Config (Windows)

`C:\Users\caner\.ssh\config` dosyasina ekle:
```
Host cnr-intel
    HostName 192.168.1.120
    User caner

Host cnr-raspberry
    HostName 192.168.1.121
    User caner
```

Artik `ssh cnr-intel` ve `ssh cnr-raspberry` ile baglanabilirsin.

---

## Sonraki Adim

1. `config.env` dosyasindaki IP ve hostname degerlerini kontrol et
2. `scripts/01-common-setup.sh` scriptini her iki node'da calistir

Bkz: [02-kubernetes-kurulum.md](02-kubernetes-kurulum.md)
