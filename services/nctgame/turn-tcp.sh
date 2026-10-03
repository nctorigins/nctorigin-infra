#!/usr/bin/env bash
# turn-tcp.sh — ouvre le relais en TCP, pour les réseaux qui bloquent l'UDP.
#
# LE MANQUE QU'IL COMBLE. `coturn`, tel que l'installation Jitsi le pose, porte
# `no-tcp` : il n'écoute qu'en UDP. C'est suffisant presque partout — et inutile
# exactement là où un relais sert. Un réseau d'entreprise ou un opérateur mobile
# qui ne laisse passer que le TCP ne trouvera aucun chemin, et la parole en direct
# du jeu n'aura pas lieu du tout pour ce joueur.
#
# Tant que ce script n'a pas tourné, le serveur de jeu N'ANNONCE AUCUNE adresse
# TCP, et c'est volontaire : un relais qui échoue toujours n'est pas un secours,
# c'est du temps perdu en négociation. Un manque nommé vaut mieux qu'une
# couverture qui n'en est pas une.
#
# POURQUOI ON NE L'ATTEND PLUS. Nous avions dit au client de nous signaler le cas
# depuis le terrain. Il a répondu, à juste titre, que son essai ne le révélerait
# pas : un passage wifi → 4G éprouve la MOBILITÉ, pas le filtrage UDP, et ni un
# wifi domestique ni un réseau mobile ne bloquent l'UDP. Le cas se trouve dans un
# bureau, un hôtel, un hôpital, une école — des réseaux qu'on ne découvrirait
# qu'en production, par un joueur disant « la voix ne marche pas » sans pouvoir
# dire pourquoi, depuis un réseau qu'on ne verrait jamais. Attendre ce signal,
# c'était attendre quelque chose qui ne vient pas.
#
# CE QU'IL FAIT, ET CE QU'IL NE FAIT PAS. Il ouvre le TCP nu, qui ne demande que
# d'écouter. Il N'ACTIVE PAS le TLS (`turns:`), qui demande un certificat que le
# client puisse valider : celui que coturn présente sur cette machine est
# AUTO-SIGNÉ, et l'annoncer donnerait un second chemin qui échoue toujours —
# exactement la faute qu'on évite en n'annonçant pas le TCP avant qu'il écoute.
# Le script dit ce qu'il faudrait réparer, et s'arrête là.
#
#     sudo bash services/nctgame/turn-tcp.sh
#
# Idempotent. Il sauvegarde la configuration avant de la modifier.
set -euo pipefail

# Substituables, pour la même raison que dans turn-secret.sh.
TURN_CONF="${TURN_CONF:-/etc/turnserver.conf}"
UNITE="${UNITE:-/etc/systemd/system/nctgame.service.d/turn-tcp.conf}"

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

if [ "${ROOT_REQUIS:-1}" = 1 ] && [ "$(id -u)" -ne 0 ]; then
    rouge "À lancer avec sudo."; exit 1
fi
[ -w "$TURN_CONF" ] || { rouge "Introuvable ou non modifiable : $TURN_CONF"; exit 1; }

PORT="$(sed -n 's/^listening-port=//p' "$TURN_CONF" | head -1)"
[ -n "$PORT" ] || PORT=3478

# --- 1. coturn : laisser passer le TCP --------------------------------------
if grep -qE '^\s*no-tcp\s*$' "$TURN_CONF"; then
    SAUVE="$TURN_CONF.avant-tcp-$(date +%Y%m%dT%H%M%S)"
    cp -a "$TURN_CONF" "$SAUVE"
    dit "Sauvegarde : $SAUVE"
    # Commenté plutôt que supprimé : la ligne d'origine reste lisible, et le
    # retour en arrière est un caractère à retirer.
    sed -i 's/^\s*no-tcp\s*$/# no-tcp   # retiré par turn-tcp.sh/' "$TURN_CONF"
    vert "no-tcp retiré : coturn écoutera aussi en TCP sur $PORT"
    REDEMARRER=1
else
    vert "coturn accepte déjà le TCP"
    REDEMARRER=0
fi

# `no-tcp-relay` est une AUTRE chose et on n'y touche pas : il interdit de
# relayer VERS un pair en TCP, ce dont la voix n'a pas besoin. Le retirer
# ouvrirait un relais TCP sortant sans que personne l'ait demandé.
# `if` plutôt que `test && commande`, par lisibilité et rien d'autre.
#
# On a d'abord écrit ici que `set -e` arrêtait le script sur un test faux, et que
# la relance en mourait. **C'est faux** : une liste `&&` dont le test échoue
# n'arrête rien (voir la note en tête de lib/common.sh, établie en l'éprouvant).
# Le défaut qui a vraiment laissé ce script à moitié fait était une variable non
# liée — `$meet.nctorigin.com` — pas cette forme-ci.
if grep -qE '^\s*no-tcp-relay' "$TURN_CONF"; then
    dit "no-tcp-relay laissé en place (il ne concerne pas ce chemin)"
fi

if [ "$REDEMARRER" = 1 ]; then
    redemarrer coturn "les appels Jitsi qui passent par le relais"
fi

# --- 2. Le pare-feu local ---------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    if ufw allow "$PORT/tcp" >/dev/null; then
        vert "UFW : $PORT/tcp autorisé"
    fi
else
    dit "UFW inactif ou absent : rien à ouvrir localement"
fi

# --- 3. Le TLS : diagnostic, sans rien décider ------------------------------
# On regarde, on dit, on ne touche pas. Trois choses doivent être vraies pour que
# `turns:` serve à quelqu'un, et aucune ne se répare sans un choix qui dépasse ce
# script.
# AVANT tout test, et pas dans une branche : `set -u` tue le script si une
# variable référencée plus bas n'a pas été assignée. C'est exactement ce qui est
# arrivé ici — le diagnostic s'affichait, puis le script mourait avant de poser le
# fragment, donc le relais écoutait en TCP sans que le jeu l'annonce. Un script
# qui s'arrête au milieu laisse un état que personne n'a voulu.
UTILISATEUR="$(systemctl show coturn -p User --value 2>/dev/null || true)"
[ -n "$UTILISATEUR" ] || UTILISATEUR=turnserver
CERT="$(sed -n 's/^cert=//p' "$TURN_CONF" | head -1)"
PKEY="$(sed -n 's/^pkey=//p' "$TURN_CONF" | head -1)"
TLS_PORT="$(sed -n 's/^tls-listening-port=//p' "$TURN_CONF" | head -1)"
[ -n "$TLS_PORT" ] || TLS_PORT=5349
TLS_PRET=1

if [ -z "$CERT" ] || [ ! -r "$CERT" ]; then
    jaune "TLS : aucun certificat lisible déclaré dans $TURN_CONF"
    TLS_PRET=0
else
    # Les EMPREINTES des noms, pas les lignes imprimées : `-issuer` et `-subject`
    # rendent « issuer=… » et « subject=… », donc comparer les sorties brutes ne
    # correspond JAMAIS — et un certificat auto-signé passerait pour signé par un
    # tiers. Défaut trouvé en éprouvant ce script contre le vrai certificat de la
    # machine, qui est justement auto-signé.
    EMETTEUR="$(openssl x509 -in "$CERT" -noout -issuer_hash 2>/dev/null || true)"
    SUJET="$(openssl x509 -in "$CERT" -noout -subject_hash 2>/dev/null || true)"
    if [ -n "$SUJET" ] && [ "$EMETTEUR" = "$SUJET" ]; then
        jaune "TLS : le certificat de coturn est AUTO-SIGNÉ — un client le refuse."
        dit "   $CERT"
        TLS_PRET=0
    fi
    # coturn ne tourne pas en root : un certificat valide qu'il ne peut pas LIRE
    # ne vaut pas mieux qu'un certificat absent, et l'échec serait au démarrage.
    if ! sudo -u "$UTILISATEUR" test -r "$PKEY" 2>/dev/null; then
        jaune "TLS : $UTILISATEUR ne peut pas lire la clef privée $PKEY"
        TLS_PRET=0
    fi
fi

if [ "$TLS_PRET" = 1 ]; then
    vert "TLS : certificat valide et lisible — turns: peut être annoncé"
    dit "Pour l'annoncer : ajoutez NCTGAME_TURN_TLS=1 au drop-in ci-dessous."
else
    printf '\n'
    jaune "LE TLS RESTE FERMÉ, ET C'EST VOULU. Pour l'ouvrir un jour, deux chemins,"
    jaune "qui touchent tous deux quelque chose de PARTAGÉ — à décider, pas à faire"
    jaune "à l'aveugle :"
    dit "1. Donner à coturn un certificat valide. Le moins intrusif : un crochet de"
    dit "   renouvellement certbot qui COPIE le seul certificat du relais dans"
    dit "   /etc/coturn/, en $UTILISATEUR:$UTILISATEUR 0640. Ajouter coturn au groupe"
    dit "   ssl-cert lui donnerait accès aux clefs des QUATRE services — plus simple,"
    dit "   plus large, et c'est pour ça qu'on ne le fait pas ici."
    dit "   ⚠ coturn ne recharge pas ses certificats : le crochet devrait le"
    dit "   REDÉMARRER à chaque renouvellement, soit une coupure automatique tous"
    dit "   les deux mois. C'est le vrai prix de ce chemin."
    dit "2. Écouter sur le 443, que le client préfère — mais nginx l'occupe déjà"
    dit "   pour les quatre services. Il faudrait soit un multiplexage SNI en bloc"
    dit "   'stream' devant les quatre vhosts (risque réel), soit une seconde IP"
    dit "   publique dédiée au relais (payante, mais elle ne touche à rien)."
fi

# --- 4. Le jeu doit ANNONCER l'adresse TCP ----------------------------------
# Sans ça, le relais écoute en TCP et personne ne le sait : le serveur continue
# de n'annoncer que l'UDP, par prudence, et le travail ci-dessus ne sert à rien.
mkdir -p "$(dirname "$UNITE")"
{
    printf '%s\n' \
        "# Posé par services/nctgame/turn-tcp.sh : coturn écoute maintenant en TCP," \
        "# donc le jeu peut annoncer cette adresse sans faire perdre du temps." \
        "[Service]" \
        'Environment="NCTGAME_TURN_TCP=1"'
    # Le TLS n'est annoncé QUE s'il est utilisable. Annoncer les deux d'un seul
    # geste aurait remis le défaut qu'on vient d'éviter, en plus discret.
    # `if` et non `&&`, pour que la lecture suive la décision. Le commentaire
    # d'origine invoquait ici `set -e` sur la dernière commande du groupe : faux
    # aussi, et vérifié (cas E de la note en tête de lib/common.sh).
    if [ "$TLS_PRET" = 1 ]; then
        printf '%s\n' \
            "# Certificat valide et lisible : le TLS est utilisable." \
            'Environment="NCTGAME_TURN_TLS=1"'
    fi
} > "$UNITE"
# `daemon-reload` ne coupe rien : il relit les unités, sans toucher aux
# processus. Le redémarrage, lui, se demande.
systemctl daemon-reload
redemarrer nctgame "toutes les parties en cours, qui vivent en mémoire"

# --- 5. VÉRIFIER, au lieu de l'annoncer -------------------------------------
# Même contrôle que dans turn-secret.sh, et pour la même raison : ce script a
# déjà laissé le relais écouter en TCP sans que le jeu l'annonce, en s'arrêtant
# au milieu. On regarde donc l'environnement du processus qui tourne, seule
# preuve que le réglage est arrivé là où il sert.
PID="$(systemctl show nctgame -p MainPID --value 2>/dev/null || true)"
if [ "$A_REDEMARRE" != 1 ]; then
    dit "Service non redémarré : rien à vérifier pour l'instant."
elif [ -n "$PID" ] && [ "$PID" != 0 ] && [ -r "/proc/$PID/environ" ]; then
    if tr '\0' '\n' < "/proc/$PID/environ" | grep -q '^NCTGAME_TURN_TCP=1'; then
        vert "Vérifié : le jeu annonce bien l'adresse TCP du relais"
    else
        jaune "Le jeu tourne SANS annoncer le TCP : le relais écoute pour rien."
        jaune "Il n'a pas été redémarré depuis la pose du fragment."
    fi
else
    jaune "Service arrêté ou environnement illisible : rien n'est vérifié."
fi

printf '\n'
jaune "LE PARE-FEU DE L'HÉBERGEUR, SI VOUS EN AVEZ UN : le $PORT/tcp doit y être"
jaune "déclaré, sinon tout ce qui précède est invisible de l'extérieur — et la"
jaune "panne ressemble trait pour trait à un service qui n'écoute pas."
dit "Au 3 octobre 2026 cette machine n'a aucun pare-feu Cloud (vérifié dans la"
dit "console et par la trace : un port ouvert ici recevait l'internet deux heures"
dit "plus tard). Pour s'en assurer :"
dit "  hcloud server describe <machine> -o json | jq '.public_net.firewalls'"
