#!/usr/bin/env bash
# whisper-api — transcription audio derrière une clef d'API.
#
# Sourcé par bootstrap.sh, qui a déjà posé le socle.

S=whisper
DIR="/home/$APP_USER/whisper-api"
DOM="${DOMAINE[$S]}"
PRT="${PORT[$S]}"
UNI="${UNITE[$S]}"

depot "https://github.com/nctorigins/whisper-api.git" "$DIR" "$APP_USER"

# 58 paquets dont torch : ce venv pèse 7,2 Go et met plusieurs minutes à se
# poser. C'est le prix de la reproductibilité — les versions y sont FIGÉES au
# lieu d'être bornées par un `>=`, donc une machine neuve obtient exactement ce
# qui tourne ici, et non ce que PyPI publiera l'an prochain.
info "installation des dépendances (7 Go environ, plusieurs minutes)"
venv_python "$DIR" "$APP_USER"

# --- La clef d'API ---------------------------------------------------------
# `.api_keys.json` n'est pas versionné, et ne doit pas l'être : c'est le seul
# fichier du dépôt dont la fuite donnerait le service à quelqu'un d'autre. Sur
# une machine neuve il n'existe donc pas, et sans lui personne ne peut appeler
# le service — pas même son propriétaire.
if [ -f "$DIR/.api_keys.json" ]; then
    ok "clefs d'API présentes (laissées telles quelles)"
elif demande_oui_non "Fabriquer une première clef d'API ?" o; then
    nom=$(demande "Nom de la clef" "premiere")
    sudo -u "$APP_USER" "$DIR/venv/bin/python" "$DIR/whisper-keys" add "$nom" \
        | sed 's/^/    /'
    alerte "Cette clef ne sera plus affichée : notez-la maintenant."
else
    alerte "aucune clef : le service refusera toutes les requêtes."
    info  "  sudo -u $APP_USER $DIR/venv/bin/python $DIR/whisper-keys add <nom>"
fi

pose_unite "$ICI/services/$S/service.service" "$UNI" "$DIR" "$APP_USER"
attends_dns "$DOM" || alerte "on continue, mais le certificat va probablement échouer"
pose_nginx "$ICI/services/$S/nginx.conf" "$DOM" "$PRT"
pose_certificat "$DOM" "$COURRIEL"

sleep 1
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$DOM/" 2>/dev/null || echo 000)
case "$code" in
    # 401/403 est le BON signe : le service tourne et refuse une requête sans
    # clef. Un 200 nu voudrait dire qu'il répond à n'importe qui.
    401|403)     ok "https://$DOM répond $code — il exige une clef, c'est voulu" ;;
    200|404|405) ok "https://$DOM répond ($code)" ;;
    *)           alerte "https://$DOM répond $code" ;;
esac
