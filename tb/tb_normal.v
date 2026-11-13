// tb_normal.v -- SPI-level functional testbench for the recovered LES core.
// Mirrors spi_ice40_crypto_ip_test.py: ingest 32b, START, wait BUSY, read 32b.
// Proves normal operation: encrypt(0x59C359C3)=0x9CD84392 and the inverse.
`timescale 1ns/1ps
module tb_normal;
    reg SCK=0, RST_N=1, MOSI=0, NORM_CS_N=1, START=0, ENC_DEC=0;
    wire MISO, BUSY, ICE_LED;

    spi_les dut(.SCK(SCK),.RST_N(RST_N),.MOSI(MOSI),.NORM_CS_N(NORM_CS_N),
                .START(START),.ENC_DEC(ENC_DEC),.MISO(MISO),.BUSY(BUSY),.ICE_LED(ICE_LED));

    task tick; begin #5 SCK=1; #5 SCK=0; end endtask

    task reset; begin
        RST_N=0; NORM_CS_N=1; START=0; tick; RST_N=1;
    end endtask

    task ingest(input [31:0] w); integer i; begin
        NORM_CS_N=0;
        for (i=31;i>=0;i=i-1) begin MOSI=w[i]; tick; end
        NORM_CS_N=1;
    end endtask

    task run_core(input mode); integer i; begin
        ENC_DEC=mode; START=1; tick; START=0;
        if (BUSY!==1'b1) $display("  [warn] core did not assert BUSY");
        for (i=0;i<7;i=i+1) tick;            // let 4 rounds finish + parallel load
        if (BUSY!==1'b0) $display("  [warn] core did not finish");
    end endtask

    task readout(output [31:0] r); integer i; begin
        r=0; NORM_CS_N=0;
        for (i=31;i>=0;i=i-1) begin r[i]=MISO; tick; end
        NORM_CS_N=1;
    end endtask

    reg [31:0] pt, ct, got;
    initial begin
        pt=32'h59C359C3; ct=32'h9CD84392;
        reset;

        // ---- SPI loopback sanity (write then read back) ----
        ingest(pt); readout(got);
        $display("SPI loopback : wrote %08h read %08h -> %s", pt, got, (got===pt)?"PASS":"FAIL");

        // ---- Encryption ----
        reset; ingest(pt); run_core(1'b0); readout(got);
        $display("ENCRYPT      : pt=%08h -> ct=%08h (expect %08h) -> %s", pt, got, ct, (got===ct)?"PASS":"FAIL");

        // ---- Decryption ----
        reset; ingest(ct); run_core(1'b1); readout(got);
        $display("DECRYPT      : ct=%08h -> pt=%08h (expect %08h) -> %s", ct, got, pt, (got===pt)?"PASS":"FAIL");

        $finish;
    end
endmodule
