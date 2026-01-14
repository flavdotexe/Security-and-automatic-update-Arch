#!/bin/bash

LOGFILE="$HOME/.system_update.log"

echo -e "\n Arch maintenance utility"
echo "----------------------------------"

read -p "Create snapshot before update? (Y/n): " SNAP
if [[ "$SNAP" == "y" || "$SNAP" == "Y" ]]; then
    echo "Creating snapshot..."
    sudo snapper create --description "snapshot-manual-$(date +%F_%H-%M)"
    echo "Snapshot created successfully!"
else
    echo "Skipping snapshot..."
fi


echo
echo "Starting update system..."

if command -v paru &>/dev/null; then
    paru -Syu --noconfirm
else
    sudo pacman -Syu --noconfirm
fi

echo
echo "Cleaning cache.."

sudo paccache -r
sudo pacman -Rns $(pacman -Qtdq 2>/dev/null) --noconfirm
echo "Clean system!"

echo
read -p "Reboot system now? (Y/n): " REBOOT
if [[ "$REBOOT" == "y" || "$REBOOT" == "Y" ]]; then
    echo "Salving log..."
    echo -e "[$(date '+%d-%m-%Y %H:%M')] System updated and successfully cleaned.\n" >> "$LOGFILE"
    sudo reboot
    fi
    
