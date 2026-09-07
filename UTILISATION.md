# Utilisation

Ce que font `bootstrap.sh` et le dump de la base, commande par commande.

Deux scripts, deux dépôts, deux rôles :

| | où | à quoi il sert |
|---|---|---|
| `bootstrap.sh` | `nctorigin-infra` | poser les services sur une machine |
| `deploy/db.sh` | `nctgame_server` | sortir la base et la remettre ailleurs |

Les deux se rejoignent sur une machine neuve : `bootstrap.sh` installe, trouve un
dump s'il y en a un, et propose de le restaurer.

---

# 1. `bootstrap.sh`

```
sudo ./bootstrap.sh                    demande quoi installer
sudo ./bootstrap.sh nctgame            un service
sudo ./bootstrap.sh nctgame quran      plusieurs
sudo ./bootstrap.sh --tout             les quatre
./bootstrap.sh --etat                  ne touche à rien
./bootstrap.sh --help                  l'aide du script
```

Les quatre services connus : **`nctgame`**, **`quran`**, **`whisper`**,
**`jitsi`**.

## 1.1 Voir où on en est

```
./bootstrap.sh --etat
```

Sans `sudo`, sans rien modifier. C'est la commande à taper en premier quand on
arrive sur une machine dont on ne sait rien.

```
  SERVICE    DOMAINE                          UNITÉ    NGINX    TLS
  nctgame    game.nctorigin.com               actif    posé     oui
  quran      quran-recognizer.nctorigin.com   actif    posé     oui
  whisper    whisper.nctorigin.com            actif    posé     oui
  jitsi      meet.nctorigin.com               actif    posé     oui
```

**`TLS` à `?` n'est pas une absence de certificat** : c'est que le script n'a pas
le droit de lire `/etc/letsencrypt`. Relancez avec `sudo` pour trancher. Cette
distinction est délibérée — confondre « absent » et « je n'ai pas regardé » a
déjà coûté deux fausses pistes dans ce projet.

## 1.2 Installer

```
sudo ./bootstrap.sh                # il demande
sudo ./bootstrap.sh nctgame        # ou on lui dit
sudo ./bootstrap.sh --tout
```

Il pose d'abord le socle — paquets, compte de service, groupes, ports — puis
chaque service demandé. Un service qui échoue n'arrête pas les autres : le
résumé final les nomme, et **relancer reprend où l'on s'est arrêté** sans
défaire ce qui a réussi.

Un nom de service inconnu est refusé **avant** que `sudo` ne soit exigé : une
faute de frappe n'a pas à coûter une saisie de mot de passe.

## 1.3 Sans questions

```
INTERACTIF=0 sudo ./bootstrap.sh --tout
```

Chaque question prend alors sa réponse par défaut. Utile depuis un autre script,
ou dans une image. **Attention** : sans clavier, une attente de DNS ne peut pas
attendre — le script s'arrête au lieu de boucler.

## 1.4 Les variables

| | défaut | |
|---|---|---|
| `APP_USER` | `whisper` | le compte qui porte les services |
| `COURRIEL` | *(vide)* | adresse donnée à Let's Encrypt |
| `INTERACTIF` | `1` | `0` pour ne rien demander |

```
APP_USER=jeu COURRIEL=ops@nctorigin.com sudo -E ./bootstrap.sh nctgame
```

`sudo -E` est nécessaire pour que les variables traversent.

## 1.5 Ce qu'il demande, et pourquoi

Le script ne s'arrête pas devant ce qu'il ne peut pas faire — il vous le fait
faire.

**Le DNS.** Si le domaine ne pointe pas encore vers la machine, il affiche
l'enregistrement exact à créer — type, nom, valeur, TTL — puis **attend et
revérifie toutes les trente secondes**. Vous créez l'entrée dans un autre
onglet, et il repart seul. Sans cela, certbot échoue d'une façon qui n'explique
rien.

**La publicité** (nctgame). Éteinte par défaut : sans `data/ads.json`, le serveur
répond `{"enabled": false}` à tout le monde, ce qui est l'état voulu. Il demande
avant d'allumer, et prévient que sans compte AdMob l'application n'affichera que
les blocs d'essai de Google.

**La base de données** (nctgame). S'il trouve un dump, il propose de le
restaurer. Il ne remplace **jamais** une base existante sans le demander.

**La preuve d'identité** (nctgame). Sur une machine neuve il n'y a aucun appareil
ancien à ménager : il propose de l'exiger dès le départ, ce qui ne coûte rien
qu'à ce moment-là.

**La clef d'administration** (nctgame). Fabriquée, jamais restaurée, et jamais
affichée — le script dit où la lire au moment de la transmettre.

**La clef d'API** (whisper). Sans elle le service refuse tout, y compris à son
propriétaire. Il propose d'en fabriquer une, et prévient qu'elle ne sera plus
jamais montrée.

**Jitsi** ne s'installe pas comme les autres : le script rappelle les trois
choses qu'il ne peut pas faire — dont **l'UDP 10000 à ouvrir dans la console
Hetzner**, sans quoi tout paraît correct et la vidéo ne passe pas — puis
propose de lancer `v3.1-safe`, le seul des sept scripts qui sache que la machine
héberge déjà autre chose.

## 1.6 Le relancer ne casse rien

C'est une propriété, pas une tolérance. Sur une machine installée, `bootstrap.sh`
met le code à jour, réinstalle les dépendances, réécrit les configurations et
redémarre — sans rien dupliquer.

C'est aussi **la seule façon de l'éprouver** sans machine vierge sous la main :
un script d'installation qu'on ne lance qu'une fois est un script qu'on
n'éprouve jamais, et qui échoue le jour où il compte.

Il ne touche pas à un dépôt qui a des modifications non enregistrées : il le
signale et passe. Installer proprement ne vaut pas d'écraser le travail de
quelqu'un.

---

# 2. `deploy/db.sh` — sortir la base, la remettre

Depuis `nctgame_server`.

```
deploy/db.sh dump              écrit data/dumps/nctgame-<date>.sql.gz
deploy/db.sh dump <fichier>    écrit où vous voulez
deploy/db.sh restore <fichier> remplace la base par ce fichier
deploy/db.sh list              les sauvegardes présentes
```

## 2.1 Sortir la base

```
deploy/db.sh dump
```

Fonctionne **pendant que le service tourne**. Résultat : une douzaine de
kilo-octets.

```
  source : /home/whisper/nctgame_server/data/nctgame.db
  ✓ écrit : data/dumps/nctgame-20260907T162843.sql.gz (12K)
  ✓ vérifié : rechargé, et chaque table a le même effectif
      game_results=444
      players=22
```

La seconde ligne est la moitié utile de la commande : **le dump est rechargé
dans une base jetable et comparé table par table à l'original.** Un dump qu'on
ne sait pas relire n'est pas une sauvegarde ; la vérification coûte une seconde
et transforme un espoir en fait.

**Pourquoi pas un `cp`.** La base est en mode WAL : les écritures récentes vivent
dans `nctgame.db-wal` et n'entrent dans le fichier principal qu'au point de
contrôle suivant — trois mégaoctets en attente, mesurés sur cette machine.
Copier `nctgame.db` seul donnerait une base amputée de tout ce qui vient d'être
joué, **et elle s'ouvrirait sans erreur**, ce qui est la pire façon d'avoir tort.

## 2.2 La remettre

```
deploy/db.sh restore data/dumps/nctgame-20260907T162843.sql.gz
```

Trois précautions, dans cet ordre :

1. **si le service tourne**, il est arrêté puis relancé — deux écrivains sur le
   même fichier donneraient deux vérités ;
2. **la base présente est mise de côté**, datée, jamais écrasée en silence.
   Restaurer la mauvaise sauvegarde est une erreur qu'on ne fait qu'une fois, et
   qu'on ne peut défaire que si l'ancienne existe encore ;
3. **la nouvelle base est construite et lue en entier avant de remplacer quoi
   que ce soit.** Un fichier abîmé est refusé et laisse la machine exactement
   comme elle était.

Restaurer ailleurs — pour vérifier une sauvegarde, ou préparer une autre
machine — ne concerne pas le service :

```
NCTGAME_DB=/tmp/essai.db deploy/db.sh restore <fichier>
```

## 2.3 Sur un serveur neuf

```
# ici
deploy/db.sh dump
# le fichier voyage comme vous voulez : scp, clef USB, courriel

# là-bas
sudo ./bootstrap.sh nctgame        # il trouve le dump et le propose
```

Ou à la main, si la base est déjà installée :

```
deploy/db.sh restore <fichier.sql.gz>
```

## 2.4 Ce que le dump ne contient pas

Il contient **la base** : profils, statistiques, historique des parties. Rien
d'autre, et c'est voulu.

| | où cela se retrouve |
|---|---|
| `data/ads.json` | quelques lignes, à réécrire ou recopier |
| la clef d'administration | **refabriquée**, jamais restaurée |
| les jetons des joueurs | dans la base — ils suivent donc le dump |
| la base d'adresses IP → pays | retéléchargée par `tools/refresh_geoip.py` |
| les journaux de partie | non — diagnostic, pas donnée |

Un secret qui voyage d'une machine à l'autre cesse d'en être un : c'est pourquoi
la clef d'administration se refait plutôt que de se copier.

---

# 3. Les autres scripts de `nctgame_server/deploy/`

Hors du sujet de ce guide, mais ils existent et se ressemblent :

| | |
|---|---|
| `require-auth.sh` | exiger la preuve d'identité ; `--wipe`, `--revert`, `--status` |
| `open-admin.sh` | ouvrir l'API d'administration ; `--rotate`, `--close`, `--status` |

Chacun porte son mode d'emploi dans son en-tête, et un `--status` qui ne modifie
rien.
