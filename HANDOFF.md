# IoT p1 — Contexte & handoff (mis à jour le 2026-09-09)

Fichier à transporter dans la nouvelle VM pour reprendre le projet sans reperdre du temps.

## Objectif du projet (p1)

Cluster K3s à 2 VMs via **Vagrant** :
- `imaalemS` — server / control-plane — IP `192.168.56.110`
- `imaalemSW` — agent / worker — IP `192.168.56.111`
- Debian stable, 1 CPU + 512–1024 Mo par VM, SSH sans mot de passe, kubectl installé.
- Le token de join généré par le server est transporté à l'agent via un dossier synchronisé (port 6443).

## Contrainte du sujet — on DOIT rester dans une VM

Sujet, chapitre III « General guidelines » :

> **The whole project has to be done in a virtual machine.**

> You can use any tools you want to set up your **host virtual machine** as well as
> the provider used in Vagrant.

Conséquences :
1. La VM hôte est **obligatoire**. On ne peut pas lancer les nœuds K3s directement sur
   le PC. L'ancienne section « dernier recours » de ce handoff proposait exactement ça :
   **elle était non conforme au sujet, elle est supprimée.**
2. En revanche le sujet ne fixe **aucun hyperviseur**. Rien n'oblige à utiliser
   VirtualBox pour la VM hôte → c'est le levier qu'on utilise (voir « Plan »).
3. La virtualisation imbriquée est donc inévitable et **assumée par le sujet**.

## Le problème rencontré

On développe **dans** une VM (L1), et Vagrant y crée d'autres VMs (L2) →
**virtualisation imbriquée**. Le moteur **nested VT-x de VirtualBox est buggé sur ce PC** :

- Symptôme : la VM L1 se fait tuer par un **Guru Meditation** (pop-up « A critical
  error has occurred… machine execution stopped »).
- Cause prouvée dans `VBox.log` : `VINF_EM_TRIPLE_FAULT` alors qu'un cœur était
  `In nested-guest hwvirt mode = true` → triple faute pendant l'exécution imbriquée.
- Ça crashe **aussi bien en VirtualBox-dans-VirtualBox qu'en KVM-dans-VirtualBox** :
  changer l'hyperviseur **interne** ne suffit pas, le bug est dans le VirtualBox du PC.

### Tentative n°1 : VM hôte neuve → ÉCHEC (2026-09-09)

Une VM neuve a été construite en suivant la recette (disque 35 Go, 8 Go RAM, 4 vCPU,
Nested VT-x coché, Debian 12). L'installation complète s'est bien passée
(`host-setup.sh` code 0, vagrant + libvirt + qemu OK, box `debian/trixie64`
téléchargée, domaine `imaalemS` créé). **Le crash est revenu à l'identique**, pendant
le montage / le boot du premier nœud, avec le même pop-up « critical error ».

**Conclusion : refaire la VM ne sert à rien. Le bug n'est pas dans la configuration
de l'invité, il est dans le moteur nested VT-x de VirtualBox côté PC.**

## Nouvelles découvertes (2026-09-09)

### A. Signature du crash confirmée depuis l'intérieur

- Le journal systemd du boot concerné s'arrête net à `16:38:13`, alors que le log QEMU
  de `imaalemS` a été créé à `16:42` et que Vagrant a continué à travailler ensuite :
  **4 à 8 minutes de journal perdues, jamais écrites sur disque**.
- Sur ce boot : **aucun kernel panic, aucun OOM, aucune MCE, aucun segfault**.
- Journal tronqué + zéro trace interne = la VM a été **tuée de l'extérieur,
  instantanément**. C'est la signature exacte du Guru Meditation.
- La VM a redémarré **7 fois dans la journée** (durées de boot : 23, 26, 11, 18, 6,
  21 min…), y compris avant que Vagrant ne soit installé.

Commandes utiles pour re-constater :
```bash
journalctl --list-boots        # durées de chaque boot, coupures nettes
journalctl -b -1 -n 25         # dernières lignes avant le crash
last -x reboot                 # aucun "shutdown" associé = arrêts non propres
```

### B. Le PC est un i7-12700 → architecture hybride Alder Lake

Facteur **non identifié jusqu'ici**, et probablement déterminant.

Ce CPU mélange des **P-cores** et des **E-cores**, qui n'exposent pas exactement le
même jeu d'instructions. Quand l'ordonnanceur de l'hôte déplace un thread vCPU d'un
P-core vers un E-core en pleine exécution, le CPUID vu par l'invité change sous ses
pieds. C'est une cause **documentée** de triple fault sous VirtualBox, et le nested
VT-x y est particulièrement sensible. Ça correspond exactement au
`VINF_EM_TRIPLE_FAULT` observé.

→ Mitigation : **épingler les vCPU sur les P-cores uniquement**.

### C. La VM neuve est très probablement sur le disque USB externe

`create-host-vm.sh` (dossier partagé) contient :
```bash
VM_DIR="/run/media/imaalem/mémoires/42/VMs"   # disque EXTERNE
DISK_MB=35000
```
Or le disque de la VM mesure **34,2 Go**, ce qui correspond exactement à
`DISK_MB=35000`. Le script n'a jamais été mis à jour alors que la recette disait
« disque **interne**, pas l'externe USB ». **La VM neuve a donc reproduit un des
facteurs aggravants qu'on voulait éliminer.**

Nuance : débit mesuré à **624 Mo/s en écriture / 666 Mo/s en lecture** (`dd oflag=direct`).
C'est donc un SSD USB, pas un disque à plateaux → le disque n'est **pas** le suspect
principal, mais autant le supprimer de l'équation.

À vérifier côté PC : `VBoxManage showvminfo iot-host | grep -i location`

### D. Ce qui n'est PAS la cause

- **La VM hôte est en Debian 12 (bookworm) et la box Vagrant en Debian 13 (trixie).**
  Cet écart **ne peut pas** provoquer le crash. Le triple fault se produit dans
  l'hyperviseur **externe** (VirtualBox, sur le PC) et tue la VM L1 tout entière. Un
  invité L2, quelle que soit sa distribution, ne peut au pire que se planter lui-même :
  il n'a aucun moyen de faire tuer la L1 par l'hyperviseur du PC. Un hyperviseur correct
  ne meurt jamais de ce que fait son invité.
  De plus la box `debian/trixie64` est **le bon choix** : le sujet exige « the latest
  stable version of the distribution of your choice » pour les nœuds, et trixie est la
  stable actuelle. La distribution de la VM hôte, elle, n'est pas notée.
- **La RAM** : pas d'OOM, ~6 Go disponibles en permanence, swap présent et inutilisé.
- **La configuration de l'invité** : la recette a été respectée à la lettre, sans effet.

## Plan retenu : garder la VM, changer d'hyperviseur EXTERNE

Le PC est sous **Fedora**, donc il dispose de **KVM en natif**. Le nested VMX de KVM est
mature et utilisé en production ; celui de VirtualBox est notoirement fragile. On
remplace donc uniquement la couche externe — le sujet reste respecté, on travaille
toujours dans une VM.

| Couche | Avant | Après |
|---|---|---|
| Hyperviseur externe (PC Fedora) | VirtualBox ❌ | **KVM / libvirt** ✅ |
| VM hôte Debian | inchangée | inchangée (sujet respecté) |
| Hyperviseur interne | libvirt/KVM | libvirt/KVM (inchangé) |
| Nœuds K3s | Vagrant | Vagrant (inchangé) |

On passe donc en **KVM-dans-KVM**, la combinaison la plus solide. Tout ce qui a été
installé dans la VM hôte (vagrant, vagrant-libvirt, qemu, `qemu.conf` patché) reste
valable : **pas de réinstallation de Debian**, on convertit le disque existant.

### Contraintes de la machine 42 (relevées le 2026-09-09, côté PC Fedora)

Ces trois points conditionnent toute la procédure :

| Point | Constat | Conséquence |
|---|---|---|
| `/home/imaalem` | **4,7 Go, 1,7 Go libres** (partition `nvme1n1` dédiée) | Impossible d'y mettre un qcow2. On utilise **`/goinfre/$USER/VMs`** (137 Go, 96 Go libres, NVMe). Attention : `/goinfre` est purgé régulièrement → ne pas y laisser l'unique copie. |
| Groupe `libvirt` | l'utilisateur **n'y est pas**, et `qemu:///system` renvoie « authentication cancelled » (polkit) ; `sudo` demande un mot de passe | On utilise **`qemu:///session`** : ça marche sans droits, et qemu tourne sous le compte utilisateur → il lit `/goinfre/$USER` (0700) sans bidouille de permissions. |
| Réseau en session | le réseau NAT `default` de libvirt n'existe pas en session | `--network user,model=virtio` (**`passt` est installé**). Sortant OK (apt, box vagrant) ; c'est tout ce dont la VM hôte a besoin. |

Autres vérifs faites : `nested = Y` ✅, `virt-manager` et `virt-viewer` présents ✅,
P-cores = `0-15` / E-cores = `16-19` ✅ (confirme le point B).

### Étapes sur le PC Fedora

Tout est automatisé — éteindre proprement la VM VirtualBox, puis :

```bash
bash ~/Desktop/iot/migrate-to-kvm.sh
```

Le script vérifie les pré-requis (nested, outils, VM éteinte, place disque), convertit
le VDI en qcow2 vers `/goinfre/$USER/VMs`, importe le domaine en `qemu:///session` avec
`--cpu host-passthrough`, et épingle les vCPU sur les P-cores.

Pour ne plus avoir à taper `-c qemu:///session` :

```bash
echo 'export LIBVIRT_DEFAULT_URI=qemu:///session' >> ~/.bashrc
```

Piloter la VM ensuite : `virt-manager` (choisir la connexion « QEMU/KVM Utilisateur »),
ou `virsh start|shutdown iot-host`.

### Une fois dans la VM migrée

Le nom de l'interface réseau change entre VirtualBox et KVM (le VDI garde l'ancienne
config). **Si la VM n'a plus de réseau**, c'est ça :

```bash
ip -br link                       # relever le nouveau nom (ex. enp1s0)
sudo nano /etc/network/interfaces # remplacer l'ancien nom par le nouveau
sudo systemctl restart networking
```

Puis :

```bash
cd ~/Bureau/iot/p1
rm -rf .vagrant          # l'état vagrant ne survit pas au changement d'hôte
vagrant up --no-parallel
```

## Vérifications de fin

```bash
vagrant ssh imaalemS -c "kubectl get nodes -o wide"   # les 2 nœuds doivent être Ready
bash ~/Bureau/iot/p1/scripts/check_cluster.sh
```

Puis enchaîner sur les **parties 2 (K3s + 3 apps + Ingress) et 3 (K3d + Argo CD)**.

## Si ça recrashe encore après la migration KVM

Dans l'ordre, du moins cher au plus cher :

1. Vérifier que l'épinglage P-cores est bien actif : `virsh -c qemu:///session vcpuinfo iot-host`
   (l'épinglage peut être refusé en session : le script le signale sans échouer).
2. Réduire la VM hôte à **2 vCPU** (moins de threads à migrer entre cœurs).
3. Passer les nœuds Vagrant en **1 seul nœud** le temps de valider la chaîne, puis
   rajouter le worker.
4. En dernier ressort **et sans quitter la VM** (le sujet l'impose) : basculer le
   provider Vagrant sur `qemu` en mode **TCG** (émulation pure, sans VT-x imbriqué)
   → lent mais immunisé au bug nested. `lv.driver = "qemu"` côté Vagrantfile.

## Inventaire des fichiers

- `p1/Vagrantfile` — 2 VMs, provider **libvirt**, box `debian/trixie64`, synced_folder 9p
  en `accessmode: "squash"`, 1 vCPU + 1024 Mo par VM, `graphics_type: none`.
- `p1/scripts/server.sh` — install K3s server (sans `--bind-address` pour que kubectl
  local marche), dépose le token, installe kubectl.
- `p1/scripts/worker.sh` — attend le token, install K3s agent, join sur `:6443`.
- `p1/scripts/host-setup.sh` — prépare la VM hôte (vagrant + libvirt/KVM + `qemu.conf`).
  **À relancer tel quel si on repart d'une VM neuve.** Testé OK le 2026-09-09.
- `p1/scripts/check_cluster.sh` — vérifs rapides pour la soutenance.
- `migrate-to-kvm.sh` (racine du dépôt) — **à lancer sur le PC Fedora** : migre la VM
  hôte de VirtualBox vers KVM/libvirt (conversion VDI→qcow2 vers `/goinfre`, import en
  `qemu:///session`, réseau `passt`, épinglage P-cores). Adapté aux contraintes de la
  machine 42 listées plus haut.
- `create-host-vm.sh` (dossier partagé, hors dépôt) — **obsolète** : crée la VM sous
  VirtualBox, sur le disque externe. Remplacé par la procédure KVM ci-dessus.
