#!/usr/bin/env bash
# =============================================================================
# arch-guardian :: modules/network.sh
# Estado de rede via `ss -tulpn`, usado para comparar portas/serviços
# escutando antes e depois de uma atualização.
# =============================================================================

net::listeners() {
    # -n usa sudo se disponível sem senha (para resolver o PID/processo);
    # se não houver sudo sem senha, cai para o `ss` normal do usuário.
    if sudo -n true 2>/dev/null; then
        sudo ss -tulpn 2>/dev/null
    else
        ss -tulpn 2>/dev/null
    fi
}

net::listener_count() {
    net::listeners | tail -n +2 | grep -c .
}

net::snapshot() {
    local tag="$1"
    net::listeners > "$STATE_DIR/net_${tag}.txt" 2>/dev/null
}

# --- Teste de conectividade (ping) --------------------------------------
# Alvo padrão: github.com (perfil de referência: github.com/flavdotexe),
# configurável via PING_HOST em guardian.conf. Serve pra decidir se vale a
# pena atualizar o sistema agora ou esperar a conexão melhorar.
net::ping_test() {
    local host="${PING_HOST:-github.com}"
    echo -e "${C_BOLD}${C_CYAN}-- Teste de conectividade --${C_RESET}"
    echo "Alvo: $host"
    echo

    if ! command -v ping &>/dev/null; then
        echo -e "${C_RED}Comando 'ping' não encontrado no sistema.${C_RESET}"
        return 1
    fi

    local out
    out="$(ping -c 4 -W 2 "$host" 2>&1)"
    echo "$out"
    echo

    local loss
    loss="$(grep -oE '[0-9]+% packet loss' <<<"$out" | grep -oE '^[0-9]+')"

    if [[ -z "$loss" ]]; then
        echo -e "${C_RED}✘ Não foi possível alcançar '$host'. Verifique sua conexão antes de atualizar.${C_RESET}"
        return 1
    elif [[ "$loss" -eq 0 ]]; then
        echo -e "${C_GREEN}✔ Conexão estável (0% de perda de pacotes). Bom momento pra atualizar.${C_RESET}"
        return 0
    elif [[ "$loss" -lt 50 ]]; then
        echo -e "${C_YELLOW}⚠ Perda de pacotes de ${loss}%. Atualizar agora pode ser arriscado (downloads incompletos/corrompidos).${C_RESET}"
        return 1
    else
        echo -e "${C_RED}✘ Perda de pacotes de ${loss}%. Não é recomendado atualizar com essa conexão.${C_RESET}"
        return 1
    fi
}

# --- Conferência de mirrors -----------------------------------------------
# Testa (com curl) os mirrors listados em /etc/pacman.d/mirrorlist,
# substituindo $repo/$arch por valores reais pra montar uma URL testável.
net::mirrors_check() {
    local mirrorlist="${MIRRORLIST_PATH:-/etc/pacman.d/mirrorlist}"
    local limit="${MIRROR_CHECK_LIMIT:-10}"

    echo -e "${C_BOLD}${C_CYAN}-- Conferência de mirrors --${C_RESET}"
    echo "Arquivo: $mirrorlist   (testando até $limit mirror(s))"
    echo

    if [[ ! -f "$mirrorlist" ]]; then
        echo -e "${C_RED}Mirrorlist não encontrada em: $mirrorlist${C_RESET}"
        return 1
    fi
    if ! command -v curl &>/dev/null; then
        echo -e "${C_RED}Comando 'curl' não encontrado no sistema.${C_RESET}"
        return 1
    fi

    local checked=0 ok=0
    while IFS= read -r line; do
        [[ "$checked" -ge "$limit" ]] && break
        local url="${line#Server = }"
        url="${url//\$repo/core}"
        url="${url//\$arch/x86_64}"
        local host
        host="$(echo "$url" | awk -F/ '{print $3}')"
        checked=$((checked + 1))
        if curl -s -o /dev/null --max-time 3 "$url"; then
            echo -e "  ${C_GREEN}OK${C_RESET}    $host"
            ok=$((ok + 1))
        else
            echo -e "  ${C_RED}FALHA${C_RESET} $host"
        fi
    done < <(grep -E '^Server' "$mirrorlist")

    echo
    echo "Mirrors testados: $checked | OK: $ok | Falharam: $((checked - ok))"
}

net::diff_report() {
    local before="$STATE_DIR/net_before.txt"
    local after="$STATE_DIR/net_after.txt"
    [[ -f "$before" && -f "$after" ]] || { echo "(sem dados de comparação)"; return; }

    echo "# Portas/serviços que pararam de escutar após a atualização:"
    comm -23 <(tail -n +2 "$before" | awk '{print $1, $5}' | sort -u) \
             <(tail -n +2 "$after"  | awk '{print $1, $5}' | sort -u) | sed 's/^/  - /'
    echo
    echo "# Portas/serviços novos escutando após a atualização:"
    comm -13 <(tail -n +2 "$before" | awk '{print $1, $5}' | sort -u) \
             <(tail -n +2 "$after"  | awk '{print $1, $5}' | sort -u) | sed 's/^/  + /'
}
