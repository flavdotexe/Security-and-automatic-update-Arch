#!/usr/bin/env bash
#
# battery-control.sh
#
# ThinkPad Battery Governance — menu interativo.
# Navegação: ↑/↓ move a seleção, → seleciona/executa, ← volta.
# Sem uso de Enter ou Esc como confirmação/cancelamento.
# Discharge e Recalibrate mantêm a confirmação Y/n (ações destrutivas/longas).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=battery-health.sh
source "$SCRIPT_DIR/battery-health.sh"

BAT="$(basename "${BAT_PATH:-BAT0}")"

MENU_ITEMS=(
    "Status"
    "Protection Mode   75% -> 80%"
    "Travel Mode        0% -> 100%"
    "Discharge"
    "Recalibrate"
    "Battery health"
    "History"
    "Exit"
)

selected=0

hide_cursor() { tput civis 2>/dev/null; }
show_cursor() { tput cnorm 2>/dev/null; }
trap show_cursor EXIT

# Lê uma tecla e resolve sequências de escape de setas (as únicas que usam ESC).
read_key() {
    local key rest
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.1 rest
        key+="$rest"
    fi
    case "$key" in
        $'\x1b[A') echo "UP" ;;
        $'\x1b[B') echo "DOWN" ;;
        $'\x1b[C') echo "RIGHT" ;;
        $'\x1b[D') echo "LEFT" ;;
        *) echo "OTHER" ;;
    esac
}

draw_menu() {
    clear
    echo "==============================="
    echo "  ThinkPad Battery Governance"
    echo "==============================="
    echo
    local i
    for i in "${!MENU_ITEMS[@]}"; do
        if [[ $i -eq $selected ]]; then
            printf " \033[7m %d. %-30s\033[0m\n" "$((i+1))" "${MENU_ITEMS[$i]}"
        else
            printf "   %d. %-30s\n" "$((i+1))" "${MENU_ITEMS[$i]}"
        fi
    done
    echo
    echo "  BAT: ${BAT}"
    echo
    echo "↑/↓ navega    → seleciona    ← volta"
}

# Espera até a pessoa apertar ← pra voltar ao menu.
pause_return() {
    echo
    echo "← volta ao menu"
    while true; do
        [[ "$(read_key)" == "LEFT" ]] && break
    done
}

confirm_yn() {
    local prompt="$1" reply
    read -rp "$prompt (Y/n): " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy]([eE][sS])?$ ]]
}

# Lê os thresholds diretamente do sysfs (fonte da verdade, não confia só no
# retorno do comando tlp).
read_thresholds_sysfs() {
    local start stop
    start=$(cat "$BAT_PATH/charge_control_start_threshold" 2>/dev/null)
    stop=$(cat "$BAT_PATH/charge_control_end_threshold" 2>/dev/null)
    echo "${start:-?} ${stop:-?}"
}

# Roda "tlp setcharge start stop BAT" e confirma no sysfs se o valor
# realmente foi escrito no hardware, em vez de confiar cegamente no
# código de saída do tlp.
apply_and_verify_threshold() {
    local label="$1" start="$2" stop="$3"
    echo "Ativando ${label} (${start}% -> ${stop}%)..."
    echo
    sudo tlp setcharge "$start" "$stop" "$BAT"
    local rc=$?
    echo
    sleep 1

    local cur_start cur_stop
    read -r cur_start cur_stop <<< "$(read_thresholds_sysfs)"

    if [[ "$cur_start" == "$start" && "$cur_stop" == "$stop" ]]; then
        echo "✔ Confirmado no hardware: start=${cur_start}% stop=${cur_stop}%"
    else
        echo "⚠ tlp retornou código $rc, mas o sysfs mostra start=${cur_start}% stop=${cur_stop}%"
        echo "  (esperado: start=${start}% stop=${stop}%)"
        echo
        echo "  Rode 'sudo tlp-stat -b' e confira a seção 'Driver usage' e os valores"
        echo "  atuais em /sys/class/power_supply/${BAT}/charge_control_*_threshold."
    fi
}

action_status() {
    clear
    print_status
    pause_return
}

action_protection() {
    clear
    apply_and_verify_threshold "Protection Mode" 75 80
    pause_return
}

action_travel() {
    clear
    echo "Ativando Travel Mode (carregar até 100%)..."
    echo
    echo "Obs.: o TLP trata start=0 como \"não gerenciar esse limite\" e não"
    echo "escreve isso no hardware — por isso usamos 'tlp fullcharge', o comando"
    echo "dedicado do TLP pra ignorar o start threshold e carregar até o stop"
    echo "threshold uma vez. Precisa estar com o carregador conectado."
    echo

    local cur_start cur_stop
    read -r cur_start cur_stop <<< "$(read_thresholds_sysfs)"

    # 1) garante stop=100 sem tentar mexer no start (que é onde o setcharge
    #    falha silenciosamente nesse tipo de driver).
    if [[ "$cur_stop" != "100" ]]; then
        echo "Ajustando stop threshold para 100% (mantendo start=${cur_start}%)..."
        sudo tlp setcharge "$cur_start" 100 "$BAT"
        sleep 1
        read -r cur_start cur_stop <<< "$(read_thresholds_sysfs)"
        echo
    fi

    # 2) ignora o start threshold uma vez, via comando dedicado do TLP.
    sudo tlp fullcharge "$BAT"
    local rc=$?
    echo
    sleep 1
    read -r cur_start cur_stop <<< "$(read_thresholds_sysfs)"

    if [[ "$cur_stop" == "100" ]]; then
        echo "✔ Stop threshold confirmado em 100% (start atual no sysfs: ${cur_start}%,"
        echo "  ignorado uma vez pelo fullcharge). A bateria deve seguir carregando até 100%."
    else
        echo "⚠ tlp fullcharge retornou código $rc, mas o stop threshold no sysfs"
        echo "  está em ${cur_stop}% (esperado 100%)."
        echo "  Rode 'sudo tlp-stat -b' e confira 'Charge'/'Capacity' pra ver se já subiu."
    fi
    pause_return
}

action_discharge() {
    clear
    echo "ATENÇÃO: a bateria será descarregada até o limite configurado no TLP."
    echo
    if confirm_yn "Deseja continuar?"; then
        echo
        sudo tlp discharge "$BAT"
    else
        echo "Operação cancelada."
    fi
    pause_return
}

action_recalibrate() {
    clear
    echo "ATENÇÃO: a recalibração descarrega e recarrega totalmente a bateria."
    echo "Isso pode levar várias horas e precisa do carregador conectado no"
    echo "final do processo (para completar a recarga até 100%)."
    echo
    if confirm_yn "Deseja continuar?"; then
        echo
        echo "Iniciando recalibração da bateria..."
        sudo tlp recalibrate "$BAT"
    else
        echo "Operação cancelada."
    fi
    pause_return
}

action_health() {
    show_battery_health
    pause_return
}

action_history() {
    show_history
    pause_return
}

run_action() {
    case $selected in
        0) action_status ;;
        1) action_protection ;;
        2) action_travel ;;
        3) action_discharge ;;
        4) action_recalibrate ;;
        5) action_health ;;
        6) action_history ;;
        7) show_cursor; clear; exit 0 ;;
    esac
}

main() {
    hide_cursor
    while true; do
        draw_menu
        case "$(read_key)" in
            UP)    ((selected = (selected - 1 + ${#MENU_ITEMS[@]}) % ${#MENU_ITEMS[@]})) ;;
            DOWN)  ((selected = (selected + 1) % ${#MENU_ITEMS[@]})) ;;
            RIGHT) run_action ;;
            LEFT)  : ;;  # no menu principal, esquerda não tem "pai" pra voltar
            *)     : ;;
        esac
    done
}

main
