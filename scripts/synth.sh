#!/usr/bin/env bash
# FPGA estimate: Yosys synth_ecp5 + nextpnr-ecp5 on a Lattice LFE5U-25F,
# 50 MHz target, default parameters (115200 8N1, 16x oversampling).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/synth
cd build/synth

yosys -q -l yosys.log -p "read_verilog ../../rtl/baud_gen.v ../../rtl/uart_rx.v; synth_ecp5 -top uart_rx -json uart_rx.json"
nextpnr-ecp5 --25k --package CABGA256 --freq 50 --json uart_rx.json \
    --report report.json --quiet --log nextpnr.log >/dev/null 2>&1

python3 - <<'PY'
import json
r = json.load(open("report.json"))
u = r["utilization"]
f = r["fmax"]
print("| Resource | Used | Available |")
print("|---|---|---|")
for k in ("TRELLIS_COMB", "TRELLIS_FF"):
    print(f"| {k} | {u[k]['used']} | {u[k]['available']} |")
for clk, v in f.items():
    print(f"| **Fmax** (clk) | **{v['achieved']:.1f} MHz** | target {v['constraint']:.0f} MHz |")
PY
