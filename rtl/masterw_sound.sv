//------------------------------------------------------------------------------
// The sound board: a 6 MHz Z80, a 3 MHz YM2203, and the PC060HA's slave side.
//
// Memory map (ref/mame/taito_b.cpp, masterw_sound_map):
//
//   0000-3FFF  ROM, the fixed first 16 KB
//   4000-7FFF  ROM, one of four 16 KB windows over the same 64 KB
//   8000-8FFF  RAM, 4 KB
//   9000-9001  YM2203
//   A000       PC060HA port select
//   A001       PC060HA data
//
// The bank is not a latch of its own: it is the **YM2203's port A**, bits
// 1-0, which is how the sound program switches banks.  The chip's IRQ, from
// its own timers, is the Z80's INT; the CIU's is its NMI, and the 68000 can
// hold it in reset through the CIU.
//
// Because the timers pace the music, the Z80's exact rate does not set the
// tempo -- but it still has to keep up, so its ROM comes through a small
// direct-mapped cache over the SDRAM (the ROM is read-only, so an entry can
// never go stale).
//------------------------------------------------------------------------------
`default_nettype none

module masterw_sound (
    input  logic        clk,
    input  logic        rst,            // the core's reset
    input  logic        cen_z80,        // 6 MHz
    input  logic        cen_ym,         // 3 MHz

    // PC060HA, the 68000 side of which lives in masterw_main
    input  logic        ciu_nmi,
    input  logic        ciu_reset,
    output logic        ciu_port_wr,
    output logic        ciu_comm_wr,
    output logic        ciu_comm_rd,
    output logic  [7:0] ciu_dout,
    input  logic  [7:0] ciu_din,

    // sound ROM, 64 KB
    output logic        rom_req,
    output logic [15:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,

    // the YM2203's three outputs, as MAME routes them: the SSG channels
    // quarter weight each, the FM at 0.80
    output logic signed [15:0] fm_snd,
    output logic  [7:0] psg_a, psg_b, psg_c,

    output logic        z80_m1          // for the diagnostic overlay
);
    // ------------------------------------------------------------------ Z80
    logic        reset_n;
    logic        mreq_n, iorq_n, rd_n, wr_n, m1_n;
    logic [15:0] a;
    logic  [7:0] di, z80_dout;
    logic        wait_n;

    assign reset_n = ~(rst | ciu_reset);
    assign z80_m1  = ~m1_n;

    tv80s_cen u_z80 (
        .reset_n(reset_n), .clk(clk), .cen(cen_z80),
        .wait_n(wait_n), .int_n(~ym_irq), .nmi_n(~ciu_nmi), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(), .halt_n(), .busak_n(),
        .A(a), .di(di), .dout(z80_dout)
    );

    // ------------------------------------------------------------ decoding
    wire mem   = ~mreq_n;
    wire rom_s = mem && (a[15:14] == 2'b00 || a[15:14] == 2'b01);
    wire ram_s = mem && (a[15:12] == 4'h8);
    wire ym_s  = mem && (a[15:12] == 4'h9);
    wire ciu_s = mem && (a[15:12] == 4'hA);

    wire rd = mem && ~rd_n;
    wire wr = mem && ~wr_n;

    // ---------------------------------------------------------------- RAM
    (* ramstyle = "M10K" *) logic [7:0] ram [0:4095];
    logic [7:0] ram_q;
    always_ff @(posedge clk) begin
        if (ram_s && wr && cen_z80) ram[a[11:0]] <= z80_dout;
        ram_q <= ram[a[11:0]];
    end

    // ------------------------------------------------------- ROM and bank
    // port A of the YM2203 is the bank register
    logic [7:0] ym_porta;
    wire  [1:0] bank = ym_porta[1:0];
    wire [15:0] rom_a = a[14] ? {bank, a[13:0]} : {2'b00, a[13:0]};

    // a 512-byte direct-mapped cache, enough to hold an interrupt handler and
    // its inner loop; the ROM never changes so a hit can never be stale
    localparam int CLINES = 512;
    (* ramstyle = "M10K" *) logic [7:0] crom_data [0:CLINES-1];
    logic  [6:0] crom_tag [0:CLINES-1];
    logic        crom_valid [0:CLINES-1];
    wire   [8:0] cidx = rom_a[8:0];
    wire   [6:0] ctag = rom_a[15:9];

    logic [7:0] cdata_q;
    logic [6:0] ctag_q;
    logic       cvalid_q;
    always_ff @(posedge clk) begin
        cdata_q  <= crom_data[cidx];
        ctag_q   <= crom_tag[cidx];
        cvalid_q <= crom_valid[cidx];
    end
    wire cache_hit = cvalid_q && (ctag_q == ctag);

    // R_DONE holds the answer until the Z80 drops its read.  Without it the
    // state machine re-enters the lookup while the read is still asserted,
    // re-asserts WAIT, and the Z80 never sees it released.
    typedef enum logic [1:0] { R_IDLE, R_LOOK, R_FETCH, R_DONE } rstate_t;
    rstate_t rstate;
    logic [7:0] rom_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            rstate  <= R_IDLE;
            rom_req <= 1'b0;
            for (int i = 0; i < CLINES; i++) crom_valid[i] <= 1'b0;
        end else case (rstate)
            R_IDLE: if (rom_s && rd) rstate <= R_LOOK;
            R_LOOK: begin
                if (cache_hit) begin
                    rom_data <= cdata_q;
                    rstate   <= R_DONE;
                end else begin
                    rom_addr <= rom_a;
                    rom_req  <= 1'b1;
                    rstate   <= R_FETCH;
                end
            end
            R_FETCH: if (rom_ack) begin
                rom_req  <= 1'b0;
                rom_data <= rom_q;
                crom_data[cidx]  <= rom_q;
                crom_tag[cidx]   <= ctag;
                crom_valid[cidx] <= 1'b1;
                rstate   <= R_DONE;
            end
            R_DONE: if (!(rom_s && rd)) rstate <= R_IDLE;
            default: rstate <= R_IDLE;
        endcase
    end

    // the Z80 waits from the moment it asks until the answer is in hand
    assign wait_n = ~(rom_s && rd && rstate != R_DONE);

    // -------------------------------------------------------------- YM2203
    logic        ym_cs_n, ym_wr_n;
    logic  [7:0] ym_dout;
    logic        ym_irq_n;
    wire         ym_irq = ~ym_irq_n;
    logic  [7:0] ioa_out;
    logic  [9:0] psg_snd;
    logic signed [15:0] ym_snd;

    // the chip is written with the Z80's strobes, one chip clock wide
    assign ym_cs_n = ~(ym_s && (rd || wr));
    assign ym_wr_n = ~(ym_s && wr);

    jt03 u_ym (
        .rst(rst), .clk(clk), .cen(cen_ym),
        .din(z80_dout), .addr(a[0]), .cs_n(ym_cs_n), .wr_n(ym_wr_n),
        .dout(ym_dout), .irq_n(ym_irq_n),
        .IOA_in(8'd0), .IOB_in(8'd0),
        .IOA_out(ioa_out), .IOB_out(), .IOA_oe(), .IOB_oe(),
        .psg_A(psg_a), .psg_B(psg_b), .psg_C(psg_c),
        .fm_snd(fm_snd), .psg_snd(psg_snd), .snd(ym_snd), .snd_sample(),
        .debug_view()
    );

    always_ff @(posedge clk) begin
        if (rst) ym_porta <= 8'd0;
        else     ym_porta <= ioa_out;
    end

    // ---------------------------------------------------------------- CIU
    // A read of the CIU advances its mode, so the strobe has to come at the
    // *end* of the access: if it came at the start, the mode would move on
    // and the chip would be presenting the next nibble by the time the Z80
    // latched the bus.  The value is captured on the way in so the Z80 sees
    // one stable byte for the whole cycle either way.
    logic rd_d, wr_d;
    logic [7:0] ciu_q;
    logic       ciu_rd_pend, ciu_rd_a0;
    always_ff @(posedge clk) begin
        rd_d <= rd;
        wr_d <= wr;
        if (ciu_s && rd && !rd_d) begin
            ciu_q       <= ciu_din;
            ciu_rd_a0   <= a[0];
            ciu_rd_pend <= 1'b1;
        end else if (ciu_rd_pend && !rd) begin
            ciu_rd_pend <= 1'b0;
        end
        if (rst) ciu_rd_pend <= 1'b0;
    end
    wire wr_edge = wr & ~wr_d;

    assign ciu_port_wr = ciu_s && !a[0] && wr_edge;
    assign ciu_comm_wr = ciu_s &&  a[0] && wr_edge;
    // the mreq strobe drops with rd, so the end of the access is found from
    // the latched state rather than from the decode
    assign ciu_comm_rd = ciu_rd_pend && !rd && ciu_rd_a0;
    assign ciu_dout    = z80_dout;

    // ------------------------------------------------------------ read mux
    always_comb begin
        if      (rom_s) di = rom_data;
        else if (ram_s) di = ram_q;
        else if (ym_s)  di = ym_dout;
        else if (ciu_s) di = ciu_rd_pend ? ciu_q : ciu_din;
        else            di = 8'hff;
    end
endmodule

`default_nettype wire
