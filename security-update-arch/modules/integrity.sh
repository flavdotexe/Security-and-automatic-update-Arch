#!/usr/bin/env bash
# =============================================================================
# arch-guardian :: modules/integrity.sh
# Integridade de pacotes (pacman -Qkk), configs modificados de pacotes com
# atualização pendente, e varredura de .pacnew/.pacsave (find/stat).
# =============================================================================

# Checagem completa de integridade de TODOS os pacotes instalados (lento).
# Só deve ser chamada explicitamente pelo menu, não na tabela de status.
integ::full_check() {
    echo "Verificando integridade de arquivos de todos os pacotes instalados..."
    echo "(pode demorar um pouco em sistemas com muitos pacotes)"
    echo
    pacman -Qkk 2>&1 | grep -v ': 0 missing files, 0 altered files$'
}

# Lista, para os pacotes com atualização PENDENTE, quais arquivos de
# configuração (marcados como backup pelo pacman) foram modificados pelo
# usuário localmente. Isso ajuda a prever conflitos / .pacnew.
integ::modified_configs_pending() {
    local pkgs
    pkgs="$(pkg::pending_names 2>/dev/null)"
    [[ -z "$pkgs" ]] && return 0

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        pacman -Qii "$pkg" 2>/dev/null | awk -v p="$pkg" '
            /^MODIFIED/ { print p ": " $2 }
        '
    done <<<"$pkgs"
}

integ::modified_configs_count() {
    integ::modified_configs_pending | grep -c .
}

# Varredura de arquivos .pacnew / .pacsave deixados pelo pacman em /etc,
# combinando find (localizar) + stat (data de modificação).
integ::pacnew_scan() {
    find /etc -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null \
        -printf '%p (modificado em %TY-%Tm-%Td %TH:%TM)\n' 2>/dev/null
}

integ::pacnew_count() {
    integ::pacnew_scan | grep -c .
}

# --- Snapshot para o relatório ------------------------------------------------
integ::pacnew_snapshot() {
    local tag="$1"
    find /etc -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null \
        > "$STATE_DIR/pacnew_${tag}.txt"
}

integ::pacnew_diff_report() {
    local before="$STATE_DIR/pacnew_before.txt"
    local after="$STATE_DIR/pacnew_after.txt"
    [[ -f "$before" && -f "$after" ]] || { echo "(sem dados de comparação)"; return; }

    echo "# Novos .pacnew/.pacsave gerados pela atualização:"
    comm -13 <(sort "$before") <(sort "$after") | sed 's/^/  + /'
    local novos
    novos="$(comm -13 <(sort "$before") <(sort "$after"))"
    if [[ -n "$novos" ]]; then
        echo
        echo "# Detalhes (stat):"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            stat --format='  %n | dono: %U | modificado: %y' "$f" 2>/dev/null
        done <<<"$novos"
    fi
}

integ::menu() {
    local -a labels=(
        "Checagem completa (pacman -Qkk) - pode ser lento"
        "Configs modificados em pacotes com atualização pendente"
        "Varredura de .pacnew / .pacsave em /etc"
        "Teste de conectividade (ping)"
        "Conferência de mirrors do pacman"
    )

    while true; do
        guardian::menu "Integridade" "${labels[@]}"
        local rc=$?
        [[ $rc -ne 0 ]] && return

        case "$GUARDIAN_MENU_CHOICE" in
            0) integ::full_check | less -F ;;
            1)
                local out
                out="$(integ::modified_configs_pending)"
                guardian::header
                [[ -z "$out" ]] && echo "Nenhum config modificado em pacotes pendentes." || echo "$out"
                guardian::pause
                ;;
            2)
                local out
                out="$(integ::pacnew_scan)"
                guardian::header
                [[ -z "$out" ]] && echo "Nenhum .pacnew/.pacsave encontrado." || echo "$out"
                guardian::pause
                ;;
            3)
                guardian::header
                net::ping_test
                guardian::pause
                ;;
            4)
                guardian::header
                net::mirrors_check
                guardian::pause
                ;;
        esac
    done
}
