#!/usr/bin/env bash
#
# Metrics/thinkpad-battery-exporter.sh
#
# Gera métricas no formato "node_exporter textfile collector"
# (https://github.com/prometheus/node_exporter#textfile-collector) a partir
# da leitura atual da bateria, prontas pra serem raspadas pelo Prometheus.
#
# Também grava um snapshot em JSON (~/.local/state/thinkpad-battery/latest_metrics.json)
# útil pra debug manual ou pra um datasource "JSON API" no Grafana.
#
# Variáveis de ambiente:
#   PROM_TEXTFILE_DIR  Diretório do textfile collector do node_exporter.
#                       Precisa bater com a flag --collector.textfile.directory
#                       usada ao iniciar o node_exporter.
#                       Padrão: /var/lib/node_exporter/textfile_collector

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../battery-monitor.sh
source "$PROJECT_DIR/battery-monitor.sh"

PROM_TEXTFILE_DIR="${PROM_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM_FILE="$PROM_TEXTFILE_DIR/thinkpad_battery.prom"
PROM_FILE_TMP="${PROM_FILE}.$$.tmp"

collect || exit 1

bat_name="$(basename "$BAT_PATH")"
status_label="${STATUS:-Unknown}"

mkdir -p "$PROM_TEXTFILE_DIR" || {
    echo "Aviso: não consegui criar $PROM_TEXTFILE_DIR (permissão?). Rode como root/usuário do node_exporter." >&2
}

{
    echo "# HELP thinkpad_battery_capacity_percent Nivel de carga atual da bateria (%)"
    echo "# TYPE thinkpad_battery_capacity_percent gauge"
    echo "thinkpad_battery_capacity_percent{battery=\"${bat_name}\"} ${CAPACITY}"

    echo "# HELP thinkpad_battery_health_percent Saude estimada: energia maxima atual / energia de projeto (%)"
    echo "# TYPE thinkpad_battery_health_percent gauge"
    echo "thinkpad_battery_health_percent{battery=\"${bat_name}\"} ${HEALTH_PCT}"

    echo "# HELP thinkpad_battery_energy_now_wh Energia atual armazenada (Wh)"
    echo "# TYPE thinkpad_battery_energy_now_wh gauge"
    echo "thinkpad_battery_energy_now_wh{battery=\"${bat_name}\"} ${ENERGY_NOW_WH}"

    echo "# HELP thinkpad_battery_energy_full_wh Capacidade maxima atual (Wh)"
    echo "# TYPE thinkpad_battery_energy_full_wh gauge"
    echo "thinkpad_battery_energy_full_wh{battery=\"${bat_name}\"} ${ENERGY_FULL_WH}"

    echo "# HELP thinkpad_battery_energy_full_design_wh Capacidade maxima de projeto (Wh)"
    echo "# TYPE thinkpad_battery_energy_full_design_wh gauge"
    echo "thinkpad_battery_energy_full_design_wh{battery=\"${bat_name}\"} ${ENERGY_FULL_DESIGN_WH}"

    echo "# HELP thinkpad_battery_voltage_volts Tensao atual (V)"
    echo "# TYPE thinkpad_battery_voltage_volts gauge"
    echo "thinkpad_battery_voltage_volts{battery=\"${bat_name}\"} ${VOLTAGE_V}"

    echo "# HELP thinkpad_battery_power_watts Potencia instantanea (W)"
    echo "# TYPE thinkpad_battery_power_watts gauge"
    echo "thinkpad_battery_power_watts{battery=\"${bat_name}\"} ${POWER_W}"

    if [[ -n "${TEMP_C:-}" ]]; then
        echo "# HELP thinkpad_battery_temperature_celsius Temperatura da bateria (graus Celsius)"
        echo "# TYPE thinkpad_battery_temperature_celsius gauge"
        echo "thinkpad_battery_temperature_celsius{battery=\"${bat_name}\"} ${TEMP_C}"
    fi

    echo "# HELP thinkpad_battery_cycle_count Numero de ciclos de carga completos"
    echo "# TYPE thinkpad_battery_cycle_count counter"
    echo "thinkpad_battery_cycle_count{battery=\"${bat_name}\"} ${CYCLE_COUNT}"

    echo "# HELP thinkpad_battery_status Status atual da bateria (1 = ativo para o label 'status')"
    echo "# TYPE thinkpad_battery_status gauge"
    for s in Charging Discharging Full "Not charging" Unknown; do
        v=0
        [[ "$s" == "$status_label" ]] && v=1
        echo "thinkpad_battery_status{battery=\"${bat_name}\",status=\"${s}\"} ${v}"
    done

    if [[ -r "$BAT_PATH/charge_control_start_threshold" && -r "$BAT_PATH/charge_control_end_threshold" ]]; then
        start_thr=$(cat "$BAT_PATH/charge_control_start_threshold")
        stop_thr=$(cat "$BAT_PATH/charge_control_end_threshold")
        echo "# HELP thinkpad_battery_charge_threshold_start_percent Limite inferior de carga configurado (%)"
        echo "# TYPE thinkpad_battery_charge_threshold_start_percent gauge"
        echo "thinkpad_battery_charge_threshold_start_percent{battery=\"${bat_name}\"} ${start_thr}"
        echo "# HELP thinkpad_battery_charge_threshold_stop_percent Limite superior de carga configurado (%)"
        echo "# TYPE thinkpad_battery_charge_threshold_stop_percent gauge"
        echo "thinkpad_battery_charge_threshold_stop_percent{battery=\"${bat_name}\"} ${stop_thr}"
    fi
} > "$PROM_FILE_TMP" && mv "$PROM_FILE_TMP" "$PROM_FILE"

# Snapshot em JSON (state dir do usuário, não versionado no repo).
mkdir -p "$STATE_DIR"
JSON_SNAPSHOT="$STATE_DIR/latest_metrics.json"
temp_json_value="null"
[[ -n "${TEMP_C:-}" ]] && temp_json_value="${TEMP_C}"

cat > "$JSON_SNAPSHOT" <<JSON
{
  "timestamp": "${TS}",
  "battery": "${bat_name}",
  "capacity_percent": ${CAPACITY},
  "health_percent": ${HEALTH_PCT},
  "energy_now_wh": ${ENERGY_NOW_WH},
  "energy_full_wh": ${ENERGY_FULL_WH},
  "energy_full_design_wh": ${ENERGY_FULL_DESIGN_WH},
  "voltage_volts": ${VOLTAGE_V},
  "power_watts": ${POWER_W},
  "temperature_celsius": ${temp_json_value},
  "cycle_count": ${CYCLE_COUNT},
  "status": "${STATUS}"
}
JSON
