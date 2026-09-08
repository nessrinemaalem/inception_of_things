# IoT p1 — Contexte & handoff (2026-09-08)

Fichier à transporter dans la nouvelle VM pour reprendre le projet sans reperdre du temps.

## Objectif du projet (p1)

Cluster K3s à 2 VMs via **Vagrant** :
- `imaalemS` — server / control-plane — IP `192.168.56.110`
- `imaalemSW` — agent / worker — IP `192.168.56.111`
- Debian stable, 1 CPU + 512–1024 Mo par VM, SSH sans mot de passe, kubectl installé.
- Le token de join généré par le server est transporté à l'agent via un dossier synchronisé (port 6443).

## Le problème rencontré (2 jours de blocage)

On développe **dans** une VM VirtualBox (appelée L1), et Vagrant y crée d'autres VMs (L2) → **virtualisation imbriquée**. Le moteur **nested VT-x de VirtualBox est buggé sur ce PC** :

- Symptôme : la VM L1 se fait tuer par un **Guru Meditation** (message « A critical error has occurred… machine execution stopped »).
- Cause exacte, prouvée dans `VBox.log` : `VINF_EM_TRIPLE_FAULT` alors qu'un cœur était `In nested-guest hwvirt mode = true` → triple faute pendant l'exécution imbriquée → Guru Meditation.
- Ça crashe **aussi bien en VirtualBox-dans-VirtualBox qu'en KVM-dans-VirtualBox** : changer l'hyperviseur interne ne suffit pas, le bug est dans le VirtualBox du PC hôte.

## Ce qui a été fait / décidé

1. **Provider = libvirt/KVM** (le sujet p.4 autorise n'importe quel provider ; KVM-dans-VBox est plus stable que VBox-dans-VBox). Le Vagrantfile et les scripts sont déjà adaptés.
2. Correctif nécessaire côté hôte pour le partage 9p du dossier projet (situé dans /home) : QEMU doit tourner en tant que l'utilisateur de login → `/etc/libvirt/qemu.conf` avec `user`/`group` = ton user + `security_driver = "none"`. **Automatisé dans `p1/scripts/host-setup.sh`.**
3. Facteurs aggravants identifiés : trop de vCPU (10), disque **USB externe**, ancienne version VBox (VM créée en 7.0.x, hôte en 7.2.16, Guest Additions 7.0.26 dépareillées).
4. Malgré la réduction à 4 vCPU, le crash a persisté → **décision : reconstruire une VM hôte neuve** (interne, sous 7.2.16, nested activé dès le départ).

## Recette de la nouvelle VM (VirtualBox 7.2.16, côté PC)

- **Disque : interne** (pas l'externe USB), taille **≥ 30 Go**
- OS : Debian 12 ou 13 (stable)
- **RAM : 8192 Mo**
- **Processeurs : 4** (surtout pas 10)
- **Accélération → « Nested VT-x/AMD-V » : coché** (indispensable)
- Guest Additions : optionnel en headless ; si installées, prendre la version **7.2.16** (assortie à l'hôte)

## Étapes une fois la VM démarrée

```bash
# 1. Récupérer le projet (depuis dossier partagé / disque externe) vers le home
cp -r /media/sf_shared_folder/iot ~/iot      # adapter le chemin source

# 2. Nettoyer l'état vagrant périmé qui a voyagé avec la copie
rm -rf ~/iot/p1/.vagrant

# 3. Installer TOUTE la chaîne en une commande (vagrant + libvirt/KVM + qemu.conf)
sudo bash ~/iot/p1/scripts/host-setup.sh

# 4. Se déconnecter / reconnecter (pour activer le groupe libvirt)

# 5. Lancer le cluster (séquentiel = plus stable)
cd ~/iot/p1 && vagrant up --no-parallel
```

## Vérifications de fin

```bash
vagrant ssh imaalemS -c "kubectl get nodes -o wide"   # les 2 nœuds doivent être Ready
bash ~/iot/p1/scripts/check_cluster.sh
```

Puis enchaîner sur les **parties 2 (K3s + 3 apps + Ingress) et 3 (K3d + Argo CD)**.

## Inventaire des fichiers

- `p1/Vagrantfile` — 2 VMs, provider **libvirt**, box `debian/trixie64`, synced_folder 9p, 4 vCPU implicites (1 par VM), graphics none.
- `p1/scripts/server.sh` — install K3s server (sans `--bind-address` pour que kubectl local marche), dépose le token, installe kubectl.
- `p1/scripts/worker.sh` — attend le token, install K3s agent, join sur `:6443`.
- `p1/scripts/host-setup.sh` — **prépare la VM hôte automatiquement** (à lancer avec sudo).
- `p1/scripts/check_cluster.sh` — vérifs rapides pour la soutenance.

## Si ça recrashe malgré la VM neuve

Le bug nested VT-x est côté VirtualBox du PC. Dernier recours : lancer les VMs K3s **directement sur le PC** (sans VM hôte intermédiaire) → virtualisation simple = stable, et conforme au sujet (les nœuds K3s sont les « VMs »).
