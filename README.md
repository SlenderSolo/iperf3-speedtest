# iperf3 speedtest

A lightweight shell script to test network speed (Ping, Download, Upload) across multiple regions using `iperf3`.

## Usage

**Run full test:**
```bash
sh <(wget -qO- https://raw.githubusercontent.com/SlenderSolo/iperf3-speedtest/refs/heads/main/speedtest.sh)
```

**Run fast test (first server only):**
```bash
sh <(wget -qO- https://raw.githubusercontent.com/SlenderSolo/iperf3-speedtest/refs/heads/main/speedtest.sh) -f
```

## Features

- **Auto-dependency check:** Prompts to install `iperf3` automatically if missing (supports `apt` and `apk`).
- **Interactive region selection:** Choose between Russia, Europe, or USA.
- **Failover & Load Balancing:** Automatically rotates through port ranges and retries if a server is busy.

## Servers

| Russia | Europe | USA |
| :--- | :--- | :--- |
| Hostkey Moscow | Hostkey Germany | Clouvider Ashburn |
| MTS Moscow | LeaseWeb Netherlands | LeaseWeb Miami |
| Ertelecom St. Petersburg | LeaseWeb UK | Clouvider Los Angeles |
| Ertelecom Rostov-on-Don | Hostkey Finland | LeaseWeb Seattle |
| Ertelecom Novosibirsk | Scaleway France | Clouvider Dallas |
