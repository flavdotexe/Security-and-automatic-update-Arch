# Metrics — Prometheus + node_exporter + Grafana

Essa pasta prepara a observabilidade da bateria: coleta de métricas no formato
Prometheus, um dashboard pronto pra importar no Grafana, e os units systemd
que mantêm tudo atualizado sozinho.

## Como funciona

```
battery-monitor.sh (coleta)  ──►  Metrics/thinkpad-battery-exporter.sh
                                        │
                                        ├─► /var/lib/node_exporter/textfile_collector/thinkpad_battery.prom
                                        │        (lido pelo node_exporter, raspado pelo Prometheus)
                                        │
                                        └─► ~/.local/state/thinkpad-battery/latest_metrics.json
                                                 (snapshot pra debug / datasource JSON API)
```

O `thinkpad-battery-exporter.sh` reaproveita a lógica de leitura do
`battery-monitor.sh` (via `source`), então os números batem com os do menu
`battery-control.sh` e com o histórico em CSV.

## 1. Instalar o node_exporter

```bash
# Arch / derivados
sudo pacman -S prometheus-node-exporter

# ou binário oficial: https://prometheus.io/download/#node_exporter
```

Garanta que ele suba com o textfile collector habilitado, apontando pro mesmo
diretório usado em `PROM_TEXTFILE_DIR`:

```bash
sudo mkdir -p /var/lib/node_exporter/textfile_collector
sudo chown SEU_USUARIO:SEU_USUARIO /var/lib/node_exporter/textfile_collector
```

Se estiver usando o pacote com systemd, edite o unit (ou um drop-in em
`/etc/systemd/system/node_exporter.service.d/override.conf`) e adicione a
flag:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
```

## 2. Instalar o exportador da bateria

```bash
sudo mkdir -p /opt/thinkpad-battery-governance
sudo cp -r ../* /opt/thinkpad-battery-governance/
sudo chmod +x /opt/thinkpad-battery-governance/*.sh /opt/thinkpad-battery-governance/Metrics/*.sh

sudo cp thinkpad-battery-exporter.service thinkpad-battery-exporter.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now thinkpad-battery-exporter.timer
```

Teste manualmente:

```bash
sudo /opt/thinkpad-battery-governance/Metrics/thinkpad-battery-exporter.sh
cat /var/lib/node_exporter/textfile_collector/thinkpad_battery.prom
```

## 3. Prometheus

Adicione o job de `prometheus-scrape-config.yml` ao seu `prometheus.yml` e
reinicie/recarregue o Prometheus:

```bash
curl -X POST http://localhost:9090/-/reload
```

## 4. Importar o dashboard no Grafana

1. Grafana → **Dashboards → New → Import**.
2. Cole o conteúdo de `grafana-dashboard.json` (ou faça upload do arquivo).
3. Selecione o datasource Prometheus quando solicitado (`DS_PROMETHEUS`).
4. Importar.

O dashboard traz:

- Gauge de capacidade atual e de saúde estimada (wear level)
- Contador de ciclos de carga
- Linha do tempo de status (`Charging` / `Discharging` / `Full` / ...)
- Séries temporais de capacidade, saúde, potência, tensão e temperatura
- Energia atual vs. máxima vs. de projeto (Wh)
- Limites de carga configurados (start/stop threshold, %)

## Métricas expostas

| Métrica | Tipo | Descrição |
|---|---|---|
| `thinkpad_battery_capacity_percent` | gauge | Carga atual (%) |
| `thinkpad_battery_health_percent` | gauge | Saúde estimada (%) |
| `thinkpad_battery_energy_now_wh` | gauge | Energia atual (Wh) |
| `thinkpad_battery_energy_full_wh` | gauge | Capacidade máxima atual (Wh) |
| `thinkpad_battery_energy_full_design_wh` | gauge | Capacidade máxima de projeto (Wh) |
| `thinkpad_battery_voltage_volts` | gauge | Tensão (V) |
| `thinkpad_battery_power_watts` | gauge | Potência instantânea (W) |
| `thinkpad_battery_temperature_celsius` | gauge | Temperatura (°C), quando disponível |
| `thinkpad_battery_cycle_count` | counter | Ciclos de carga completos |
| `thinkpad_battery_status{status="..."}` | gauge | 1 no status ativo, 0 nos demais |
| `thinkpad_battery_charge_threshold_start_percent` | gauge | Limite inferior configurado |
| `thinkpad_battery_charge_threshold_stop_percent` | gauge | Limite superior configurado |

Todas as métricas têm o label `battery="BAT0"` (ou o nome real detectado).
