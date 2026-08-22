#!/usr/bin/env bash
# =============================================================================
# arch-guardian :: guardian.sh
# Agente interativo de segurança e atualização de pacotes para Arch Linux.
#
# Não substitui o snapper (que continua funcionando com seus próprios
# hooks/timers) — o guardian só orquestra pacman/AUR, gera relatórios de
# antes/depois de cada atualização e mostra uma tabela de avisos de
# segurança/saúde do sistema.
# =============================================================================
set -uo pipefail

# --- localização e carregamento de módulos ----------------------------------
GUARDIAN_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${GUARDIAN_CONFIG:-$GUARDIAN_ROOT/config/guardian.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Erro: arquivo de configuração não encontrado em: $CONFIG_FILE" >&2
    exit 1
fi
# shellcheck source=config/guardian.conf
source "$CONFIG_FILE"

for mod in packages services network journal integrity btrfs security; do
    mod_file="$GUARDIAN_ROOT/modules/${mod}.sh"
    if [[ -f "$mod_file" ]]; then
        # shellcheck source=/dev/null
        source "$mod_file"
    else
        echo "Aviso: módulo ausente: $mod_file" >&2
    fi
done

mkdir -p "$STATE_DIR" "$LOG_BASE_DIR" 2>/dev/null

# --- dependências mínimas ----------------------------------------------------
guardian::check_deps() {
    local missing=()
    for c in pacman ss systemctl journalctl find stat awk comm diff ping curl; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Aviso: comandos ausentes no sistema: ${missing[*]}" >&2
        echo "Algumas funcionalidades podem não funcionar corretamente." >&2
    fi
}
guardian::check_deps

# --- cores --------------------------------------------------------------------
if [[ "${COLOR_OUTPUT:-true}" == "true" ]] && [[ -t 1 ]]; then
    C_RESET="\e[0m"; C_BOLD="\e[1m"
    C_RED="\e[31m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"
    C_BLUE="\e[34m"; C_CYAN="\e[36m"; C_MAGENTA="\e[35m"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
fi

# --- util -----------------------------------------------------------------
guardian::pause() { read -rp "Pressione ENTER para continuar..." _; }

guardian::header() {
    clear
    echo -e "${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║                       SECURE UPDATE ARCH LINUX                        ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║             Agente de segurança e atualização de pacotes              ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════════════════════════════╝${C_RESET}"
    echo -e "  Host: $(hostname)   Kernel: $(uname -r)   $(date '+%d/%m/%Y %H:%M:%S')"
    echo
}

# --- menu de navegação por setas ---------------------------------------------
# guardian::menu <título> <opção1> <opção2> ...
#
# Controles: ↑/↓ (ou k/j) navegam, →/Enter seleciona, ← volta, q sai/volta.
#
# Retorno (status code):
#   0 -> uma opção foi selecionada; índice (0-based) fica em $GUARDIAN_MENU_CHOICE
#   1 -> usuário apertou ← (voltar)
#   2 -> usuário apertou q (sair/voltar)
#
# Variável opcional GUARDIAN_MENU_EXTRA: nome de uma função a ser chamada logo
# após o cabeçalho (ex.: para desenhar a tabela de status antes das opções).
guardian::menu() {
    local title="$1"; shift
    local -a options=("$@")
    local n=${#options[@]}
    local sel=0
    local key rest
    local redraw_lines=$((n + 2))  # opções + linha em branco + linha de dicas

    tput civis 2>/dev/null

    # Desenha o cabeçalho, a tabela de status (se houver) e o título UMA
    # única vez. Só a lista de opções é redesenhada a cada tecla, movendo o
    # cursor pra cima em vez de limpar a tela inteira e recalcular tudo.
    guardian::header
    if [[ -n "${GUARDIAN_MENU_EXTRA:-}" ]]; then
        "$GUARDIAN_MENU_EXTRA"
        echo
    fi
    [[ -n "$title" ]] && echo -e "${C_BOLD}${C_CYAN}-- ${title} --${C_RESET}" && echo

    guardian::_draw_menu_options() {
        local i
        for i in "${!options[@]}"; do
            printf '\r'; tput el 2>/dev/null
            if [[ $i -eq $sel ]]; then
                echo -e "  ${C_BOLD}${C_GREEN}❯ ${options[$i]}${C_RESET}"
            else
                echo -e "    ${options[$i]}"
            fi
        done
        printf '\r'; tput el 2>/dev/null; echo
        printf '\r'; tput el 2>/dev/null
        echo -e "  ${C_BLUE}↑/↓${C_RESET} navega    ${C_BLUE}→ / Enter${C_RESET} seleciona    ${C_BLUE}←${C_RESET} volta    ${C_BLUE}q${C_RESET} sair"
    }

    guardian::_draw_menu_options

    while true; do
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.05 rest
            key+="$rest"
        fi

        case "$key" in
            $'\x1b[A'|k|K)
                ((sel--)); ((sel < 0)) && sel=$((n - 1))
                tput cuu "$redraw_lines" 2>/dev/null
                guardian::_draw_menu_options
                ;;
            $'\x1b[B'|j|J)
                ((sel++)); ((sel >= n)) && sel=0
                tput cuu "$redraw_lines" 2>/dev/null
                guardian::_draw_menu_options
                ;;
            $'\x1b[C'|"")
                tput cnorm 2>/dev/null
                GUARDIAN_MENU_CHOICE=$sel
                unset -f guardian::_draw_menu_options
                return 0
                ;;
            $'\x1b[D')
                tput cnorm 2>/dev/null
                unset -f guardian::_draw_menu_options
                return 1
                ;;
            q|Q)
                tput cnorm 2>/dev/null
                unset -f guardian::_draw_menu_options
                return 2
                ;;
        esac
    done
}

# --- orquestração de atualização (antes/depois + relatório) ------------------
guardian::execute_update() {
    local label="$1"
    local update_fn="$2"

    echo -e "${C_BOLD}${C_BLUE}==> Coletando estado do sistema (ANTES)...${C_RESET}"
    jr::mark_start
    net::snapshot before
    svc::snapshot before
    integ::pacnew_snapshot before
    pkg::snapshot before
    btrfs::snapshot before

    echo -e "${C_BOLD}${C_YELLOW}==> Executando: $label${C_RESET}"
    echo
    local status="OK"
    "$update_fn" || status="FALHOU"
    echo

    echo -e "${C_BOLD}${C_BLUE}==> Coletando estado do sistema (DEPOIS)...${C_RESET}"
    jr::mark_end
    net::snapshot after
    svc::snapshot after
    integ::pacnew_snapshot after
    pkg::snapshot after
    btrfs::snapshot after

    echo "$status" > "$STATE_DIR/last_update_status"
    guardian::write_report "$label" "$status"

    echo
    echo -e "${C_BOLD}${C_GREEN}Relatório salvo em:${C_RESET} $LOG_FILE"
    guardian::pause
}

guardian::write_report() {
    local label="$1" status="$2"
    local start end
    start="$(cat "$STATE_DIR/last_update_start" 2>/dev/null || echo "?")"
    end="$(cat "$STATE_DIR/last_update_end" 2>/dev/null || echo "?")"

    mkdir -p "$LOG_BASE_DIR"
    {
        echo "==================================================================="
        echo " ARCH GUARDIAN - Relatório da última atualização"
        echo "==================================================================="
        echo "Ação executada : $label"
        echo "Início         : $start"
        echo "Fim            : $end"
        echo "Status         : $status"
        echo "Host           : $(hostname)"
        echo "Kernel         : $(uname -r)"
        echo
        echo "-------------------------------------------------------------------"
        echo " PACOTES"
        echo "-------------------------------------------------------------------"
        pkg::diff_report
        echo
        echo "-------------------------------------------------------------------"
        echo " SERVIÇOS (systemctl)"
        echo "-------------------------------------------------------------------"
        svc::diff_report
        echo
        echo "-------------------------------------------------------------------"
        echo " REDE (ss -tulpn)"
        echo "-------------------------------------------------------------------"
        net::diff_report
        echo
        echo "-------------------------------------------------------------------"
        echo " JOURNAL (journalctl) - erros durante a atualização"
        echo "-------------------------------------------------------------------"
        jr::report_section
        echo
        echo "-------------------------------------------------------------------"
        echo " INTEGRIDADE (find + stat) - novos .pacnew/.pacsave"
        echo "-------------------------------------------------------------------"
        integ::pacnew_diff_report
        echo
        echo "-------------------------------------------------------------------"
        echo " BTRFS"
        echo "-------------------------------------------------------------------"
        if [[ -f "$STATE_DIR/btrfs_before.txt" || -f "$STATE_DIR/btrfs_after.txt" ]]; then
            echo "-- Antes --"
            cat "$STATE_DIR/btrfs_before.txt" 2>/dev/null
            echo
            echo "-- Depois --"
            cat "$STATE_DIR/btrfs_after.txt" 2>/dev/null
        else
            echo "(BTRFS não aplicável ou desativado)"
        fi
        echo
        echo "==================================================================="
    } > "$LOG_FILE" 2>/dev/null
}

guardian::view_last_log() {
    guardian::header
    if [[ -f "$LOG_FILE" ]]; then
        less -F "$LOG_FILE"
    else
        echo "Ainda não existe log de atualização em: $LOG_FILE"
        guardian::pause
    fi
}

# --- ações do menu principal --------------------------------------------------
guardian::action_full_update() {
    guardian::header
    guardian::execute_update "Atualização completa (pacman -Syu)" pkg::action_full_update
}

guardian::action_sync_official() {
    guardian::header
    guardian::execute_update "Atualização de repositórios oficiais" pkg::action_sync_official
}

guardian::action_aur_update() {
    guardian::header
    if [[ "$AUR_HELPER" == "none" ]]; then
        echo "AUR desativado na configuração (AUR_HELPER=none)."
        guardian::pause
        return
    fi
    guardian::execute_update "Atualização AUR" pkg::action_aur_update
}

guardian::action_blackarch_update() {
    guardian::header
    guardian::execute_update "Atualização BlackArch" pkg::action_blackarch_update
}

guardian::action_list_updates() {
    guardian::header
    echo -e "${C_BOLD}${C_CYAN}-- Pacotes disponíveis para atualização --${C_RESET}"
    echo
    local out
    out="$(pkg::pending_updates)"
    if [[ -z "$out" ]]; then
        echo -e "${C_GREEN}Sistema em dia, nada para atualizar.${C_RESET}"
    else
        echo "$out"
    fi
    guardian::pause
}

# --- menu principal -------------------------------------------------------
guardian::main_menu() {
    local -a labels=(
        "Atualização completa do sistema"
        "Atualizar apenas repositórios oficiais"
        "Atualizar apenas pacotes AUR"
        "Atualizar apenas pacotes BlackArch"
        "Ver pacotes disponíveis para atualização"
        "Tipos de pacotes"
        "Informações do kernel"
        "Ver log da última atualização"
        "BTRFS / Snapper"
        "Verificar integridade de pacotes/configs"
        "Sair"
    )

    while true; do
        GUARDIAN_MENU_EXTRA=sec::render_warnings_table guardian::menu "Menu" "${labels[@]}"
        local rc=$?

        # No menu principal, ← e q têm o mesmo efeito: sair do programa.
        if [[ $rc -eq 1 || $rc -eq 2 ]]; then
            tput cnorm 2>/dev/null
            echo "Até mais."
            exit 0
        fi

        case "$GUARDIAN_MENU_CHOICE" in
            0) guardian::action_full_update ;;
            1) guardian::action_sync_official ;;
            2) guardian::action_aur_update ;;
            3) guardian::action_blackarch_update ;;
            4) guardian::action_list_updates ;;
            5) pkg::types_menu ;;
            6) pkg::kernel_info ;;
            7) guardian::view_last_log ;;
            8) btrfs::menu ;;
            9) integ::menu ;;
            10) tput cnorm 2>/dev/null; echo "Bye."; exit 0 ;;
        esac
    done
}

trap 'tput cnorm 2>/dev/null' EXIT
guardian::main_menu
