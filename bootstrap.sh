#!/usr/bin/env bash
#
# ============================================================================
# nctorigin — installation des services de la machine, depuis zéro
# ============================================================================
#
#   sudo ./bootstrap.sh                    demande quoi installer
#   sudo ./bootstrap.sh nctgame            un service
#   sudo ./bootstrap.sh nctgame quran      plusieurs
#   sudo ./bootstrap.sh --tout             les quatre
#   ./bootstrap.sh --etat                  ne touche à rien, dit où on en est
#
#   INTERACTIF=0 sudo ./bootstrap.sh --tout        sans aucune question
#
# ----------------------------------------------------------------------------
# CE SCRIPT EST FAIT POUR ÊTRE RELANCÉ.
#
# Sur une machine déjà installée, il ne casse rien : il met à jour le code,
# réinstalle les dépendances, réécrit les configurations et redémarre. C'est
# ainsi qu'on l'éprouve — un script d'installation qu'on ne lance qu'une fois
# est un script qu'on n'éprouve jamais, et qui échoue le jour où il compte.
#
# CE QU'IL NE PEUT PAS FAIRE, IL LE FAIT FAIRE.
#
# Trois choses ne se font pas depuis cette machine : créer un enregistrement
# DNS, ouvrir le pare-feu de l'hébergeur, décider s'il faut restaurer des
# données. Le script ne s'arrête pas devant : il affiche exactement quoi faire,
# puis attend, puis reprend.
# ============================================================================

set -euo pipefail
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ICI/lib/common.sh"

# --- Ce que la machine héberge ---------------------------------------------
# Un service = un nom, un domaine, un port local, un module. Ajouter le
# cinquième ne demandera qu'une ligne ici et un fichier dans services/.
declare -A DOMAINE=(
    [nctgame]="game.nctorigin.com"
    [quran]="quran-recognizer.nctorigin.com"
    [whisper]="whisper.nctorigin.com"
    [jitsi]="meet.nctorigin.com"
)
declare -A PORT=(
    [nctgame]="8765"
    [quran]="8001"
    [whisper]="8000"
    [jitsi]="-"
)
declare -A RESUME=(
    [nctgame]="serveur de jeu Ludo temps réel (WebSocket)"
    [quran]="reconnaissance de récitation coranique"
    [whisper]="transcription audio derrière clef d'API"
    [jitsi]="visioconférence Jitsi Meet"
)
# Le nom de l'unité systemd ne suit pas celui du service : il faut donc le
# dire, et non le deviner. Jitsi en a quatre ; jicofo suffit à savoir s'il tourne.
declare -A UNITE=(
    [nctgame]="nctgame"
    [quran]="quran-recognizer"
    [whisper]="whisper-api"
    [jitsi]="jicofo"
)

SERVICES=(nctgame quran whisper jitsi)

APP_USER="${APP_USER:-whisper}"
COURRIEL="${COURRIEL:-}"

# --- État -------------------------------------------------------------------
etat() {
    titre "État des services"
    local root=0; [ "$(id -u)" -eq 0 ] && root=1
    printf '  %-10s %-32s %-8s %-8s %s\n' SERVICE DOMAINE UNITÉ NGINX TLS
    printf '  %-10s %-32s %-8s %-8s %s\n' "----------" "--------------------------------" \
           "--------" "--------" "---"
    for s in "${SERVICES[@]}"; do
        local d="${DOMAINE[$s]}" u n t
        systemctl is-active --quiet "${UNITE[$s]}" 2>/dev/null && u="actif" || u="—"

        # Le bloc nginx est CHERCHÉ par son contenu, jamais deviné par son
        # nom : deux des quatre fichiers ne portent pas celui de leur domaine.
        #
        # Et `-R`, non `-r` : la descente de grep NE SUIT PAS les liens
        # symboliques, or sites-enabled n'en contient que. Avec `-r` la
        # recherche ne trouvait rien du tout et l'état annonçait quatre blocs
        # absents qui étaient tous en place.
        if grep -Rlq "server_name[[:space:]].*${d}" /etc/nginx/sites-enabled/ 2>/dev/null; then
            n="posé"
        else
            n="—"
        fi

        # « Je ne peux pas lire » n'est pas « il n'y en a pas ». Sans les
        # droits, /etc/letsencrypt/live est invisible, et confondre les deux
        # ferait croire à une machine sans aucun certificat.
        if [ "$root" = "1" ] || [ -r /etc/letsencrypt/live ]; then
            [ -d "/etc/letsencrypt/live/$d" ] && t="oui" || t="—"
        else
            t="?"
        fi
        printf '  %-10s %-32s %-8s %-8s %s\n' "$s" "$d" "$u" "$n" "$t"
    done
    printf '\n'
    [ "$root" = "1" ] || info "TLS en « ? » : relancez avec sudo pour le savoir."
    info "adresse publique : $(ip_publique)"
}

# --- Choisir ----------------------------------------------------------------
choisir() {
    titre "Quels services installer ?"
    for s in "${SERVICES[@]}"; do
        printf '    %-10s %s\n' "$s" "${RESUME[$s]}"
    done
    printf '\n'
    local rep
    rep=$(demande "Lesquels (séparés par des espaces, ou 'tout')" "tout")
    [ "$rep" = "tout" ] && { printf '%s\n' "${SERVICES[@]}"; return; }
    printf '%s\n' $rep
}

# --- Les phases communes à tous ---------------------------------------------
socle() {
    titre "Socle de la machine"
    paquets git curl dnsutils python3 python3-venv python3-pip nginx \
            certbot python3-certbot-nginx sqlite3 openssl
    compte_service "$APP_USER"
    ouvre_ports 80/tcp 443/tcp 'OpenSSH'
}

# --- Programme --------------------------------------------------------------
CHOIX=()
TOUT=0
case "${1:-}" in
    --etat|--status) etat; exit 0 ;;
    -h|--help) sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --tout) TOUT=1 ;;
    "") : ;;
    *) CHOIX=("$@") ;;
esac

# Vérifié AVANT d'exiger les privilèges : un nom de service erroné est une
# faute de frappe, pas un manque de droits, et l'apprendre après avoir tapé son
# mot de passe est un aller-retour pour rien.
for s in "${CHOIX[@]}"; do
    [ -f "$ICI/services/$s/install.sh" ] \
        || mourir "service inconnu : $s (connus : ${SERVICES[*]})"
done

exige_root

printf '\n%s' "$_c_gras"
cat <<'BANNIERE'
  ╔══════════════════════════════════════════════════════════════╗
  ║   nctorigin — installation des services                      ║
  ╚══════════════════════════════════════════════════════════════╝
BANNIERE
printf '%s\n' "$_c_fin"

if [ "$TOUT" = "1" ]; then
    CHOIX=("${SERVICES[@]}")
elif [ ${#CHOIX[@]} -eq 0 ]; then
    mapfile -t CHOIX < <(choisir)
fi

info "à installer : ${CHOIX[*]}"
socle

ECHECS=()
for s in "${CHOIX[@]}"; do
    titre "${s} — ${RESUME[$s]}"
    if ( source "$ICI/services/$s/install.sh" ); then
        ok "$s terminé"
    else
        echec "$s a échoué"
        ECHECS+=("$s")
    fi
done

titre "Résultat"
etat
if [ ${#ECHECS[@]} -gt 0 ]; then
    printf '\n'
    echec "échecs : ${ECHECS[*]}"
    info "Relancez le script : il reprendra où il s'est arrêté, sans"
    info "défaire ce qui a réussi."
    exit 1
fi
printf '\n'
ok "Tout est en place."
