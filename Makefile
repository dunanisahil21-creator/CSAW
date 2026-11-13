# One-command pipeline: recover -> simulate (normal + exploit) -> report.
IV=iverilog
VVP=vvp
.PHONY: all normal exploit recover keyrecover clean
all: normal exploit
normal:
	@$(IV) -o build_normal tb/tb_normal.v rtl/spi_les.v && $(VVP) build_normal
exploit:
	@$(IV) -o build_exploit tb/tb_exploit.v rtl/spi_les_trojan.v && $(VVP) build_exploit
recover:
	@iceunpack recovery/ice40_bitstream.bin recovery/design.asc && \
	 icebox_vlog recovery/design.asc > recovery/recovered_netlist.v 2>/dev/null && \
	 echo "recovered -> recovery/recovered_netlist.v"
keyrecover:
	@gcc -O3 -o build_keyrec tools/keyrecover.c && echo "running 2^32 known-plaintext search..." && ./build_keyrec
clean:
	@rm -f build_normal build_exploit build_keyrec *.vcd recovery/design.asc
