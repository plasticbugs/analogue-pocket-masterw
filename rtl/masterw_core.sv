//------------------------------------------------------------------------------
// The whole board: the 68000 side, the TC0180VCU, the sound board, and the
// two custom chips that sit between them.
//
// Everything that is a memory outside the chips is a port here -- the two
// program ROMs, the graphics, and the tilemap VRAM -- so the same core runs
// against the Pocket's SDRAM and SRAM (target/pocket/masterw_mem.sv) and
// against the bench's models, with nothing platform-specific inside.
//------------------------------------------------------------------------------
`default_nettype none

module masterw_core (
    input  logic        clk,
    input  logic        rst,
    input  logic        pix_sync,       // see clk_enables.sv

    // ---- memories ----
    output logic        mrom_req,       // 68000 program, 512 KB
    output logic [18:1] mrom_addr,
    input  logic        mrom_ack,
    input  logic [15:0] mrom_q,

    output logic        srom_req,       // Z80 program, 64 KB
    output logic [15:0] srom_addr,
    input  logic        srom_ack,
    input  logic  [7:0] srom_q,

    // graphics, 256K 32-bit words, on two ports: single words for the line
    // renderer, whole 32-word tiles for the sprite engine
    output logic        gfxl_req,
    output logic [17:0] gfxl_addr,
    input  logic        gfxl_ack,
    input  logic [31:0] gfxl_q,

    output logic        gfxs_req,
    output logic [17:0] gfxs_addr,
    input  logic        gfxs_ack,
    input  logic [31:0] gfxs_q,

    output logic        vram_req,       // tilemap VRAM, 32K words
    output logic        vram_we,
    output logic [14:0] vram_addr,
    output logic [15:0] vram_din,
    output logic  [1:0] vram_ben,
    input  logic        vram_ack,
    input  logic [15:0] vram_q,

    // ---- inputs, all active low as the board reads them ----
    input  logic  [7:0] dswa, dswb,
    input  logic  [7:0] in0, in1, in2,

    // ---- video ----
    output logic [23:0] rgb,
    output logic        hsync, vsync,
    output logic        hblank, vblank,
    output logic        pix_ce,
    output logic        de,

    // ---- audio ----
    output logic signed [15:0] snd,

    // ---- diagnostics ----
    output logic  [8:0] vpos,
    output logic [17:0] spr_cycles,
    output logic [15:0] ren_cycles,
    output logic        dbg_halted,
    output logic        watchdog_reset
);
    // --------------------------------------------------------- clock enables
    logic cen_phi1, cen_phi2, cen_z80, cen_ym;
    clk_enables u_cen (
        .clk(clk), .rst(rst), .pix_sync(pix_sync),
        .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .cen_z80(cen_z80), .cen_ym(cen_ym), .cen_pix(pix_ce)
    );

    // ----------------------------------------------------- main <-> chips
    logic        vcu_cs, vcu_we, vcu_ack;
    logic [18:1] vcu_addr;
    logic [15:0] vcu_din, vcu_dout;
    logic  [1:0] vcu_ben;
    logic        inth, intl;

    logic        ioc_sel_wr, ioc_data_wr, ioc_wdog_rd;
    logic  [7:0] ioc_din, ioc_dout;
    logic  [3:0] coin_ctrl;

    logic        m_port_wr, m_comm_wr, m_comm_rd;
    logic  [7:0] m_din, m_dout;
    logic        s_port_wr, s_comm_wr, s_comm_rd;
    logic  [7:0] s_din, s_dout;
    logic        ciu_nmi, ciu_reset;

    logic [11:0] pix_index;
    logic        pix_de;

    masterw_main u_main (
        .clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .rom_req(mrom_req), .rom_addr(mrom_addr), .rom_ack(mrom_ack), .rom_q(mrom_q),
        .vcu_cs(vcu_cs), .vcu_addr(vcu_addr), .vcu_din(vcu_din), .vcu_we(vcu_we),
        .vcu_ben(vcu_ben), .vcu_dout(vcu_dout), .vcu_ack(vcu_ack),
        .inth(inth), .intl(intl),
        .ioc_sel_wr(ioc_sel_wr), .ioc_data_wr(ioc_data_wr), .ioc_wdog_rd(ioc_wdog_rd),
        .ioc_din(ioc_din), .ioc_dout(ioc_dout),
        .ciu_port_wr(m_port_wr), .ciu_comm_wr(m_comm_wr), .ciu_comm_rd(m_comm_rd),
        .ciu_din(m_din), .ciu_dout(m_dout),
        .pal_index(pix_index), .pal_rgb(rgb),
        .dbg_halted(dbg_halted), .dbg_addr()
    );

    tc0180vcu u_vcu (
        .clk(clk), .rst(rst), .pix_ce(pix_ce),
        .cs(vcu_cs), .addr(vcu_addr), .din(vcu_din), .we(vcu_we), .ben(vcu_ben),
        .dout(vcu_dout), .ack(vcu_ack),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr),
        .vram_din(vram_din), .vram_ben(vram_ben),
        .vram_ack(vram_ack), .vram_q(vram_q),
        .gfxl_req(gfxl_req), .gfxl_addr(gfxl_addr), .gfxl_ack(gfxl_ack), .gfxl_q(gfxl_q),
        .gfxs_req(gfxs_req), .gfxs_addr(gfxs_addr), .gfxs_ack(gfxs_ack), .gfxs_q(gfxs_q),
        .pix_index(pix_index), .pix_de(pix_de),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .inth(inth), .intl(intl),
        .ld_we(1'b0), .ld_sel(3'd0), .ld_addr(17'd0), .ld_data(16'd0),
        .vpos(vpos), .spr_busy(), .spr_cycles(spr_cycles), .ren_cycles(ren_cycles)
    );

    // The palette read follows the index by one system clock, not by a dot,
    // so the data enable is the chip's own.  Both are sampled by clk_vid
    // about ten clocks into the dot, where each has long settled.
    assign de = pix_de;

    tc0040ioc u_ioc (
        .clk(clk), .rst(rst),
        .sel_wr(ioc_sel_wr), .data_wr(ioc_data_wr), .wdog_rd(ioc_wdog_rd),
        .din(ioc_din), .dout(ioc_dout),
        .dswa(dswa), .dswb(dswb), .in0(in0), .in1(in1), .in2(in2),
        .coin_ctrl(coin_ctrl), .watchdog_reset(watchdog_reset)
    );

    pc060ha u_ciu (
        .clk(clk), .rst(rst),
        .master_port_wr(m_port_wr), .master_comm_wr(m_comm_wr),
        .master_comm_rd(m_comm_rd), .master_din(m_din), .master_dout(m_dout),
        .slave_port_wr(s_port_wr), .slave_comm_wr(s_comm_wr),
        .slave_comm_rd(s_comm_rd), .slave_din(s_din), .slave_dout(s_dout),
        .nmi(ciu_nmi), .snd_reset(ciu_reset)
    );

    // ------------------------------------------------------------ sound
    logic signed [15:0] fm_snd;
    logic  [7:0] psg_a, psg_b, psg_c;

    masterw_sound u_sound (
        .clk(clk), .rst(rst), .cen_z80(cen_z80), .cen_ym(cen_ym),
        .ciu_nmi(ciu_nmi), .ciu_reset(ciu_reset),
        .ciu_port_wr(s_port_wr), .ciu_comm_wr(s_comm_wr), .ciu_comm_rd(s_comm_rd),
        .ciu_dout(s_din), .ciu_din(s_dout),
        .rom_req(srom_req), .rom_addr(srom_addr), .rom_ack(srom_ack), .rom_q(srom_q),
        .fm_snd(fm_snd), .psg_a(psg_a), .psg_b(psg_b), .psg_c(psg_c),
        .z80_m1()
    );

    // MAME mixes the three SSG channels at 0.25 each and the FM at 0.80
    // (ref/mame/taito_b.cpp, masterw machine config), and those weights are
    // what the numerators below are.
    //
    // The SSG channels leave jt49 as 8-bit *unipolar* levels -- 0 is silence,
    // as the chip's own DAC is -- so they are summed and scaled but never
    // centred.  Centring them put a fixed -6 dBFS step on the output whenever
    // the SSG was quiet, which is most of this game: the first measurement
    // against MAME showed the core five times too loud with almost all of it
    // DC.  The board removes the offset with a coupling capacitor and the
    // Pocket's audio path with its DC blocker, so the offset belongs there,
    // not here.
    //
    // Against MAME's own recording the FM lands within about 20% across the
    // bands the music occupies (sim/run_sound.sh).  The SSG's scale against
    // the FM is still unmeasured, because the passage that was compared plays
    // no SSG at all -- see docs/hardware.md section 8.
    localparam logic signed [8:0] FM_NUM  = 9'sd205;   // 0.801
    localparam logic signed [8:0] PSG_NUM = 9'sd64;    // 0.250
    wire  [9:0] psg_sum = {2'd0, psg_a} + {2'd0, psg_b} + {2'd0, psg_c};
    wire signed [16:0] psg_s = $signed({2'b00, psg_sum, 5'd0});
    wire signed [26:0] fm_w  = $signed({{11{fm_snd[15]}}, fm_snd}) * FM_NUM;
    wire signed [26:0] psg_w = $signed({{10{psg_s[16]}}, psg_s}) * PSG_NUM;
    wire signed [26:0] mixed = (fm_w + psg_w) >>> 8;

    always_ff @(posedge clk) begin
        if (rst) snd <= '0;
        else if (mixed >  27'sd32767) snd <=  16'sh7fff;
        else if (mixed < -27'sd32768) snd <= -16'sh8000;
        else snd <= mixed[15:0];
    end

    wire _unused = &{1'b0, coin_ctrl, 1'b0};
endmodule

`default_nettype wire
