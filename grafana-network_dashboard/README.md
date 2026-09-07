# Network Supervisor

Package with Grafana dashboard + Prometheus collectors for:
- Brute force attempts / possible DDoS on SSH (+ active SSH sessions)
- Device governance: **hotspot**, **virtual networks** (bridge/libvirt/docker) and **SSH**, all with IP
- Bandwidth consumption (GB download/upload) — summary and charts

## 1. Prerequisites (pacman)

```bash
sudo pacman -S prometheus node_exporter grafana iw
# optional, recommended:
sudo pacman -S fail2ban
# optional, only if you use these technologies:
sudo pacman -S libvirt        # for virsh
# docker via AUR/official repos, if you use containers
```

## 2. Enable the textfile collector on node_exporter

```bash
sudo mkdir -p /var/lib/node_exporter/textfile_collector
sudo chown node_exporter:node_exporter /var/lib/node_exporter/textfile_collector
```

```bash
sudo systemctl edit node_exporter
```

Add:
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart node_exporter
```

## 3. Install the collector scripts

```bash
sudo install -Dm755 ssh-monitor.sh /usr/local/bin/ssh-monitor.sh
sudo install -Dm755 hotspot-monitor.sh /usr/local/bin/hotspot-monitor.sh
sudo install -Dm755 virtual-networks-monitor.sh /usr/local/bin/virtual-networks-monitor.sh
```

Edit `hotspot-monitor.service` and replace `wlan0` with the actual
interface of your hotspot (check with `iw dev` or `nmcli device`).

```bash
sudo cp ssh-monitor.service ssh-monitor.timer /etc/systemd/system/
sudo cp hotspot-monitor.service hotspot-monitor.timer /etc/systemd/system/
sudo cp virtual-networks-monitor.service virtual-networks-monitor.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ssh-monitor.timer hotspot-monitor.timer virtual-networks-monitor.timer
```

Test manually:
```bash
sudo /usr/local/bin/ssh-monitor.sh
sudo /usr/local/bin/hotspot-monitor.sh wlan0
sudo /usr/local/bin/virtual-networks-monitor.sh
cat /var/lib/node_exporter/textfile_collector/*.prom
```

> **Note about sshd**: the scripts read `journalctl -u sshd`. If your sshd
> appears under a different unit on your system (e.g., `sshd@.service` with
> socket activation), adjust the `-u sshd` in the script.
>
> **Note about permissions**: the timers run as root by default, which is
> necessary for `iw dev` (station dump), `virsh` and `docker inspect`.

## 4. Configure Prometheus

In `/etc/prometheus/prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'node_exporter'
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:9100']
```

```bash
sudo systemctl enable --now prometheus
sudo systemctl restart prometheus
```

## 5. Import the dashboard into Grafana

1. **Connections → Data sources** → add Prometheus (`http://localhost:9090`).
2. **Dashboards → Import** → upload `arch-network-supervisorio.json`.
3. Select your Prometheus datasource when prompted.
4. At the top of the dashboard: choose the **interface** variable (for the
   GB panels) and, optionally, filter **Virtual network** (`vnet`) to focus
   on a specific bridge/network in the governance tables.

## What each section shows

| Section | Panels |
|---|---|
| SSH Security | failed attempts, unique attacking IPs, connections on port 22 (DDoS/scan), banned IPs (fail2ban), chart over time, top 10 IPs table |
| Device Governance | hotspot / virtual networks / active SSH sessions count, hotspot table (MAC/IP/hostname), virtual networks table (network/IP/MAC/hostname/source), SSH sessions table (user/IP/TTY), combined history |
| Consumption (GB) | total download/upload in the last 24h, gauges for the period selected on the dashboard |
| Charts | real-time download/upload rate in Mbps, cumulative consumption in GB over the period |

## IP sources by device category

| Category | Primary source | Fallback |
|---|---|---|
| Hotspot | dnsmasq lease | interface ARP/neighbor table (`ip neigh`) |
| Generic bridges | ARP/NDP table (`ip neigh`) | — |
| Libvirt/QEMU | `virsh net-dhcp-leases` (includes hostname) | — |
| Docker | `docker inspect` per container | — |
| SSH | `who` (authenticated sessions with remote host) | — |

## Adjusting brute force/DDoS sensitivity

Thresholds on the SSH panels:
- Failed attempts: 5 min → warning at 5, critical at 15
- Connections on SSH port: warning at 30, critical at 100

Edit `thresholds.steps` in the JSON or via the UI (Edit panel → Thresholds)
according to your network's traffic profile.
