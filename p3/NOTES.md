# Antisèche p3 — à relire avant la peer-evaluation

---

## ⚡ La commande à garder sous la main

Argo CD interroge le dépôt GitHub **toutes les ~3 minutes** par défaut. Pendant
la correction, c'est très long. Cette commande force une vérification immédiate :

```bash
kubectl -n argocd patch application playground --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

**Mesuré sur ce cluster :** 181 s sans elle, **5 s avec**.

Elle est déjà intégrée à `./scripts/check_p3.sh --switch`, qui joue toute la
démonstration (bascule la version dans GitHub, pousse, force le rafraîchissement,
vérifie le redéploiement).

---

## La question du sujet : K3s vs K3d

> *« First of all, you must understand the difference between K3s and K3d. »*

| | K3s (p1, p2) | K3d (p3) |
|---|---|---|
| C'est quoi | une **distribution** Kubernetes légère | un **outil** qui lance K3s dans Docker |
| Un node = | une vraie machine (VM Vagrant) | **un conteneur Docker** |
| Création | `vagrant up` + installation, ~8 min | `k3d cluster create`, ~50 s |
| Suppression | `vagrant destroy` | `k3d cluster delete` |

**En une phrase : K3d, c'est K3s empaqueté dans Docker.**

La preuve en deux commandes (elle est dans `check_p3.sh`) :

```
Kubernetes voit :   k3d-iot-server-0   Ready   control-plane
Docker voit     :   k3d-iot-server-0   rancher/k3s:v1.35.5-k3s1
```

C'est le **même objet**. Ce que Kubernetes appelle un « node » est un conteneur.

---

## Le GitOps en une phrase

Argo CD est encore une **boucle de réconciliation** (comme le Deployment en p2),
mais la source de vérité change : ce n'est plus un objet stocké dans le cluster,
c'est **le dépôt Git**.

```
  Dépôt GitHub public          Argo CD (ns argocd)          Cluster (ns dev)
  deployment.yaml       ──►    compare en continu    ──►    Pod playground
  image: ...:v1                et corrige l'écart
```

On modifie `v1` → `v2` dans Git, on pousse, et le Pod est remplacé **sans aucun
`kubectl apply`**. C'est ce que le correcteur veut voir.

---

## L'objet `Application`

⚠️ **Piège classique** : l'objet `Application` vit dans le namespace **`argocd`**,
pas dans `dev`. Il *décrit* un déploiement, il n'en fait pas partie — c'est le
contrôleur Argo CD (qui tourne dans `argocd`) qui le lit.

`kind: Application` n'existe que parce qu'Argo CD a installé la **CRD**
correspondante. C'est une extension du cluster, pas un type Kubernetes natif.

Ses trois blocs :

| Bloc | Répond à |
|---|---|
| `source` | **où est la vérité** → le dépôt GitHub, branche par défaut, racine |
| `destination` | **où déployer** → ce cluster, namespace `dev` |
| `syncPolicy.automated` | **comment** → automatiquement |

Sans `automated`, Argo CD détecterait l'écart mais attendrait un clic sur
« Sync ». Les deux options qui comptent :
- `prune: true` — supprime du cluster ce qui est retiré de Git
- `selfHeal: true` — annule toute modification faite à la main (`kubectl edit`)

---

## La chaîne des ports

```
curl localhost:8888
      │
      ▼  conteneur k3d-iot-serverlb   (mapping -p "8888:30080@loadbalancer")
      ▼  node, port 30080             (nodePort)
      ▼  Service, port 8888           (port)
      ▼  Pod, port 8888               (targetPort)
```

Pourquoi `NodePort` ici alors qu'on avait `ClusterIP` en p2 ? En p2, Traefik
était **dans** le cluster et pouvait joindre une ClusterIP. Ici l'appel vient de
**l'extérieur de Docker** : il faut un port ouvert sur le node.

⚠️ Le `nodePort: 30080` du dépôt GitHub doit correspondre exactement au mapping
`-p "8888:30080@loadbalancer"` de `setup.sh`. C'est le seul couplage entre les
deux dépôts.

---

## Le piège de l'installation d'Argo CD

`kubectl apply -f install.yaml` échoue avec :

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Pourquoi :** `kubectl apply` en mode client recopie le manifest entier dans une
annotation `last-applied-configuration` pour calculer les diffs futurs. Les CRD
d'Argo CD dépassent la limite de 256 Ko d'etcd.

**Correctif** (déjà dans `setup.sh`) : `--server-side --force-conflicts`.
L'apply côté serveur suit les champs via `managedFields` et n'a pas cette limite.

---

## Interface web Argo CD (optionnelle, mais elle fait bon effet)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

puis <https://localhost:8080> — identifiant `admin`, mot de passe dans
`p3/.argocd-password` (gitignoré).

---

## Commandes de debug

```bash
kubectl -n argocd get application                   # Synced / Healthy ?
kubectl -n argocd describe application playground   # detail des ecarts Git <-> cluster
kubectl -n dev get all                              # ce qu'Argo CD a reellement deploye
kubectl -n dev get deployment playground \
  -o jsonpath='{.spec.template.spec.containers[0].image}'   # quelle version ?
kubectl logs -n argocd statefulset/argocd-application-controller --tail=50
```

Si l'Application reste `OutOfSync` ou `Unknown` : vérifier que le dépôt GitHub
est bien **public** (Argo CD le clone anonymement en HTTPS) —
`curl -o /dev/null -w "%{http_code}" https://github.com/nessrinemaalem/imaalem-iot-app`
doit renvoyer `200`.
