// Whole-machine bench: masterw_core with models of the memories that sit
// outside it, so both CPUs run the real program against the real graphics.
//
// The models answer after a settable number of clocks, so the bench can ask
// what happens when the Pocket's memories are slower than an ideal one.
`default_nettype none

module tb_system_top (
    input  logic        clk,
    input  logic        reset,

    // ROM image load, byte at a time, in the order masterw.mra builds it
    input  logic        dl_we,
    input  logic [20:0] dl_addr,
    input  logic  [7:0] dl_data,

    input  logic  [3:0] lat_rom,
    input  logic  [3:0] lat_gfx,
    input  logic  [3:0] lat_vram,

    input  logic  [7:0] dswa, dswb,
    input  logic  [7:0] in0, in1, in2,

    output logic [23:0] rgb,
    output logic        de,
    output logic        pix_ce,
    output logic        vblank,
    output logic  [8:0] vpos,
    output logic signed [15:0] snd,
    output logic        dbg_halted,
    output logic        watchdog_reset,
    output logic [17:0] spr_cycles,
    output logic [15:0] ren_cycles
);
    localparam int PROG_BASE = 'h000000;    // 512 KB, 16-bit words
    localparam int SND_BASE  = 'h080000;    // 64 KB, bytes
    localparam int GFX_BASE  = 'h090000;    // 1 MB, 32-bit words

    // ---------------------------------------------------------- the image
    logic [15:0] prog [0:262143];           // 68000 program, big-endian words
    logic  [7:0] sndrom [0:65535];
    logic [31:0] gfx [0:262143];

    wire [17:0] gfx_wi = 18'((dl_addr - 21'(GFX_BASE)) >> 2);

    always_ff @(posedge clk) begin
        if (dl_we) begin
            if (dl_addr < 21'(SND_BASE)) begin
                if (dl_addr[0]) prog[dl_addr[18:1]][7:0]  <= dl_data;
                else            prog[dl_addr[18:1]][15:8] <= dl_data;
            end else if (dl_addr < 21'(GFX_BASE)) begin
                sndrom[dl_addr[15:0]] <= dl_data;
            end else begin
                case (dl_addr[1:0])
                    2'd0: gfx[gfx_wi][31:24] <= dl_data;
                    2'd1: gfx[gfx_wi][23:16] <= dl_data;
                    2'd2: gfx[gfx_wi][15:8]  <= dl_data;
                    default: gfx[gfx_wi][7:0] <= dl_data;
                endcase
            end
        end
    end

    // ------------------------------------------------------------- ports
    logic        mrom_req, mrom_ack;
    logic [18:1] mrom_addr;
    logic [15:0] mrom_q;
    logic  [3:0] mrom_cnt;

    always_ff @(posedge clk) begin
        mrom_ack <= 1'b0;
        if (!mrom_req) mrom_cnt <= '0;
        else if (!mrom_ack) begin
            if (mrom_cnt >= lat_rom) begin
                mrom_cnt <= '0; mrom_ack <= 1'b1; mrom_q <= prog[mrom_addr];
            end else mrom_cnt <= mrom_cnt + 4'd1;
        end
    end

    logic        srom_req, srom_ack;
    logic [15:0] srom_addr;
    logic  [7:0] srom_q;
    logic  [3:0] srom_cnt;

    always_ff @(posedge clk) begin
        srom_ack <= 1'b0;
        if (!srom_req) srom_cnt <= '0;
        else if (!srom_ack) begin
            if (srom_cnt >= lat_rom) begin
                srom_cnt <= '0; srom_ack <= 1'b1; srom_q <= sndrom[srom_addr];
            end else srom_cnt <= srom_cnt + 4'd1;
        end
    end

    logic        gfxl_req, gfxl_ack;
    logic [17:0] gfxl_addr;
    logic [31:0] gfxl_q;
    logic  [3:0] gfxl_cnt;

    always_ff @(posedge clk) begin
        gfxl_ack <= 1'b0;
        if (!gfxl_req) gfxl_cnt <= '0;
        else if (!gfxl_ack) begin
            if (gfxl_cnt >= lat_gfx) begin
                gfxl_cnt <= '0; gfxl_ack <= 1'b1; gfxl_q <= gfx[gfxl_addr];
            end else gfxl_cnt <= gfxl_cnt + 4'd1;
        end
    end

    // the sprite engine's burst: 32 consecutive words after one latency
    logic        gfxs_req, gfxs_ack;
    logic [17:0] gfxs_addr;
    logic [31:0] gfxs_q;
    logic  [3:0] gfxs_cnt;
    logic  [5:0] gfxs_i;
    logic        gfxs_run;

    always_ff @(posedge clk) begin
        gfxs_ack <= 1'b0;
        if (!gfxs_req) begin
            gfxs_cnt <= '0; gfxs_i <= 6'd0; gfxs_run <= 1'b0;
        end else if (!gfxs_run) begin
            if (gfxs_cnt >= lat_gfx) begin
                gfxs_run <= 1'b1; gfxs_ack <= 1'b1;
                gfxs_q <= gfx[gfxs_addr]; gfxs_i <= 6'd1;
            end else gfxs_cnt <= gfxs_cnt + 4'd1;
        end else if (gfxs_i < 6'd32) begin
            gfxs_ack <= 1'b1;
            gfxs_q   <= gfx[gfxs_addr + {12'd0, gfxs_i}];
            gfxs_i   <= gfxs_i + 6'd1;
        end
    end

    // tilemap VRAM, the Pocket's SRAM
    logic [15:0] vram [0:32767];
    logic        vram_req, vram_we, vram_ack;
    logic [14:0] vram_addr;
    logic [15:0] vram_din, vram_q;
    logic  [1:0] vram_ben;
    logic  [3:0] vram_cnt;

    always_ff @(posedge clk) begin
        vram_ack <= 1'b0;
        if (!vram_req) vram_cnt <= '0;
        else if (!vram_ack) begin
            if (vram_cnt >= lat_vram) begin
                vram_cnt <= '0;
                vram_ack <= 1'b1;
                if (vram_we) begin
                    if (vram_ben[1]) vram[vram_addr][15:8] <= vram_din[15:8];
                    if (vram_ben[0]) vram[vram_addr][7:0]  <= vram_din[7:0];
                end
                vram_q <= vram[vram_addr];
            end else vram_cnt <= vram_cnt + 4'd1;
        end
    end

    // --------------------------------------------------------------- DUT
    masterw_core u_core (
        .clk(clk), .rst(reset), .pix_sync(1'b0),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .gfxl_req(gfxl_req), .gfxl_addr(gfxl_addr), .gfxl_ack(gfxl_ack), .gfxl_q(gfxl_q),
        .gfxs_req(gfxs_req), .gfxs_addr(gfxs_addr), .gfxs_ack(gfxs_ack), .gfxs_q(gfxs_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr),
        .vram_din(vram_din), .vram_ben(vram_ben), .vram_ack(vram_ack), .vram_q(vram_q),
        .dswa(dswa), .dswb(dswb), .in0(in0), .in1(in1), .in2(in2),
        .rgb(rgb), .hsync(), .vsync(), .hblank(), .vblank(vblank),
        .pix_ce(pix_ce), .de(de),
        .snd(snd),
        .vpos(vpos), .spr_cycles(spr_cycles), .ren_cycles(ren_cycles),
        .dbg_halted(dbg_halted), .watchdog_reset(watchdog_reset)
    );
endmodule

`default_nettype wire
