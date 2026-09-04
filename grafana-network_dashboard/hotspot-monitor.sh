#!/bin/bash
#
# hotspot-monitor.sh
# Coleta a lista de dispositivos conectados no hotspot (AP) do host,
# garantindo o IP de cada um (lease do dnsmasq, com fallback na tabela
# de vizinhos/ARP quando nao ha lease), no formato Prometheus textfile
# collector.
#
# Uso: hotspot-monitor.sh <interface>   (padrao: wlan0)

set -euo pipefail

OUTPUT_DIR="/var/lib/node_exporter/textfile_collector"
OUTPUT_FILE="${OUTPUT_DIR}/hotspot_devices.prom"
TMP_FILE="$(mktemp)"
IFACE="${1:-wlan0}"

LEASES_CANDIDATES=(
    "/var/lib/misc/dnsmasq.leases"
    "/var/lib/NetworkManager/dnsmasq-${IFACE}.leases"
)

mkdir -p "$OUTPUT_DIR"

LEASES_FILE=""
for f in "${LEASES_CANDIDATES[@]}"; do
    [[ -f "$f" ]] && LEASES_FILE="$f" && break
done

macs=()
if command -v iw >/dev/null 2>&1; then
    mapfile -t macs < <(iw dev "$IFACE" station dump 2>/dev/null | awk '/^Station/ {print $2}')
fi

count=${#macs[@]}
device_lines=()

for mac in "${macs[@]}"; do
    ip="desconhecido"
    hostname="desconhecido"

    # 1) Tenta pegar IP/hostname no lease do dnsmasq (mais confiavel)
    if [[ -n "$LEASES_FILE" ]]; then
        lease_line=$(grep -i "$mac" "$LEASES_FILE" | tail -1 || true)
        if [[ -n "$lease_line" ]]; then
            ip=$(awk '{print $3}' <<< "$lease_line")
            h=$(awk '{print $4}' <<< "$lease_line")
            [[ -n "$h" && "$h" != "*" ]] && hostname="$h"
        fi
    fi

    # 2) Fallback: se nao achou no lease, busca na tabela de vizinhos (ARP)
    #    da propria interface — garante IP mesmo sem dnsmasq configurado.
    if [[ "$ip" == "desconhecido" ]] && command -v ip >/dev/null 2>&1; then
        neigh_ip=$(ip neigh show dev "$IFACE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1 || true)
        [[ -n "$neigh_ip" ]] && ip="$neigh_ip"
    fi

    device_lines+=("hotspot_device_info{mac=\"${mac}\",ip=\"${ip}\",hostname=\"${hostname}\",iface=\"${IFACE}\"} 1")
done

{
    echo "# HELP hotspot_connected_devices Numero de dispositivos conectados ao hotspot"
    echo "# TYPE hotspot_connected_devices gauge"
    echo "hotspot_connected_devices ${count}"

    echo "# HELP hotspot_device_info Dispositivo conectado ao hotspot, com IP garantido (lease ou ARP)"
    echo "# TYPE hotspot_device_info gauge"
    for l in "${device_lines[@]:-}"; do
        [[ -n "$l" ]] && echo "$l"
    done
} > "$TMP_FILE"

chmod 644 "$TMP_FILE"
mv "$TMP_FILE" "$OUTPUT_FILE"
