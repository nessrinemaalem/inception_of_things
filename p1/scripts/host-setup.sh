#!/bin/bash
# =============================================================================
# host-setup.sh — prepare une VM hote Debian pour lancer le projet p1 avec
# Vagrant + libvirt/KVM (provider stable en virtualisation imbriquee).
#
# A lancer UNE FOIS dans la nouvelle VM, avec sudo :
#     sudo bash p1/scripts/host-setup.sh
#
# Puis se deconnecter/reconnecter (pour le groupe libvirt) et :
#     cd p1 && vagrant up --no-parallel
# =============================================================================
set -eu

# Utilisateur non-root qui lancera vagrant (celui qui a invoque sudo)
TARGET_USER="${SUDO_USER:-$(id -un)}"
echo ">>> Utilisateur cible : ${TARGET_USER}"

echo ">>> Installation de Vagrant + libvirt/KVM + QEMU..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  vagrant vagrant-libvirt \
  libvirt-daemon-system libvirt-clients \
  qemu-system-x86 dnsmasq-base

echo ">>> Ajout de ${TARGET_USER} au groupe libvirt (acces au demon sans root)..."
usermod -aG libvirt "${TARGET_USER}"

# QEMU (connexion qemu:///system) doit pouvoir ouvrir le dossier partage 9p
# situe dans le home de l'utilisateur : on le fait tourner en tant que cet
# utilisateur, et on ecarte AppArmor pour eviter tout blocage sur ce partage.
# (Relachement acceptable sur une VM de dev dediee au projet.)
QEMU_CONF=/etc/libvirt/qemu.conf
if ! grep -q "Ajouts IoT" "${QEMU_CONF}"; then
  echo ">>> Configuration de ${QEMU_CONF} (user/group=${TARGET_USER}, AppArmor off)..."
  cat >> "${QEMU_CONF}" <<EOF

# --- Ajouts IoT (VM de dev) ---
user = "${TARGET_USER}"
group = "${TARGET_USER}"
security_driver = "none"
EOF
else
  echo ">>> ${QEMU_CONF} deja configure, on ne touche pas."
fi

echo ">>> Activation du demon libvirt..."
systemctl enable --now libvirtd
systemctl restart libvirtd

echo
echo "============================================================"
echo "OK. Hote pret."
echo "IMPORTANT : deconnecte-toi puis reconnecte-toi (ou reboote)"
echo "pour que le groupe 'libvirt' prenne effet, puis lance :"
echo "    cd p1 && vagrant up --no-parallel"
echo "============================================================"
