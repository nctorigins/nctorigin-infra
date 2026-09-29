#!/usr/bin/env bash
# turn-secret.sh — donne au jeu le secret du relais, et rien d'autre.
#
# CE QUE FAIT LA PAROLE EN DIRECT, pour savoir de quoi on parle : les quatre
# appareils d'une table se parlent **de pair à pair**. Aucun média ne passe par
# cette machine — pas de mixage, pas de transcodage, pas de bande passante. Le
# serveur de jeu ne fait que dire qui est dans la salle et porter les quelques
# messages techniques qui permettent aux appareils de se trouver.
#
# Il ne lui manque qu'une chose : de quoi délivrer des identifiants TEMPORAIRES
# pour `coturn`, le relais de secours utilisé quand un réseau refuse le direct.
# Ces identifiants sont calculés — un nom qui porte son échéance, un mot de passe
# qui est l'empreinte de ce nom par le secret partagé — donc il n'y a aucun compte
# à créer, aucun à révoquer, aucune base à tenir.
#
# Le secret vit dans /etc/turnserver.conf, que le jeu ne peut pas lire : il ne
# tourne pas en root, et il n'a pas à le faire. Ce script le recopie, une fois,
# dans un fichier d'environnement que l'unité systemd lit.
#
# À LANCER AVEC sudo, UNE FOIS :
#     sudo bash services/nctgame/turn-secret.sh
#
# Idempotent : relancé, il constate et ne réécrit que si le secret a changé.
#
# CE QU'IL NE FAIT PAS : toucher à coturn, à Prosody, à Jitsi ou à nginx. Il lit
# un fichier et en écrit un autre. Le seul service redémarré est le jeu.
set -euo pipefail

# Substituables pour pouvoir ÉPROUVER ce script sans toucher à la machine : un
# script qui ne s'exécute que pour de vrai est un script qu'on ne rejoue jamais, et
# celui-ci s'est déjà arrêté deux fois au milieu.
TURN_CONF="${TURN_CONF:-/etc/turnserver.conf}"
ENV_FILE="${ENV_FILE:-/etc/nctgame/live-voice.env}"
# Un FRAGMENT d'unité, et pas une modification de l'unité principale : celle-ci
# est posée par `bootstrap.sh` depuis un modèle, donc la réécrire ici serait
# écrasé au prochain passage. Le fragment, lui, survit et s'additionne.
#
# Il existe parce que le défaut est arrivé : le secret avait été écrit, le service
# redémarré, le script avait dit « ✓ » — et l'unité installée, plus ancienne que le
# modèle, ne lisait aucun fichier d'environnement. La configuration était donc
# absente, le redémarrage avait détruit les parties en cours pour rien, et rien ne
# le disait. Un script qui annonce un succès qu'il n'a pas vérifié est pire que
# celui qui échoue.
FRAGMENT="${FRAGMENT:-/etc/systemd/system/nctgame.service.d/live-voice.conf}"

rouge() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
vert()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
jaune() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
dit()   { printf '  %s\n' "$*"; }

# --- Redémarrer : jamais sans le demander ------------------------------------
# UN REDÉMARRAGE N'EST PAS ANODIN SUR CETTE MACHINE, qui porte quatre services :
#
#   * `nctgame` garde les parties EN MÉMOIRE. Le redémarrer ne coupe pas des
#     sockets, il DÉTRUIT toutes les parties en cours — chaque table perd la
#     sienne, au milieu d'un coup. C'est la coupure la plus coûteuse d'ici, et
#     elle est invisible pour qui ne le sait pas.
#   * `coturn` est partagé avec Jitsi : le redémarrer coupe les appels en cours
#     qui passent par le relais.
#   * `prosody` et `jicofo` coupent toutes les conférences en cours.
#
# On demande donc, avec NON par défaut, et on imprime la commande pour plus tard.
# `INTERACTIF=0` (la convention de ce dépôt) ne redémarre rien : un automate ne
# décide pas d'une coupure de service.
INTERACTIF=${INTERACTIF:-1}
# Témoin : un redémarrage a-t-il VRAIMENT eu lieu ? La vérification qui suit n'a
# de sens qu'après — sans ce témoin, un script appelé par un autre avertissait
# « le service tourne sans le réglage » juste avant que l'appelant ne le
# redémarre. Un faux signal fait chercher une panne qui n'existe pas.
A_REDEMARRE=0

redemarrer() {
    local service="$1" cout="$2" reponse
    systemctl list-unit-files "$service.service" >/dev/null 2>&1 || return 0
    if [ "$INTERACTIF" != "1" ] || [ ! -t 0 ]; then
        jaune "$service n'est PAS redémarré (sans question)."
        dit "Quand la coupure est acceptable : sudo systemctl restart $service"
        return 0
    fi
    jaune "Redémarrer $service coupe : $cout"
    read -rp "  Redémarrer $service maintenant ? [o/N] " reponse </dev/tty || true
    if [[ "${reponse,,}" =~ ^(o|oui|y|yes)$ ]]; then
        systemctl restart "$service" && vert "$service redémarré" && A_REDEMARRE=1
    else
        jaune "$service non redémarré — le réglage ne prendra effet qu'après."
        dit "Quand la coupure est acceptable : sudo systemctl restart $service"
    fi
}

# `ROOT_REQUIS=0` n'existe que pour les épreuves, qui écrivent dans un bac à sable.
if [ "${ROOT_REQUIS:-1}" = 1 ] && [ "$(id -u)" -ne 0 ]; then
    rouge "À lancer avec sudo."; exit 1
fi
[ -r "$TURN_CONF" ] || { rouge "Introuvable : $TURN_CONF — coturn est-il installé ?"; exit 1; }

SECRET="$(sed -n 's/^static-auth-secret=//p' "$TURN_CONF" | head -1)"
if [ -z "$SECRET" ]; then
    rouge "Pas de static-auth-secret dans $TURN_CONF."
    dit "coturn doit être en mode secret partagé. Dans $TURN_CONF :"
    dit "    use-auth-secret"
    dit "    static-auth-secret=<32 caractères au hasard>"
    dit "puis : sudo systemctl restart coturn"
    exit 1
fi
grep -qE '^\s*use-auth-secret' "$TURN_CONF" || \
    jaune "use-auth-secret n'est pas activé dans $TURN_CONF : le relais refusera"

# Le nom du relais tel que les téléphones le joindront. On le prend du royaume
# déclaré par coturn plutôt que de le demander : c'est le même nom que celui du
# certificat, et le faire taper serait une occasion de se tromper.
HOTE="$(sed -n 's/^realm=//p' "$TURN_CONF" | head -1)"
[ -n "$HOTE" ] || HOTE="meet.nctorigin.com"
PORT="$(sed -n 's/^listening-port=//p' "$TURN_CONF" | head -1)"
[ -n "$PORT" ] || PORT=3478

mkdir -p /etc/nctgame
NOUVEAU="$(printf '%s\n' \
    "# Parole en direct de NCTGame : le secret du relais coturn." \
    "# Recopié de $TURN_CONF par services/nctgame/turn-secret.sh." \
    "# Le changer demande de le changer DES DEUX CÔTÉS — ce fichier n'est pas la" \
    "# source, $TURN_CONF l'est." \
    "NCTGAME_TURN_SECRET=$SECRET" \
    "NCTGAME_TURN_HOST=$HOTE" \
    "NCTGAME_TURN_PORT=$PORT")"

# `exit 0` ici serait un piège, et il l'a été : un fichier déjà correct faisait
# sortir le script AVANT la pose du fragment d'unité, donc relancer ne réparait
# jamais l'oubli qui empêche le service de lire ce fichier. On ne saute que
# l'écriture, jamais la suite.
if [ -f "$ENV_FILE" ] && [ "$(cat "$ENV_FILE")" = "$NOUVEAU" ]; then
    vert "Secret du relais déjà à jour dans $ENV_FILE"
else
    printf '%s\n' "$NOUVEAU" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    vert "Secret du relais écrit dans $ENV_FILE (600, root)"
fi
dit "Relais annoncé aux joueurs : $HOTE:$PORT"

# --- Faire LIRE le fichier par le service ------------------------------------
mkdir -p "$(dirname "$FRAGMENT")"
printf '%s\n' \
    "# Posé par services/nctgame/turn-secret.sh : fait lire $ENV_FILE au service." \
    "# Le tiret tolère un fichier absent — une fonction facultative ne doit pas" \
    "# empêcher le jeu de démarrer." \
    "[Service]" \
    "EnvironmentFile=-$ENV_FILE" > "$FRAGMENT"
systemctl daemon-reload
vert "Fragment d'unité posé : $FRAGMENT"

# Le fichier est écrit et déclaré ; il ne sera LU qu'au prochain démarrage.
redemarrer nctgame "toutes les parties en cours, qui vivent en mémoire"

# --- VÉRIFIER, au lieu de l'annoncer ----------------------------------------
# On regarde l'environnement du processus qui tourne, pas ce qu'on vient
# d'écrire : c'est la seule preuve que la configuration est arrivée là où elle
# sert. Sans ce contrôle, ce script a déjà menti une fois.
PID="$(systemctl show nctgame -p MainPID --value 2>/dev/null)"
if [ "$A_REDEMARRE" != 1 ]; then
    dit "Service non redémarré : rien à vérifier pour l'instant."
elif [ -n "$PID" ] && [ "$PID" != 0 ] && [ -r "/proc/$PID/environ" ]; then
    if tr '\0' '\n' < "/proc/$PID/environ" | grep -q '^NCTGAME_TURN_SECRET='; then
        vert "Vérifié : le service qui tourne a bien le secret du relais"
    else
        jaune "Le service tourne SANS le secret : la parole en direct répondra"
        jaune "live_voice_not_configured. Il n'a pas encore été redémarré depuis"
        jaune "la pose du fragment — c'est le redémarrage qui le lui donnera."
    fi
else
    jaune "Service arrêté ou environnement illisible : rien n'est vérifié."
fi

printf '\n'
jaune "DEUX LIMITES À CONNAÎTRE, parce qu'elles ne se voient pas d'ici :"
dit "1. L'UDP $PORT doit être ouvert dans le pare-feu de HETZNER. Sans lui, le"
dit "   relais de secours est inutilisable — et il ne sert justement qu'aux"
dit "   réseaux qui n'ont pas d'autre chemin."
dit "2. Tant que 'no-tcp' est dans $TURN_CONF, coturn n'écoute QU'EN UDP. Un"
dit "   joueur derrière un réseau qui bloque l'UDP n'aura pas de voix du tout."
dit "   Pour lui ouvrir le TCP : services/nctgame/turn-tcp.sh"
