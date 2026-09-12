# p2 — K3s et trois applications routées par un Ingress

Une seule VM Debian (`imaalemS`, `192.168.56.110`) avec K3s en mode server, et
trois applications web routées par nom d'hôte :

| Requête | Application |
|---|---|
| `Host: app1.com` | app1 |
| `Host: app2.com` | app2 (**3 répliques**) |
| tout le reste | app3 (règle par défaut) |

## Prérequis de l'hôte

Vagrant + le plugin **vagrant-libvirt**, libvirt/KVM et QEMU doivent être
installés. Le script à la racine du dépôt s'en charge (commun à p1 et p2) :

```bash
sudo bash ../host-setup.sh
```

Puis se déconnecter/reconnecter (pour que le groupe `libvirt` prenne effet).

## Avant de lancer : détruire la p1

La p1 et la p2 se disputent l'IP `192.168.56.110` **et** le nom de domaine
libvirt `imaalemS` (libvirt exige des noms uniques). Les parties du projet étant
corrigées les unes après les autres, on détruit la précédente :

```bash
cd ../p1 && vagrant destroy -f
```

Rien n'est perdu : le code reste, `vagrant up` reconstruit la p1 à l'identique.

## Lancement

```bash
cd p2
vagrant up
```

Le provisioning (`scripts/k3s-server.sh`) installe K3s **avec Traefik**, attend
que le cluster et Traefik soient prêts, puis applique tous les manifests de
`confs/`. Il affiche `kubectl get all` et `kubectl get ingress` en fin de course.

## Tests

```bash
curl -H "Host: app1.com" 192.168.56.110    # -> Hello from app1
curl -H "Host: app2.com" 192.168.56.110    # -> Hello from app2
curl 192.168.56.110                         # -> Hello from app3 (défaut)
```

Vérifier l'état du cluster :

```bash
vagrant ssh imaalemS -c "kubectl get all"
vagrant ssh imaalemS -c "kubectl get ingress"
vagrant ssh imaalemS -c "kubectl get deployment app2"   # -> READY 3/3
```

### Script de vérification

Enchaîne les tests de routage et les preuves des 3 répliques :

```bash
./scripts/check_apps.sh
./scripts/check_apps.sh --demo    # + démo d'auto-réparation d'un Pod
```

## Structure

```
p2/
├── Vagrantfile              une VM libvirt, 1 CPU / 1024 Mo
├── confs/
│   ├── app1.yaml            ConfigMap + Deployment + Service
│   ├── app2.yaml            idem, avec replicas: 3
│   ├── app3.yaml            idem (application par défaut)
│   └── ingress.yaml         routage par host + règle par défaut
├── scripts/
│   ├── k3s-server.sh        provisioning : K3s + kubectl apply
│   └── check_apps.sh        vérification (peer-evaluation)
├── NOTES.md                 antisèche pour la défense
└── README.md
```

## Pour la défense

Voir [NOTES.md](NOTES.md) : le modèle du Service, le piège label ≠ nom, la
chaîne des ports, et surtout **comment l'Ingress exprime la règle par défaut**.
