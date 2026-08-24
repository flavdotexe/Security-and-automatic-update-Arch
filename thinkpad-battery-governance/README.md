# ThinkPad Battery Governance

Controle e observabilidade de bateria para ThinkPad no Linux, usando TLP.
`tlp.conf` neste repositório é calibrado pro T495 com Ryzen 7 3700u — ajuste
os valores de CPU/PCIe/USB pra outra máquina se for reaproveitar.

```
thinkpad-battery-governance/
├── Metrics/
│   ├── thinkpad-battery-exporter.sh        # gera métricas Prometheus + JSON
│   ├── thinkpad-battery-exporter.service
│   ├── thinkpad-battery-exporter.timer
│   ├── prometheus-scrape-config.yml
│   ├── grafana-dashboard.json              # importar direto no Grafana
│   └── README.md
├── battery-control.sh     # menu interativo (setas)
├── battery-monitor.sh     # coleta + grava histórico em CSV
├── battery-health.sh      # saúde da bateria + gráficos ASCII
├── tlp.conf
├── thinkpad-battery.service
├── thinkpad-battery.timer
└── README.md
```

## Instalação

```bash
sudo pacman -S tlp prometheus-node-exporter   # node_exporter é opcional, só pra métricas

sudo cp tlp.conf /etc/tlp.conf
sudo systemctl enable --now tlp.service

sudo mkdir -p /opt/thinkpad-battery-governance
sudo cp -r . /opt/thinkpad-battery-governance/
sudo chmod +x /opt/thinkpad-battery-governance/*.sh /opt/thinkpad-battery-governance/Metrics/*.sh
```

## Histórico de uso

`battery-monitor.sh` grava uma linha por leitura em:

```
~/.local/state/thinkpad-battery/history.csv
```

com as colunas:

```
timestamp,capacity,energy_now,energy_full,voltage,power,temperature,cycle_count,status
```

Pra manter isso alimentado sozinho, habilite o timer:

```bash
sudo cp thinkpad-battery.service thinkpad-battery.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now thinkpad-battery.timer
```

Por padrão ele roda a cada 10 minutos (`OnUnitActiveSec=10min` no timer,
ajustável).

## Uso — menu interativo

```bash
./battery-control.sh
```

```
===============================
  ThinkPad Battery Governance
===============================

   1. Status
   2. Protection Mode   75% -> 80%
   3. Travel Mode        0% -> 100%
   4. Discharge
   5. Recalibrate
   6. Battery health
   7. History
   8. Exit

  BAT: BAT0

↑/↓ navega    → seleciona    ← volta
```

Navegação exclusivamente por setas: **↑/↓** move o cursor, **→** seleciona/executa,
**←** volta pra tela anterior. Nada de Enter nem Esc. As duas ações
potencialmente demoradas/destrutivas (**Discharge** e **Recalibrate**) pedem
confirmação `(Y/n)` digitada normalmente antes de rodar.

> Nota: o menu original tinha uma numeração com um item pulado (1, 2, 4, 5...);
> aqui ficou renumerado sequencialmente (1 a 8) mantendo a mesma ordem das
> opções que você pediu.

### Battery health

Mostra saúde estimada (energia máxima atual ÷ energia de projeto), energia
máxima atual/de projeto, ciclos de carga, e um gráfico de barras em ASCII
com a evolução mensal:

```
Battery health
100% ┤████████████████████
 95% ┤███████████████████
 90% ┤█████████████████
     └────────────────────
       Jan  Mar  Mai  Jul  Ago
```

### History

Mesmo estilo de gráfico, mas com a capacidade diária dos últimos pontos
registrados, seguido de uma tabela com as últimas 10 leituras brutas do CSV.

## Observabilidade (Grafana + Prometheus + node_exporter)

A pasta `Metrics/` já vem pronta pra exportar tudo isso pra fora do
terminal: um exportador no formato **node_exporter textfile collector**, os
units systemd pra rodar sozinho, um exemplo de scrape config do Prometheus, e
um **dashboard Grafana em JSON** pronto pra importar.

Ver `Metrics/README.md` para o passo a passo completo. Resumo:

```bash
sudo cp Metrics/thinkpad-battery-exporter.service Metrics/thinkpad-battery-exporter.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now thinkpad-battery-exporter.timer
```

Isso gera `/var/lib/node_exporter/textfile_collector/thinkpad_battery.prom`
a cada minuto, que o node_exporter expõe e o Prometheus raspa. Depois é só
importar `Metrics/grafana-dashboard.json` no Grafana.

## Comandos TLP usados por trás do menu

| Ação | Comando |
|---|---|
| Protection Mode | `tlp setcharge 75 80 BAT0` |
| Travel Mode | `tlp setcharge 0 100 BAT0` |
| Discharge | `tlp discharge BAT0` |
| Recalibrate | `tlp recalibrate BAT0` |
| Status | `tlp-stat -b` + leitura direta de `/sys/class/power_supply/BAT0` |
