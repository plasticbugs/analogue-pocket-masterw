// Frozen-state video bench: the whole TC0180VCU with the memories that sit
// outside it modelled here, so a dumped MAME frame can be loaded into the
// hardware and rendered.
//
// The C++ driver owns `pix_ce`, which is how it runs replay frames quickly
// (a tick every clock, stalled while the sprite engine is working, so vblank
// is exactly as long as the sprites need) and the frame under test at the
// real rate of one tick in fourteen, where the line renderer's budget is
// real and the bench can report whether it was met.
`default_nettype none

module tb_video_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        pix_ce,

    // ---- loads ----
    input  logic        ld_we,
    input  logic  [2:0] ld_sel,         // into the chip: see tc0180vcu.sv
    input  logic [16:0] ld_addr,
    input  logic [15:0] ld_data,

    input  logic        vram_we,
    input  logic [14:0] vram_waddr,
    input  logic [15:0] vram_wdata,

    input  logic        gfx_we,
    input  logic [17:0] gfx_waddr,
    input  logic [31:0] gfx_wdata,

    // memory latency, so the bench can ask what happens when the real
    // memories are slower than a clock
    input  logic  [3:0] vram_lat,
    input  logic  [3:0] gfx_lat,

    // ---- observation ----
    output logic [11:0] pix_index,
    output logic        pix_de,
    output logic  [8:0] vpos,
    output logic        vblank,
    output logic        spr_busy,
    output logic [17:0] spr_cycles,
    output logic [15:0] ren_cycles
);
    // ------------------------------------------------------- VRAM (Pocket SRAM)
    logic [15:0] vram [0:32767];
    logic        vram_req, vram_we_o, vram_ack;
    logic [14:0] vram_addr;
    logic [15:0] vram_din, vram_q;
    logic  [1:0] vram_ben;
    logic  [3:0] vram_cnt;

    always_ff @(posedge clk) begin
        if (vram_we) vram[vram_waddr] <= vram_wdata;
        vram_ack <= 1'b0;
        if (!vram_req) begin
            vram_cnt <= '0;
        end else if (!vram_ack) begin
            if (vram_cnt >= vram_lat) begin
                vram_cnt <= '0;
                vram_ack <= 1'b1;
                if (vram_we_o) begin
                    if (vram_ben[1]) vram[vram_addr][15:8] <= vram_din[15:8];
                    if (vram_ben[0]) vram[vram_addr][7:0]  <= vram_din[7:0];
                end
                vram_q <= vram[vram_addr];
            end else begin
                vram_cnt <= vram_cnt + 4'd1;
            end
        end
    end

    // ------------------------------------------------ graphics ROM (SDRAM)
    logic [31:0] gfx [0:262143];
    logic        gfx_req, gfx_ack;
    logic [17:0] gfx_addr;
    logic [31:0] gfx_q;
    logic  [3:0] gfx_cnt;

    always_ff @(posedge clk) begin
        if (gfx_we) gfx[gfx_waddr] <= gfx_wdata;
        gfx_ack <= 1'b0;
        if (!gfx_req) begin
            gfx_cnt <= '0;
        end else if (!gfx_ack) begin
            if (gfx_cnt >= gfx_lat) begin
                gfx_cnt <= '0;
                gfx_ack <= 1'b1;
                gfx_q   <= gfx[gfx_addr];
            end else begin
                gfx_cnt <= gfx_cnt + 4'd1;
            end
        end
    end

    // ------------------------------------------------------------------ DUT
    tc0180vcu u_vcu (
        .clk(clk), .rst(reset), .pix_ce(pix_ce),
        .cs(1'b0), .addr(18'd0), .din(16'd0), .we(1'b0), .ben(2'b00),
        .dout(), .ack(),
        .vram_req(vram_req), .vram_we(vram_we_o), .vram_addr(vram_addr),
        .vram_din(vram_din), .vram_ben(vram_ben),
        .vram_ack(vram_ack), .vram_q(vram_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .pix_index(pix_index), .pix_de(pix_de),
        .hsync(), .vsync(), .hblank(), .vblank(vblank),
        .inth(), .intl(),
        .ld_we(ld_we), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),
        .vpos(vpos), .spr_busy(spr_busy), .spr_cycles(spr_cycles),
        .ren_cycles(ren_cycles)
    );
endmodule

`default_nettype wire
