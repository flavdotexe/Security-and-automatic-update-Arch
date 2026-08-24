#!/bin/bash

FAN="/proc/acpi/ibm/fan"
THERMAL="/proc/acpi/ibm/thermal"

LEVEL7="level 7"
FULLSPEED="level full-speed"

last_mode=""

# Garante que o módulo esteja carregado com controle manual
if ! grep -q "^Y$" /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null; then
    modprobe thinkpad_acpi fan_control=1
fi

while true; do
    # Primeiro sensor térmico reportado pelo ThinkPad
    temp=$(awk '/^temperatures:/ {print $2}' "$THERMAL")

    if [[ "$temp" =~ ^[0-9]+$ ]]; then

        if (( temp >= 65 )); then
            mode="full-speed"

            if [[ "$last_mode" != "$mode" ]]; then
                echo "$FULLSPEED" > "$FAN"
                last_mode="$mode"
            fi

        else
            mode="level-7"

            if [[ "$last_mode" != "$mode" ]]; then
                echo "$LEVEL7" > "$FAN"
                last_mode="$mode"
            fi
        fi
    fi

    sleep 2
done
