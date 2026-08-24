#!/usr/bin/env bash
#
# battery-health.sh
#
# Cálculo de saúde da bateria + gráficos ASCII de histórico
# (estilo "Battery health" em barras, com eixo de % e datas).
# Feito para ser "sourced" pelo battery-control.sh (e usa o battery-monitor.sh
# por baixo para ler a bateria e o histórico).

SCRIPT_DIR_HEALTH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=battery-monitor.sh
source "$SCRIPT_DIR_HEALTH/battery-monitor.sh"

# render_chart <groupby: day|month> <field: capacity|health> <title>
#
# Lê $HISTORY_CSV, agrupa por dia ou por mês (média dos pontos), e desenha
# um gráfico de barras em ASCII parecido com:
#
#   Battery health
#   100% ┤████████████████████
#    95% ┤███████████████████
#    90% ┤█████████████████
#        └────────────────────
#          Jan  Mar  Mai  Jul  Ago
render_chart() {
    local groupby="$1" field="$2" title="$3"

    if [[ ! -s "$HISTORY_CSV" ]]; then
        echo "Ainda não há histórico suficiente. Deixe o thinkpad-battery.timer rodando por um tempo."
        return
    fi

    local design="0"
    if [[ "$field" == "health" ]]; then
        collect >/dev/null 2>&1 || true
        design="${ENERGY_FULL_DESIGN_WH:-0}"
    fi

    awk -F',' -v groupby="$groupby" -v field="$field" -v title="$title" -v design="$design" '
    BEGIN {
        split("Jan,Fev,Mar,Abr,Mai,Jun,Jul,Ago,Set,Out,Nov,Dez", monthnames, ",")
    }
    NR==1 { next }
    NF < 9 { next }
    {
        ts=$1; capacity=$2+0; energy_full=$4+0

        split(ts, dt, "T")
        split(dt[1], ymd, "-")

        if (groupby == "day") key = ymd[1]"-"ymd[2]"-"ymd[3]
        else key = ymd[1]"-"ymd[2]

        if (field == "health" && design > 0 && energy_full > 0)
            val = (energy_full/design)*100
        else
            val = capacity

        if (!(key in seen)) { order[++n] = key; seen[key]=1 }
        sum[key] += val
        cnt[key] += 1
    }
    END {
        if (n == 0) { print "Sem dados suficientes."; exit }

        # mantém só os últimos 20 pontos, pra não estourar a largura do terminal
        start = (n > 20) ? n-19 : 1

        maxv = -1; minv = 1000000
        for (i=start; i<=n; i++) {
            k = order[i]
            avg[k] = sum[k]/cnt[k]
            if (avg[k] > maxv) maxv = avg[k]
            if (avg[k] < minv) minv = avg[k]
        }

        top = int((maxv + 4) / 5) * 5
        if (top > 100) top = 100
        if (top < maxv) top += 5
        bottom = int(minv / 5) * 5
        if (bottom >= top) bottom = top - 5
        if (bottom < 0) bottom = 0

        print title
        for (level = top; level >= bottom; level -= 5) {
            line = sprintf("%3d%% ┤", level)
            for (i=start; i<=n; i++) {
                k = order[i]
                line = line (avg[k] >= level ? "████" : "    ")
            }
            print line
        }

        line = "    └"
        for (i=start; i<=n; i++) line = line "────"
        print line

        line = "      "
        for (i=start; i<=n; i++) {
            k = order[i]
            split(k, p, "-")
            if (groupby == "day") line = line sprintf("%-4s", p[3]"/"p[2])
            else { mi = p[2]+0; line = line sprintf("%-4s", monthnames[mi]) }
        }
        print line
    }
    ' "$HISTORY_CSV"
}

show_battery_health() {
    collect || { echo "Não foi possível ler a bateria."; return; }

    clear
    echo "=== Saúde da bateria ==="
    echo
    echo "Saúde estimada       : ${HEALTH_PCT}%  (energia máxima atual / energia de projeto)"
    echo "Energia máxima atual : ${ENERGY_FULL_WH} Wh"
    echo "Energia de projeto   : ${ENERGY_FULL_DESIGN_WH} Wh"
    echo "Ciclos de carga      : ${CYCLE_COUNT}"
    echo "Status atual         : ${STATUS} (${CAPACITY}%)"
    echo
    render_chart "month" "health" "Battery health"
    echo
}

show_history() {
    clear
    echo "=== Histórico de uso ==="
    echo
    render_chart "day" "capacity" "Capacidade da bateria (por dia)"
    echo
    echo "Últimas leituras registradas:"
    echo
    if [[ -s "$HISTORY_CSV" ]]; then
        printf "%-20s %5s %7s %7s %10s\n" "Timestamp" "Cap%" "Pot(W)" "Temp°C" "Status"
        tail -n +2 "$HISTORY_CSV" | tail -n 10 | awk -F',' '{printf "%-20s %5s %7s %7s %10s\n", $1, $2, $6, ($7==""?"N/A":$7), $9}'
    else
        echo "Nenhum registro ainda."
    fi
    echo
}
