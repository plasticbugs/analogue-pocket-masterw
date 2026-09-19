// Whole-machine bench with the Pocket's real memory glue: masterw_core
// against masterw_mem, sdram_ctrl and sram_port, with behavioural chips on the
// far side of the pins.  sim/tb_system_top.sv models the memories as ideal
// ports, which is why it could pass while the first hardware run crashed: the
// arbitration in masterw_mem had never run anywhere but on a Pocket.
//
// Same ports as tb_system_top, and the same module name, so tb_system.cpp
// drives either; the latency inputs mean nothing here and are ignored.  The
// image goes in through masterw_mem's own download port, as the Pocket sends
// it, so that path is under test too -- the driver must leave it time between
// bytes (tb_system.cpp -dlgap).
`default_nettype none

module tb_system_top (
    input  logic        clk,
    input  logic        reset,
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
    logic        mrom_req, mrom_ack;  logic [18:1] mrom_addr;  logic [15:0] mrom_q;
    logic        srom_req, srom_ack;  logic [15:0] srom_addr;  logic  [7:0] srom_q;
    logic        gfxl_req, gfxl_ack;  logic [17:0] gfxl_addr;  logic [31:0] gfxl_q;
    logic        gfxs_req, gfxs_ack;  logic [17:0] gfxs_addr;  logic [31:0] gfxs_q;
    logic        vram_req, vram_we, vram_ack;
    logic [14:0] vram_addr;  logic [15:0] vram_din, vram_q;  logic [1:0] vram_ben;
    logic        mem_ready;

    wire [15:0] dram_dq;  wire [12:0] dram_a;  wire [1:0] dram_ba;
    wire        dram_dqml, dram_dqmh, dram_clk, dram_cke, dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
    wire [16:0] sram_a;   wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    // `reset` from the driver plays the Pocket's part: high through power-up
    // and the download, low once the image is in.  The SDRAM must initialise
    // before the download, so it is released by its own short power-up count.
    // The driver raises `reset` first, so the count starts from there.
    logic [7:0] por;
    logic       seen_reset;
    always_ff @(posedge clk) begin
        if (reset && !seen_reset) begin seen_reset <= 1'b1; por <= '0; end
        else if (!(&por)) por <= por + 8'd1;
    end
    wire mem_init = !seen_reset || !(&por);

    masterw_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(mem_init), .ready(mem_ready),
        .rd_late(1'b1), .burst_slow(1'b0), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr({4'd0, dl_addr}), .dl_data(dl_data), .dl_active(reset),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .gfxl_req(gfxl_req), .gfxl_addr(gfxl_addr), .gfxl_ack(gfxl_ack), .gfxl_q(gfxl_q),
        .gfxs_req(gfxs_req), .gfxs_addr(gfxs_addr), .gfxs_ack(gfxs_ack), .gfxs_q(gfxs_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr),
        .vram_din(vram_din), .vram_ben(vram_ben), .vram_ack(vram_ack), .vram_q(vram_q),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba),
        .SDRAM_DQML(dram_dqml), .SDRAM_DQMH(dram_dqmh),
        .SDRAM_nCS(dram_cs_n), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba), .dqml(dram_dqml), .dqmh(dram_dqmh),
        .cs_n(dram_cs_n), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n), .cke(dram_cke)
    );
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    masterw_core u_core (
        .clk(clk), .rst(reset | ~mem_ready), .pause(1'b0), .pix_sync(1'b0),
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
        .dbg_halted(dbg_halted), .dbg_addr(f_addr), .dbg_bus(f_bus), .dbg_wait(),
        .watchdog_reset(watchdog_reset)
    );

    // the hardware's first-fault capture, run here to prove it stays quiet on
    // a healthy boot before it is trusted on a sick one
    logic [23:1] f_addr;  logic f_bus, f_hit, f_hit_d;
    logic  [7:0] f_vec, f_n;  logic [23:0] f_pc0, f_pc1, f_io;
    logic f_rst;
    always_ff @(posedge clk) f_rst <= reset | ~mem_ready;   // its own copy: the CPUs use theirs asynchronously
    dbg_fault u_fault (.clk(clk), .rst(f_rst), .addr(f_addr), .bus(f_bus),
                       .hit(f_hit), .vec(f_vec), .pc0(f_pc0), .pc1(f_pc1), .io(f_io), .faults(f_n));
    always_ff @(posedge clk) begin
        f_hit_d <= f_hit;
        if (f_hit && !f_hit_d)
            $display("FAULT CAPTURE: vector %02x, pc0 %06x, pc1 %06x, io %06x", f_vec, f_pc0, f_pc1, f_io);
    end

    // How often the renderer raises its VRAM request on the very clock a
    // 68000 access is acknowledged -- the race the ack routing in tc0180vcu
    // has to survive.  Not zero: that is the point of counting it.
    int stolen;
    always_ff @(posedge clk)
        if (f_rst) stolen <= 0;
        else if (u_core.u_vcu.vram_ack && u_core.u_vcu.ren_vram_req && !u_core.u_vcu.ren_req_d) begin
            stolen <= stolen + 1;
            if (stolen < 3) $display("VRAM ack race at vpos %0d (68000's ack, renderer's request rising)", vpos);
        end
    final $display("VRAM ack races seen: %0d", stolen);
endmodule

`default_nettype wire
