# nctorigin-infra

De quoi remonter la machine `nctorigin` depuis une Ubuntu nue.

```
sudo ./bootstrap.sh                    demande quoi installer
sudo ./bootstrap.sh nctgame            un service
sudo ./bootstrap.sh --tout             les quatre
./bootstrap.sh --etat                  ne touche à rien, dit où on en est
```

C'est **ce dépôt-ci qu'on clone en premier** sur une machine neuve : il connaît
les quatre autres, aucun d'eux ne le connaît.

**[UTILISATION.md](UTILISATION.md)** donne toutes les commandes, une par une —
celles de `bootstrap.sh` et celles du dump et de la restauration de la base.

---

## Les quatre services

| | domaine | dépôt |
|---|---|---|
| `nctgame` | game.nctorigin.com | `nctorigins/nctgame_server` |
| `quran` | quran-recognizer.nctorigin.com | `nctorigins/quran_recognizer` |
| `whisper` | whisper.nctorigin.com | `nctorigins/whisper-api` |
| `jitsi` | meet.nctorigin.com | `nctorigins/jitsi-installation` |

Ils suivent tous le même motif — un sous-domaine, un bloc nginx, un certificat
certbot, une unité systemd, un venv. C'est ce qui rend l'aiguillage économique :
`lib/common.sh` porte tout ce qui est commun, et chaque module ne dit que ce qui
lui est propre.

Ajouter un cinquième service demande une ligne dans les tables de
`bootstrap.sh` et un fichier dans `services/`.

## Trois principes, et ce qu'ils ont coûté

**Tout est idempotent.** Le script se relance sur une machine déjà installée
sans rien casser ni rien dupliquer. Ce n'est pas une élégance : un script
d'installation qu'on ne lance qu'une fois est un script qu'on n'éprouve jamais,
et qui échouera donc le jour où l'on en a besoin. On l'éprouve en le relançant
ici.

C'est pourquoi les tâches périodiques vont dans `/etc/cron.d/` plutôt que dans
un crontab : un fichier qu'on écrase ne se duplique pas, une ligne qu'on ajoute
si — quatre relances donnent quatre exécutions le même matin.

**Ce qu'il ne peut pas faire, il le fait faire.** Trois choses ne se font pas
depuis cette machine : créer un enregistrement DNS, ouvrir le pare-feu de
l'hébergeur, décider s'il faut restaurer des données. Le script ne s'arrête pas
devant. Pour le DNS il affiche l'enregistrement exact — type, nom, valeur, TTL —
puis **attend et revérifie**, si bien qu'on crée l'entrée dans un autre onglet
et qu'il repart seul. La différence avec « prérequis non satisfait, arrêt » est
tout ce qui sépare un script utilisable d'un script qu'on relance six fois.

**Rien n'est deviné quand on peut regarder.** `--etat` cherche les blocs nginx
par leur **contenu**, pas par leur nom de fichier : deux des quatre ne portent
pas celui de leur domaine. Et quand il ne peut pas lire — `/etc/letsencrypt`
sans privilèges — il affiche `?`, jamais `—`. Confondre « absent » et « je n'ai
pas le droit de voir » a coûté deux fausses pistes dans ce projet, dont une
pendant l'écriture de ce script.

## Les secrets

Ils sont **fabriqués, jamais restaurés**. Un secret qui voyage d'une machine à
l'autre cesse d'en être un.

| | |
|---|---|
| clef d'administration nctgame | `openssl rand -hex 32`, dans un fichier annexe systemd en mode 600 |
| clefs d'API whisper | `whisper-keys add`, écrites dans `.api_keys.json`, hors dépôt |
| jetons des joueurs | délivrés par le serveur à la demande |

Aucun n'est affiché par le script. Il dit où les lire, au moment où il faut les
transmettre.

## Ce que ce dépôt ne sauve pas

**Les données ne sont pas DANS ce dépôt** — profils, statistiques, historique
des parties n'y ont pas leur place. Mais elles ne sont plus laissées de côté :
`nctgame_server/deploy/db.sh` sort la base d'une machine et la remet sur une
autre, et `bootstrap.sh` cherche un dump à l'installation et propose de le
restaurer.

Il ne remplace jamais une base existante sans le demander. Voir
[UTILISATION.md](UTILISATION.md#2-deploydbsh--sortir-la-base-la-remettre).

**Ce qui est reproductible n'a pas à être sauvé** : le venv se refait depuis
`requirements.txt`, la base d'adresses IP → pays se retélécharge chez db-ip, les
certificats se redemandent à Let's Encrypt. Ces trois-là n'ont besoin que d'une
recette, et la recette est dans le script.

## Le pare-feu de Hetzner

Il n'est pas sur la machine, et rien ici ne peut l'ouvrir. Jitsi a besoin de
**l'UDP 10000** depuis la console de l'hébergeur ; sans lui tout paraît correct
et la vidéo ne passe pas. Le module Jitsi le rappelle avant de commencer plutôt
qu'après avoir échoué.
