# UART receiver: simulation, lint, docs images, FPGA estimate.
#
#   make test        self-checking testbench in 5 frame formats (Icarus Verilog)
#   make sim         one run, override e.g.  make sim PARITY=2 STOP_BITS=2
#   make waves       VCD of the default run -> build/tb_uart_rx.vcd (gtkwave / surfer)
#   make lint        Verilator -Wall on the RTL
#   make diagrams    regenerate docs/img (waveforms + baud_gen netlist)
#   make synth       Yosys + nextpnr estimate on a Lattice ECP5-25F
#
# Tools: iverilog, verilator, yosys, nextpnr-ecp5 (e.g. OSS CAD Suite), python3, npx.

SHELL      := /bin/bash
RTL        := rtl/baud_gen.v rtl/uart_rx.v
BUILD      := build
IVERILOG   := iverilog -g2005 -Wall

DATA_BITS  ?= 8
PARITY     ?= 0
STOP_BITS  ?= 1
BAUD_RATE  ?= 115200
OVERSAMPLE ?= 16
N_RANDOM   ?= 200

# name:DATA_BITS:PARITY:STOP_BITS:BAUD_RATE:OVERSAMPLE:CLK_FREQ
CONFIGS := 8N1:8:0:1:115200:16:50000000 \
           8E1:8:2:1:115200:16:50000000 \
           7O2:7:1:2:115200:16:50000000 \
           9E1-8x:9:2:1:115200:8:12000000 \
           8N1-9600:8:0:1:9600:16:50000000

.PHONY: test sim waves lint diagrams netlist synth clean

$(BUILD):
	@mkdir -p $(BUILD)

test: | $(BUILD)
	@fail=0; for c in $(CONFIGS); do \
	    IFS=: read -r name db par sb baud os clk <<< "$$c"; \
	    $(IVERILOG) -P tb_uart_rx.DATA_BITS=$$db -P tb_uart_rx.PARITY=$$par \
	        -P tb_uart_rx.STOP_BITS=$$sb -P tb_uart_rx.BAUD_RATE=$$baud \
	        -P tb_uart_rx.OVERSAMPLE=$$os -P tb_uart_rx.CLK_FREQ=$$clk \
	        -P tb_uart_rx.N_RANDOM=$$([ $$baud -lt 100000 ] && echo 40 || echo 200) \
	        -o $(BUILD)/tb_$$name.vvp tb/tb_uart_rx.v $(RTL) || exit 1; \
	    out=$$(vvp -n $(BUILD)/tb_$$name.vvp); \
	    if grep -q "RESULT: PASS" <<< "$$out"; then \
	        printf "  %-10s PASS  (%s)\n" $$name "$$(grep 'words checked' <<< "$$out" | xargs)"; \
	    else \
	        printf "  %-10s FAIL\n" $$name; echo "$$out" | grep -E "FAIL|RESULT"; fail=1; \
	    fi; \
	done; exit $$fail

sim: | $(BUILD)
	$(IVERILOG) -P tb_uart_rx.DATA_BITS=$(DATA_BITS) -P tb_uart_rx.PARITY=$(PARITY) \
	    -P tb_uart_rx.STOP_BITS=$(STOP_BITS) -P tb_uart_rx.BAUD_RATE=$(BAUD_RATE) \
	    -P tb_uart_rx.OVERSAMPLE=$(OVERSAMPLE) -P tb_uart_rx.N_RANDOM=$(N_RANDOM) \
	    -o $(BUILD)/tb_uart_rx.vvp tb/tb_uart_rx.v $(RTL)
	vvp -n $(BUILD)/tb_uart_rx.vvp

waves: | $(BUILD)
	$(IVERILOG) -DDUMP -P tb_uart_rx.N_RANDOM=20 -o $(BUILD)/tb_uart_rx_dump.vvp tb/tb_uart_rx.v $(RTL)
	cd $(BUILD) && vvp -n tb_uart_rx_dump.vvp

lint:
	verilator --lint-only -Wall --top-module uart_rx $(RTL)
	verilator --lint-only -Wall --top-module uart_rx -GPARITY=2 -GSTOP_BITS=2 -GDATA_BITS=9 $(RTL)
	verilator --lint-only -Wall --top-module uart_rx -GOVERSAMPLE=8 -GDATA_BITS=5 $(RTL)
	@echo "lint clean"

diagrams: | $(BUILD)
	$(IVERILOG) -o $(BUILD)/tb_wave.vvp tb/tb_wave.v $(RTL)
	vvp -n $(BUILD)/tb_wave.vvp
	python3 scripts/wave_svg.py $(BUILD)/tb_wave.vcd docs/img
	scripts/netlist.sh

synth:
	scripts/synth.sh

clean:
	rm -rf $(BUILD)
