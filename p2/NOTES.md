# Antisèche p2 — à relire avant la peer-evaluation

Notes de compréhension sur les objets Kubernetes utilisés dans `confs/`.
Enrichi au fur et à mesure de la construction du projet.

---

## Le modèle du Service (à savoir réexpliquer)

> Kubernetes lit la déclaration du Service. Un contrôleur **souscrit** aux
> changements de Pods et maintient un registre (`Endpoints`) des IP des Pods
> **étiquetés** `app=app2` et **Ready**. Quand une requête arrive sur l'IP:port
> du Service, le **noyau** réécrit sa destination vers une de ces IP, tirée au
> hasard.

Les trois nuances qui font la différence en défense :

| Formulation approximative | Formulation juste |
|---|---|
| « les Pods qui s'appellent app2 » | les Pods **étiquetés** `app=app2` (le nom réel est `app2-7d9f8c-x4k2p`) |
| « le contrôleur demande en boucle » | il **souscrit** (watch) : l'API lui pousse les événements, ce n'est pas du polling |
| « il route vers les Pods up » | vers les Pods **Ready** (c'est le rôle de la `readinessProbe`) |
| « Kubernetes redirige la requête » | **aucun proxy dans le chemin** : `kube-proxy` pré-écrit des règles iptables, le noyau réécrit l'adresse de destination |

---

## Le piège n°1 : label ≠ nom

Il n'y a **aucune variable** dans les YAML. Chaque `app2` est une chaîne
littérale indépendante. Trois mécanismes différents coexistent :

| Mécanisme | Où | Rôle |
|---|---|---|
| **Identifiant** | `metadata.name` | clé unique de l'objet dans le cluster |
| **Étiquette + requête** | `labels:` / `selector:` | comme du CSS : `.app2` n'est déclaré nulle part, le navigateur *sélectionne* ce qui correspond |
| **Référence par nom** | `configMap.name`, `service.name` (Ingress) | va réellement chercher l'objet par son nom |

**Le nom et le selector regardent dans deux directions opposées :**
- le **nom** du Service regarde vers le haut → c'est par lui que l'Ingress l'appelle
- le **selector** regarde vers le bas → c'est par lui qu'il trouve ses Pods

⚠️ Une erreur de selector ne produit **aucune erreur** : les Pods tournent, mais
le Service a 0 endpoint et le curl renvoie `503`.
Exception : un `selector` de Deployment qui ne matche pas son propre `template`
est rejeté par l'API — c'est le seul cas protégé.

⚠️ Si deux Deployments différents étiquetaient leurs Pods `app=app2`, le Service
ramasserait **les deux** sans broncher (c'est ce qui permet les déploiements
canary). D'où des labels bien distincts : `app1`, `app2`, `app3`.

---

## Les 3 familles d'IP

| Plage | Quoi | Joignable depuis l'hôte ? |
|---|---|---|
| `192.168.56.110` | la VM | ✅ oui — **seule porte d'entrée** |
| `10.43.x.x` | les Services (ClusterIP) | ❌ non |
| `10.42.x.x` | les Pods | ❌ non |

Une ClusterIP n'est posée sur **aucune carte réseau** (introuvable dans
`ip addr`) : c'est une adresse virtuelle qui n'existe que par les règles
iptables écrites par `kube-proxy` **dans la VM**. Et elle est attribuée
dynamiquement, donc imprévisible.

👉 D'où la nécessité de l'Ingress : une seule IP + un seul port (80) pour
trois applications. Le seul critère qui reste pour les distinguer est **dans le
contenu HTTP** : l'en-tête `Host`.

Les trois Services peuvent tous utiliser le port 80 sans conflit : un port est
toujours attaché à une adresse, et ils ont trois IP différentes.

---

## La chaîne des ports

```
Ingress port.number: 80  →  Service 10.43.12.7:80  →  Pod 10.42.0.8:80
                            (port)      (targetPort)   (nginx)
```

- `port` = le port **sur la ClusterIP** (« où frappe-t-on le Service ? »)
- `targetPort` = le port **sur le Pod** (« où transmettre ? »)
- équivalent Docker : `-p port:targetPort`
- `containerPort` dans le Deployment est **purement documentaire** (supprimable)

Un seul port est visible de l'extérieur : **le 80 de Traefik sur la VM**. Les
autres sont internes, alignés sur 80 par simple convention. Seules vraies
contraintes : nginx écoute sur 80 (imposé par l'image) et le sujet teste
`curl 192.168.56.110` sans port (donc Traefik doit occuper le 80 de la VM).

---

## L'Ingress

**Un Ingress ne fait rien** : c'est une table de routage déclarative. Le moteur,
c'est **Traefik** (l'Ingress Controller livré avec K3s) : il écoute sur le port
80 de la VM, souscrit aux objets Ingress et reconfigure son routage à la volée.

### Pourquoi `curl -H "Host: app1.com"` suffit (aucun DNS)

`curl` ouvre la connexion vers **l'IP** — le domaine `app1.com` n'est jamais
résolu. Il écrit juste l'en-tête texte `Host: app1.com` dans la requête, et
c'est cette chaîne que Traefik lit pour décider.
*(Dans un navigateur, il faudrait ajouter `192.168.56.110 app1.com app2.com`
dans `/etc/hosts`, car un navigateur, lui, résout le nom.)*

### La règle par défaut : une absence

```yaml
- host: app1.com     # règle 1 : teste l'en-tête Host
    ...
- http:              # règle 3 : AUCUN champ host -> matche tout
    ...
```

`host` est facultatif. Absent, la règle ne teste aucun nom d'hôte et matche
n'importe quelle valeur — y compris une IP brute (`curl 192.168.56.110` envoie
littéralement `Host: 192.168.56.110`).

### Pourquoi app1.com ne tombe pas dans la règle par défaut

Ce n'est **pas** l'ordre du fichier : Traefik traduit chaque règle en route
pondérée et **la plus spécifique gagne**.

| Règle | Route Traefik | Spécificité |
|---|---|---|
| 1 | ``Host(`app1.com`) && PathPrefix(`/`)`` | 2 conditions → prioritaire |
| 3 | ``PathPrefix(`/`)`` | 1 condition → filet de sécurité |

### Où voir la règle par défaut (vérifié sur le cluster)

⚠️ `kubectl get ingress` **n'affiche PAS** la règle sans host :

```
NAME           CLASS     HOSTS               ADDRESS          PORTS
apps-ingress   traefik   app1.com,app2.com   192.168.56.110   80
```

C'est `kubectl describe ingress apps-ingress` qui la montre, sous la forme
d'un `*` — et c'est LA commande à sortir en défense :

```
Rules:
  Host        Path  Backends
  ----        ----  --------
  app1.com
              /   app1:80 (10.42.0.9:80)
  app2.com
              /   app2:80 (10.42.0.10:80,10.42.0.12:80,10.42.0.11:80)
  *
              /   app3:80 (10.42.0.13:80)
```

Cette seule sortie prouve **tout** d'un coup :
- le routage par host (app1.com, app2.com)
- la **règle par défaut** (`*`)
- les **3 répliques** d'app2 (trois IP de Pods derrière le Service)

`spec.defaultBackend` serait fonctionnellement équivalent, mais apparaîtrait
dans une ligne `Default backend:` séparée plutôt que parmi les règles.

---

## Démonstration en direct : inventer un host devant le correcteur

Le plus visuel pour prouver la règle par défaut : créer un nom d'hôte à la
volée et montrer qu'il tombe sur app3.

```bash
sudo sh -c 'echo "192.168.56.110 nimportequoi.com" >> /etc/hosts'
```

Puis ouvrir **http://nimportequoi.com** dans le navigateur → page rouge,
« Hello from app3 ».

Ce que ça démontre : aucune machine ne s'appelle `nimportequoi.com`, rien n'a
été configuré côté cluster, et pourtant ça répond. La règle sans `host` de
l'Ingress attrape **tout** ce qui ne matche ni app1.com ni app2.com.

Rappel de la même ligne pour app1 et app2 (nécessaire seulement pour le
navigateur, jamais pour curl) :

```bash
sudo sh -c 'echo "192.168.56.110 app1.com app2.com" >> /etc/hosts'
```

⚠️ Toujours taper `http://` devant : sinon le navigateur tente HTTPS et rien
n'écoute sur le port 443.

**Avec curl, aucune entrée n'est nécessaire** — curl se connecte à l'IP et
fabrique l'en-tête lui-même :

```bash
curl -H "Host: nimportequoi.com" 192.168.56.110
```

C'est la différence à savoir expliquer : le navigateur doit **résoudre** le nom
(donc `/etc/hosts`), curl non.

Pour nettoyer après la correction :

```bash
sudo sed -i '/192.168.56.110/d' /etc/hosts
```

---

## Commandes de debug

```bash
kubectl get endpoints app2     # le carnet d'adresses : <none> = le selector ne matche rien
kubectl get pods -l app=app2   # exécute à la main la requête par label du Service
kubectl describe ingress       # voir les règles de routage telles que Traefik les lit
kubectl get ingressclass       # vérifier que la classe "traefik" existe bien
```

### Isoler une panne : tester depuis l'INTÉRIEUR du cluster

```bash
kubectl run test --rm -it --image=curlimages/curl -- curl http://app1
```

Si ça marche **dans** le cluster mais que `curl -H "Host: app1.com"
192.168.56.110` échoue depuis l'hôte, le problème est dans l'Ingress ou
Traefik — ni dans l'app, ni dans le Service.

---

## Preuve des 3 répliques d'app2

Le `curl` ne prouve **rien** (les 3 Pods servent le même HTML). La preuve est
côté `kubectl`.

Se connecter à la VM :

```bash
cd ~/Bureau/iot/p2
vagrant ssh imaalemS
```

Puis, dans la VM :

```bash
kubectl get deployment app2
```
```bash
kubectl get pods -l app=app2 -o wide
```

`READY 3/3` d'un côté, trois Pods avec trois IP différentes de l'autre.

Le `-l app=app2` est intéressant à commenter : tu exécutes à la main la
**requête par label** que le Service pose en interne pour trouver ses Pods.

### Démo d'auto-réparation

Supprimer un Pod devant le correcteur et montrer que le Deployment le recrée :

```bash
kubectl get pods -l app=app2
```
```bash
kubectl delete pod $(kubectl get pods -l app=app2 -o jsonpath='{.items[0].metadata.name}')
```
```bash
kubectl get pods -l app=app2
```

Le troisième affichage montre un Pod en `ContainerCreating` avec un nom neuf :
le Deployment a déjà réagi. C'est la démonstration la plus courte de ce
qu'apporte Kubernetes par rapport à `docker run`.

⚠️ Ne **pas** faire `kubectl delete pod -l app=app2 | head -1` : ça supprime
les **3** Pods, `head` ne filtre que l'affichage. D'où le `jsonpath` qui cible
`items[0]`, un seul Pod.

---

## Rappels d'environnement

- **Avant tout `vagrant up` en p2 : arrêter la p1** (`cd p1 && vagrant halt`).
  Les deux VM se disputent l'IP `192.168.56.110` et le nom de domaine libvirt
  `imaalemS`.
- **Différence majeure avec le `server.sh` de p1** : ne surtout **pas** reprendre
  `--disable traefik`. En p2, Traefik est le composant qui exécute l'Ingress.
- `server.vm.network "private_network", ip: "192.168.56.110"` donne simplement
  à la VM cette IP, joignable directement depuis l'hôte — c'est ce qui fait
  marcher le `curl`. Si le curl échoue un jour :
  `vagrant ssh imaalemS -c "ip -br addr show"` et vérifier que l'IP est là.
