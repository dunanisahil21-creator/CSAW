// =====================================================================
//  spi_les.v  -- Clean RTL reconstruction of the Hackster iCE40
//  lightweight cryptographic accelerator ("LES"), recovered from
//  ice40_bitstream.bin (iceunpack + icebox_vlog) and the block diagrams.
//
//  32-bit block, 4-round substitution-permutation cipher over SPI.
//    ENC_DEC=0 (encrypt): x_{i+1} = ROTL8( S  ( x_i ^ K ) )
//    ENC_DEC=1 (decrypt): y_{i+1} = ROTR8-inv path: S^-1( ROTR8(y_i) ) ^ K
//  Embedded key K recovered by known-plaintext analysis: 0x8E043CB1
//  Verified: encrypt(0x59C359C3)=0x9CD84392, decrypt(0x9CD84392)=0x59C359C3
//
//  Interface per ice40_cryptographic_IP.md. Unified SCK clock domain.
// =====================================================================
module spi_les #(parameter [31:0] KEY = 32'h8E043CB1) (
    input  wire SCK,        // unified system + SPI clock
    input  wire RST_N,      // synchronous active-low reset
    input  wire MOSI,       // serial data in
    input  wire NORM_CS_N,  // active-low chip select / shift enable
    input  wire START,      // start encryption/decryption
    input  wire ENC_DEC,    // 0 = encrypt, 1 = decrypt
    output wire MISO,       // serial data out
    output wire BUSY,       // high while processing
    output wire ICE_LED     // mirrors BUSY
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
    reg [31:0] sr;       // SPI shift register (32-bit, MSB first)
    reg [31:0] text;     // crypto core text register
    reg [1:0]  state;
    reg        busy_d;

    wire busy = (state != IDLE) | (START & (state == IDLE));
    wire load = busy_d & ~busy;          // falling-edge of busy -> parallel load

    assign BUSY    = busy;
    assign ICE_LED = busy;
    assign MISO    = sr[31];

    always @(posedge SCK) begin
        if (!RST_N) begin
            sr <= 32'd0; text <= 32'd0; state <= IDLE; busy_d <= 1'b0;
        end else begin
            busy_d <= busy;
            case (state)
                IDLE: if (START) begin text <= rnd(sr,   ENC_DEC); state <= R1; end
                R1:            begin text <= rnd(text, ENC_DEC); state <= R2; end
                R2:            begin text <= rnd(text, ENC_DEC); state <= R3; end
                R3:            begin text <= rnd(text, ENC_DEC); state <= IDLE; end
            endcase
            // shift register priority: clear (reset above) > load > shift
            if (load)              sr <= text;
            else if (!NORM_CS_N)   sr <= {sr[30:0], MOSI};
        end
    end
endmodule
