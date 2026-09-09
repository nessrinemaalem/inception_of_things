#!/bin/bash
# =============================================================================
# migrate-to-kvm.sh
# À LANCER SUR TON PC (Fedora), dans un terminal — PAS dans la VM.
#
# Migre la VM hôte "iot-host" de VirtualBox vers KVM/libvirt, sans réinstaller
# Debian : on convertit son disque et on la réimporte.
#
# Pourquoi : le nested VT-x de VirtualBox provoque un Guru Meditation
# (VINF_EM_TRIPLE_FAULT) sur ce PC. Le nested VMX de KVM, lui, est mature.
# Le sujet impose de travailler dans une VM mais n'impose aucun hyperviseur.
#
#     bash migrate-to-kvm.sh
# =============================================================================
set -eu

VM_NAME="iot-host"
# $HOME ne fait que 4,7 Go sur cette machine : le qcow2 va dans /goinfre.
DEST_DIR="/goinfre/$USER/VMs"
DEST_DISK="$DEST_DIR/$VM_NAME.qcow2"
RAM_MB=8192
CPUS=4
# session (et pas system) : l'utilisateur n'est pas dans le groupe libvirt, et
# qemu tourne alors sous son compte -> accès direct à /goinfre/$USER en 0700.
URI="qemu:///session"

say() { echo; echo ">>> $*"; }

# --- 1. Pré-requis -----------------------------------------------------------
say "Vérification des pré-requis..."
MISSING=""
for c in qemu-img virt-install virsh VBoxManage; do
  command -v "$c" >/dev/null || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
  echo "!! Outils manquants :$MISSING"
  echo "   sudo dnf install -y qemu-img virt-install libvirt-client libvirt-daemon-kvm"
  exit 1
fi

# virt-manager n'est pas indispensable au script, mais c'est LA fenetre
# graphique (equivalent de l'interface VirtualBox) : on previent si absent.
if ! command -v virt-manager >/dev/null; then
  echo "    (!) virt-manager absent : pas d'interface graphique pour piloter la VM."
  echo "        sudo dnf install -y virt-manager"
fi

NESTED=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "?")
echo "    nested KVM = $NESTED"
if [ "$NESTED" != "Y" ] && [ "$NESTED" != "1" ]; then
  echo "!! Le nested KVM n'est pas actif. Active-le puis relance :"
  echo "   echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm.conf"
  echo "   sudo modprobe -r kvm_intel && sudo modprobe kvm_intel"
  exit 1
fi

virsh -c "$URI" list >/dev/null 2>&1 || {
  echo "!! Impossible de joindre $URI"
  exit 1
}

# --- 2. La VM VirtualBox doit être ÉTEINTE -----------------------------------
say "Vérification que '$VM_NAME' est bien éteinte..."
if ! VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
  echo "!! Aucune VM VirtualBox nommée '$VM_NAME'."
  echo "   Liste : VBoxManage list vms"
  exit 1
fi
STATE=$(VBoxManage showvminfo "$VM_NAME" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p')
echo "    état = $STATE"
if [ "$STATE" != "poweroff" ] && [ "$STATE" != "saved" ] && [ "$STATE" != "aborted" ]; then
  echo "!! Éteins d'abord la VM (arrêt propre depuis le bureau Debian), puis relance."
  exit 1
fi

# --- 3. Localiser le disque VDI ---------------------------------------------
say "Localisation du disque VDI..."
SRC_DISK=$(VBoxManage showvminfo "$VM_NAME" --machinereadable \
           | sed -n 's/^"SATA-0-0"="\(.*\)"/\1/p' | head -1)
[ -n "${SRC_DISK:-}" ] && [ -f "$SRC_DISK" ] || {
  echo "!! Disque introuvable automatiquement. Cherche-le avec :"
  echo "   VBoxManage showvminfo $VM_NAME | grep -i vdi"
  exit 1
}
echo "    source : $SRC_DISK"
case "$SRC_DISK" in
  /run/media/*) echo "    (sur le disque externe -> on le rapatrie en interne)" ;;
esac

# --- 4. Conversion VDI -> qcow2 ---------------------------------------------
say "Conversion en qcow2 (peut prendre plusieurs minutes)..."
mkdir -p "$DEST_DIR"
if [ -f "$DEST_DISK" ]; then
  echo "!! $DEST_DISK existe déjà. Supprime-le ou renomme-le d'abord."
  exit 1
fi
NEEDED_GB=$(( $(stat -c %s "$SRC_DISK") / 1000000000 + 5 ))
FREE_GB=$(df -BG --output=avail "$DEST_DIR" | tail -1 | tr -dc '0-9')
echo "    besoin ~${NEEDED_GB} Go, libre ${FREE_GB} Go sur $DEST_DIR"
if [ "$FREE_GB" -lt "$NEEDED_GB" ]; then
  echo "!! Pas assez de place sur $DEST_DIR."
  exit 1
fi
qemu-img convert -p -f vdi -O qcow2 "$SRC_DISK" "$DEST_DISK"
qemu-img info "$DEST_DISK" | head -4

# --- 5. Import sous libvirt --------------------------------------------------
say "Import sous libvirt (CPU host-passthrough = VMX exposé proprement)..."
if virsh -c "$URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "!! Un domaine libvirt '$VM_NAME' existe déjà : virsh -c $URI undefine $VM_NAME"
  exit 1
fi
# --network user : en session, le réseau NAT "default" n'existe pas. passt
# fournit un réseau sortant sous l'utilisateur, suffisant pour apt/vagrant.
# bus=sata (et pas virtio) : garantit que l'initramfs Debian existant boote.
virt-install --connect "$URI" --import --name "$VM_NAME" \
  --memory "$RAM_MB" --vcpus "$CPUS" \
  --cpu host-passthrough \
  --disk "$DEST_DISK",bus=sata \
  --os-variant debian12 \
  --network user,model=virtio \
  --graphics spice --noautoconsole

# --- 6. Épinglage sur les P-cores -------------------------------------------
# i7-12700 = Alder Lake hybride. Un thread vCPU qui saute d'un P-core à un
# E-core change le CPUID sous l'invité -> triple fault. On l'interdit.
say "Épinglage des vCPU sur les P-cores..."
PCORES=$(cat /sys/devices/cpu_core/cpus 2>/dev/null || echo "")
if [ -z "$PCORES" ]; then
  echo "    (détection auto impossible, repli sur 0-15)"
  PCORES="0-15"
fi
echo "    P-cores = $PCORES"
# --config seul ne suffit pas : virt-install a déjà démarré le domaine, il faut
# donc aussi --live sinon les vCPU restent libres de migrer sur les E-cores.
PIN_OK=1
for i in $(seq 0 $((CPUS - 1))); do
  virsh -c "$URI" vcpupin "$VM_NAME" "$i" "$PCORES" --config || PIN_OK=0
  virsh -c "$URI" vcpupin "$VM_NAME" "$i" "$PCORES" --live   || PIN_OK=0
done
virsh -c "$URI" emulatorpin "$VM_NAME" "$PCORES" --config || PIN_OK=0
virsh -c "$URI" emulatorpin "$VM_NAME" "$PCORES" --live   || PIN_OK=0
[ "$PIN_OK" = 1 ] || echo "    (!) épinglage refusé — la VM tourne quand même, voir la section
        « Si ça recrashe » du HANDOFF."

say "Terminé."
cat <<EOF

============================================================
La VM '$VM_NAME' tourne maintenant sous KVM (connexion $URI).

  Console graphique :   virt-manager      puis choisir "QEMU/KVM Utilisateur"
                        (ou : virt-viewer -c $URI $VM_NAME)
  Démarrer / arrêter :  virsh -c $URI start $VM_NAME
                        virsh -c $URI shutdown $VM_NAME
  Vérifier l'épinglage : virsh -c $URI vcpuinfo $VM_NAME

  Astuce : export LIBVIRT_DEFAULT_URI=$URI  (dans ~/.bashrc)
  pour ne plus avoir à taper -c à chaque fois.

Une fois connectée dans la VM :

  # Le nom de l'interface réseau change entre VirtualBox et KVM. Si la VM
  # n'a plus de réseau :  ip -br link   puis reporter le nouveau nom dans
  # /etc/network/interfaces  et  sudo systemctl restart networking
  cd ~/Bureau/iot/p1
  rm -rf .vagrant          # l'état vagrant ne survit pas au changement d'hôte
  vagrant up --no-parallel

L'ancienne VM VirtualBox n'est PAS supprimée : elle reste disponible en
repli. Pour la retirer une fois la migration validée :
  VBoxManage unregistervm "$VM_NAME" --delete
============================================================
EOF
