#!/usr/bin/env bash
# RTL netlist schematics for docs/img: Yosys -> JSON -> netlistsvg.
# Needs yosys and npx (Node.js).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build docs/img

for top in baud_gen; do
    yosys -q -p "read_verilog rtl/baud_gen.v rtl/uart_rx.v; hierarchy -top $top; proc; flatten; opt -full; clean; write_json build/${top}.json"
    npx --yes netlistsvg@1.0.2 "build/${top}.json" -o "docs/img/${top}_netlist.svg"
    echo "wrote docs/img/${top}_netlist.svg"
done
