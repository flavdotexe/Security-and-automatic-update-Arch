#!/usr/bin/env bash
#
# battery-monitor.sh
#
# Coleta os dados atuais da bateria via /sys/class/power_supply e grava
# um histórico em CSV. Pode ser:
#   - executado diretamente (é o que o thinkpad-battery.timer faz, para
#     alimentar o histórico usado pelos gráficos); ou
#   - "sourced" por outros scripts (battery-health.sh,
#     Metrics/thinkpad-battery-exporter.sh) que só querem reaproveitar as
#     funções de coleta, sem disparar o log automático.
#
# Histórico gravado em: ~/.local/state/thinkpad-battery/history.csv
# Colunas: timestamp,capacity,energy_now,energy_full,voltage,power,temperature,cycle_count,status

set -uo pipefail

# --- Configuração ----------------------------------------------------------

STATE_DIR="${STATE_DIR:-$HOME/.local/state/thinkpad-battery}"
HISTORY_CSV="${HISTORY_CSV:-$STATE_DIR/history.csv}"
HISTORY_HEADER="timestamp,capacity,energy_now,energy_full,voltage,power,temperature,cycle_count,status"

# Detecta a bateria: tenta BAT0/BAT1 primeiro, senão pega a primeira BAT* disponível.
detect_battery_path() {
    local p
    for p in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
        [[ -d "$p" ]] && { echo "$p"; return 0; }
    done
    p=$(find /sys/class/power_supply -maxdepth 1 -iname 'BAT*' 2>/dev/null | sort | head -n1)
    [[ -n "$p" ]] && { echo "$p"; return 0; }
    return 1
}

BAT_PATH="${BAT_PATH:-$(detect_battery_path)}"

_read_sysfs() {
    local file="$1"
    [[ -r "$file" ]] && cat "$file" 2>/dev/null
}

# --- Coleta ------------------------------------------------------------
#
# Preenche variáveis globais com a leitura atual da bateria:
#   TS, CAPACITY, ENERGY_NOW_WH, ENERGY_FULL_WH, ENERGY_FULL_DESIGN_WH,
#   VOLTAGE_V, POWER_W, TEMP_C, CYCLE_COUNT, STATUS, HEALTH_PCT
collect() {
    if [[ -z "${BAT_PATH:-}" || ! -d "$BAT_PATH" ]]; then
        echo "Erro: nenhuma bateria encontrada em /sys/class/power_supply/" >&2
        return 1
    fi

    TS=$(date -Iseconds)
    CAPACITY=$(_read_sysfs "$BAT_PATH/capacity"); CAPACITY=${CAPACITY:-0}
    STATUS=$(_read_sysfs "$BAT_PATH/status"); STATUS=${STATUS:-Unknown}
    CYCLE_COUNT=$(_read_sysfs "$BAT_PATH/cycle_count"); CYCLE_COUNT=${CYCLE_COUNT:-0}

    local energy_now_raw energy_full_raw energy_full_design_raw
    local voltage_raw power_raw current_raw

    energy_now_raw=$(_read_sysfs "$BAT_PATH/energy_now")
    energy_full_raw=$(_read_sysfs "$BAT_PATH/energy_full")
    energy_full_design_raw=$(_read_sysfs "$BAT_PATH/energy_full_design")
    voltage_raw=$(_read_sysfs "$BAT_PATH/voltage_now")
    power_raw=$(_read_sysfs "$BAT_PATH/power_now")
    current_raw=$(_read_sysfs "$BAT_PATH/current_now")

    # Algumas baterias (ACPI antigo) reportam em charge_* (µAh) em vez de energy_* (µWh).
    [[ -z "$energy_now_raw" ]] && energy_now_raw=$(_read_sysfs "$BAT_PATH/charge_now")
    [[ -z "$energy_full_raw" ]] && energy_full_raw=$(_read_sysfs "$BAT_PATH/charge_full")
    [[ -z "$energy_full_design_raw" ]] && energy_full_design_raw=$(_read_sysfs "$BAT_PATH/charge_full_design")

    energy_now_raw=${energy_now_raw:-0}
    energy_full_raw=${energy_full_raw:-0}
    energy_full_design_raw=${energy_full_design_raw:-0}
    voltage_raw=${voltage_raw:-0}
    current_raw=${current_raw:-0}

    if [[ -z "$power_raw" || "$power_raw" == "0" ]]; then
        # P(µW) = V(µV) * I(µA) / 1e6
        power_raw=$(awk -v v="$voltage_raw" -v i="$current_raw" 'BEGIN{printf "%.0f", (v*i)/1000000}')
    fi

    ENERGY_NOW_WH=$(awk -v x="$energy_now_raw" 'BEGIN{printf "%.3f", x/1000000}')
    ENERGY_FULL_WH=$(awk -v x="$energy_full_raw" 'BEGIN{printf "%.3f", x/1000000}')
    ENERGY_FULL_DESIGN_WH=$(awk -v x="$energy_full_design_raw" 'BEGIN{printf "%.3f", x/1000000}')
    VOLTAGE_V=$(awk -v x="$voltage_raw" 'BEGIN{printf "%.3f", x/1000000}')
    POWER_W=$(awk -v x="$power_raw" 'BEGIN{printf "%.3f", x/1000000}')

    # Temperatura: nem todo ThinkPad expõe isso via sysfs. Tenta sysfs, depois upower.
    local temp_raw=""
    temp_raw=$(_read_sysfs "$BAT_PATH/temp")
    TEMP_C=""
    if [[ -n "$temp_raw" ]]; then
        TEMP_C=$(awk -v x="$temp_raw" 'BEGIN{printf "%.1f", x/10}')
    elif command -v upower >/dev/null 2>&1; then
        local dev
        dev=$(upower -e 2>/dev/null | grep -i battery | head -n1)
        if [[ -n "$dev" ]]; then
            TEMP_C=$(upower -i "$dev" 2>/dev/null | awk -F: '/temperature/{gsub(/[^0-9.]/,"",$2); print $2}')
        fi
    fi

    # Saúde estimada = energia máxima atual / energia máxima de projeto
    if awk -v d="$ENERGY_FULL_DESIGN_WH" 'BEGIN{exit !(d>0)}'; then
        HEALTH_PCT=$(awk -v f="$ENERGY_FULL_WH" -v d="$ENERGY_FULL_DESIGN_WH" 'BEGIN{printf "%.1f", (f/d)*100}')
    else
        HEALTH_PCT="$CAPACITY"
    fi
}

# --- Histórico ---------------------------------------------------------

ensure_history_file() {
    mkdir -p "$STATE_DIR"
    [[ -f "$HISTORY_CSV" ]] || echo "$HISTORY_HEADER" > "$HISTORY_CSV"
}

log_history() {
    ensure_history_file
    echo "${TS},${CAPACITY},${ENERGY_NOW_WH},${ENERGY_FULL_WH},${VOLTAGE_V},${POWER_W},${TEMP_C},${CYCLE_COUNT},${STATUS}" >> "$HISTORY_CSV"
}

# --- Status legível (usado pelo menu "Status") --------------------------

print_status() {
    collect || return 1
    echo "Bateria detectada  : $(basename "$BAT_PATH")"
    echo "Status             : $STATUS"
    echo "Capacidade         : ${CAPACITY}%"
    echo "Saúde estimada     : ${HEALTH_PCT}%"
    echo "Energia atual      : ${ENERGY_NOW_WH} Wh"
    echo "Energia máx. (full): ${ENERGY_FULL_WH} Wh"
    echo "Energia de projeto : ${ENERGY_FULL_DESIGN_WH} Wh"
    echo "Tensão             : ${VOLTAGE_V} V"
    echo "Potência           : ${POWER_W} W"
    if [[ -n "$TEMP_C" ]]; then
        echo "Temperatura        : ${TEMP_C} °C"
    else
        echo "Temperatura        : indisponível"
    fi
    echo "Ciclos de carga    : ${CYCLE_COUNT}"
    if [[ -r "$BAT_PATH/charge_control_start_threshold" && -r "$BAT_PATH/charge_control_end_threshold" ]]; then
        echo "Limite configurado : $(cat "$BAT_PATH/charge_control_start_threshold")% → $(cat "$BAT_PATH/charge_control_end_threshold")%"
    fi
    if command -v tlp-stat >/dev/null 2>&1; then
        echo
        echo "--- tlp-stat -b ---"
        sudo tlp-stat -b 2>/dev/null || tlp-stat -b 2>/dev/null
    fi
}

# --- Execução direta (chamada pelo thinkpad-battery.timer) ---------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    collect || exit 1
    log_history
fi
