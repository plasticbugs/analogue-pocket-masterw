//------------------------------------------------------------------------------
// The Pocket's memories behind the core's ports (docs/core-design.md section 2).
//
//   SDRAM   68000 program   512 KB   word 0x000000   single words, cached
//           Z80 program      64 KB   word 0x040000   single words, cached
//           graphics          1 MB   word 0x080000   single words for the line
//                                                    renderer, 64-word bursts
//                                                    for the sprite engine
//   SRAM    tilemap VRAM     64 KB   word 0x00000    single words, byte enables
//
// The image arrives from the Pocket as a stream of bytes in the order
// masterw.mra builds it, and is written into SDRAM a word at a time through
// the same controller the core reads it back through.
//
// The graphics ports are 32 bits wide where the SDRAM is 16, so each 32-bit
// word is two SDRAM words: the line renderer's port reads them one after the
// other, and the sprite engine's burst of 32 is a 64-word SDRAM burst.
//------------------------------------------------------------------------------
`default_nettype none

module masterw_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase shifted, drives the pin
    input  logic        init,           // hold to (re)initialise the SDRAM
    output logic        ready,

    input  logic        rd_late,        // SDRAM diagnostics, from the Pocket menu
    input  logic        burst_slow,
    input  logic        sram_slow,
    input  logic        sram_slow_wr,

    // the ROM image arriving from the Pocket
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_active,

    // core ports
    input  logic        mrom_req,  input  logic [18:1] mrom_addr,
    output logic        mrom_ack,  output logic [15:0] mrom_q,

    input  logic        srom_req,  input  logic [15:0] srom_addr,
    output logic        srom_ack,  output logic  [7:0] srom_q,

    input  logic        gfxl_req,  input  logic [17:0] gfxl_addr,
    output logic        gfxl_ack,  output logic [31:0] gfxl_q,

    input  logic        gfxs_req,  input  logic [17:0] gfxs_addr,
    output logic        gfxs_ack,  output logic [31:0] gfxs_q,

    input  logic        vram_req,  input  logic        vram_we,
    input  logic [14:0] vram_addr, input  logic [15:0] vram_din,
    input  logic  [1:0] vram_ben,
    output logic        vram_ack,  output logic [15:0] vram_q,

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // SRAM pins
    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    // Where each region starts, as an SDRAM word address.  The bases are
    // powers of two and every region fits inside its own, so the offsets go
    // in with an OR and cost no adder.
    localparam logic [24:1] PROG_W = 24'h000000;
    localparam logic [24:1] SND_W  = 24'h040000;
    localparam logic [24:1] GFX_W  = 24'h080000;
    // and where each starts in the image, as a byte offset
    localparam logic [24:0] SND_B  = 25'h080000;
    localparam logic [24:0] GFX_B  = 25'h090000;

    // ------------------------------------------------------------ download
    // a byte at a time from the Pocket; a word is written when its odd byte
    // arrives
    logic [15:0] dl_word;
    logic        dl_pending;
    logic [24:1] dl_waddr;

    wire [24:1] dl_target = (dl_addr >= GFX_B) ? (GFX_W + 24'((dl_addr - GFX_B) >> 1))
                          : (dl_addr >= SND_B) ? (SND_W + 24'((dl_addr - SND_B) >> 1))
                                               : (PROG_W + 24'(dl_addr >> 1));

    always_ff @(posedge clk) begin
        if (init) begin
            dl_pending <= 1'b0;
        end else if (dl_we) begin
            if (!dl_addr[0]) begin
                dl_word[15:8] <= dl_data;       // the image is big-endian
            end else begin
                dl_word[7:0] <= dl_data;
                dl_waddr     <= dl_target;
                dl_pending   <= 1'b1;
            end
        end else if (dl_pending && dl_ack) begin
            dl_pending <= 1'b0;
        end
    end

    // ---------------------------------------------------- SDRAM clients
    // 0 download (writes), 1 graphics for the line renderer, 2 the 68000,
    // 3 the Z80.  Fixed priority, first listed first: the download only runs
    // while the core is held in reset, and the line renderer has the tightest
    // deadline of the three that run.
    localparam int NCLI = 4;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;

    wire dl_ack = c_ack[0];
    assign c_addr[0]  = dl_waddr;
    assign c_req[0]   = dl_pending;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = dl_word;
    assign c_be[0]    = 2'b11;

    // graphics for the line renderer: one 32-bit word is two SDRAM words
    logic        gl_phase;
    logic [15:0] gl_hi;
    assign c_addr[1]  = GFX_W | {5'd0, gfxl_addr, gl_phase};
    assign c_req[1]   = gfxl_req && !gfxl_ack;
    assign c_we[1]    = 1'b0;
    assign c_wdata[1] = 16'd0;
    assign c_be[1]    = 2'b11;

    always_ff @(posedge clk) begin
        gfxl_ack <= 1'b0;
        if (!gfxl_req) begin
            gl_phase <= 1'b0;
        end else if (c_ack[1]) begin
            if (!gl_phase) begin
                gl_hi    <= rdata;
                gl_phase <= 1'b1;
            end else begin
                gfxl_q   <= {gl_hi, rdata};
                gfxl_ack <= 1'b1;
                gl_phase <= 1'b0;
            end
        end
    end

    assign c_addr[2]  = PROG_W | {6'd0, mrom_addr};
    assign c_req[2]   = mrom_req && !mrom_ack;
    assign c_we[2]    = 1'b0;
    assign c_wdata[2] = 16'd0;
    assign c_be[2]    = 2'b11;
    always_ff @(posedge clk) begin
        mrom_ack <= c_ack[2];
        if (c_ack[2]) mrom_q <= rdata;
    end

    // the Z80 reads bytes; the SDRAM holds them two to a word, high byte first
    assign c_addr[3]  = SND_W | {9'd0, srom_addr[15:1]};
    assign c_req[3]   = srom_req && !srom_ack;
    assign c_we[3]    = 1'b0;
    assign c_wdata[3] = 16'd0;
    assign c_be[3]    = 2'b11;
    logic srom_lo;
    always_ff @(posedge clk) begin
        srom_ack <= c_ack[3];
        if (c_req[3]) srom_lo <= srom_addr[0];
        if (c_ack[3]) srom_q <= srom_lo ? rdata[7:0] : rdata[15:8];
    end

    // ------------------------------------------------- the sprite engine's burst
    // 32 image words is 64 SDRAM words, consecutive
    logic [15:0] gs_hi;
    logic        b_wr, b_done;
    logic  [9:0] b_idx;
    logic [15:0] b_data;

    always_ff @(posedge clk) begin
        gfxs_ack <= 1'b0;
        if (b_wr) begin
            if (!b_idx[0]) begin
                gs_hi <= b_data;
            end else begin
                gfxs_q   <= {gs_hi, b_data};
                gfxs_ack <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------- SDRAM
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(GFX_W | {5'd0, gfxs_addr, 1'b0}), .b_len(10'd64),
        .b_req(gfxs_req), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx()
    );

    // -------------------------------------------------------------- SRAM
    sram_port u_sram (
        .clk(clk), .reset(init), .slow(sram_slow), .slow_wr(sram_slow_wr),
        .req(vram_req && !dl_active), .we(vram_we), .addr({1'b0, vram_addr}),
        .be(vram_ben), .wdata(vram_din), .ack(vram_ack), .q(vram_q),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    wire _unused = &{1'b0, b_done, 1'b0};
endmodule

`default_nettype wire
