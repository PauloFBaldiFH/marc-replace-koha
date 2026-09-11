#!/bin/bash
#
# install.sh - instala/atualiza o marc_replace.pl no Koha
#
# Uso (como root, na maquina que roda o Koha):
#   curl -sSL https://raw.githubusercontent.com/PauloFBaldiFH/marc-replace-koha/main/install.sh | sudo bash
#
# Ou, se preferir revisar antes de rodar:
#   curl -O https://raw.githubusercontent.com/PauloFBaldiFH/marc-replace-koha/main/install.sh
#   less install.sh
#   sudo bash install.sh
#
# A instancia e o usuario/grupo dono sao detectados automaticamente a
# partir de /etc/koha/sites/. So defina isso na mao se o auto-detect falhar
# ou se voce tiver mais de uma instancia e quiser escolher qual usar:
#   KOHA_INSTANCE   nome da instancia Koha
#   KOHA_USER       usuario/grupo dono do arquivo (padrao: <instancia>-koha)

set -euo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/PauloFBaldiFH/marc-replace-koha/main/marc_replace.pl"
DEST="/usr/share/koha/intranet/cgi-bin/tools/marc_replace.pl"
SITES_DIR="/etc/koha/sites"

if [ "$(id -u)" -ne 0 ]; then
    echo "Este instalador precisa rodar como root (use sudo)." >&2
    exit 1
fi

if [ -z "${KOHA_INSTANCE:-}" ]; then
    if [ -d "$SITES_DIR" ]; then
        mapfile -t instances < <(find "$SITES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    else
        instances=()
    fi

    if [ "${#instances[@]}" -eq 1 ]; then
        KOHA_INSTANCE="${instances[0]}"
        echo "Instancia detectada automaticamente: $KOHA_INSTANCE"
    elif [ "${#instances[@]}" -gt 1 ]; then
        echo "Mais de uma instancia Koha encontrada em $SITES_DIR:" >&2
        printf '  - %s\n' "${instances[@]}" >&2
        echo "Rode de novo definindo qual usar, ex:" >&2
        echo "  export KOHA_INSTANCE=${instances[0]}" >&2
        exit 1
    else
        echo "Nao foi possivel detectar a instancia Koha em $SITES_DIR." >&2
        echo "Defina manualmente, ex: export KOHA_INSTANCE=library" >&2
        exit 1
    fi
fi

KOHA_USER="${KOHA_USER:-${KOHA_INSTANCE}-koha}"

echo "Baixando marc_replace.pl..."
curl -fsSL "$REPO_RAW_URL" -o "$DEST"

echo "Ajustando dono e permissoes ($KOHA_USER)..."
chown "${KOHA_USER}:${KOHA_USER}" "$DEST"
chmod 755 "$DEST"

echo "Reiniciando o Plack da instancia ${KOHA_INSTANCE}..."
koha-plack --restart "$KOHA_INSTANCE"

echo ""
echo "Instalado com sucesso em: $DEST"
echo "Acesse (logado no staff client): http://SEU_INTRANET/cgi-bin/koha/tools/marc_replace.pl"
