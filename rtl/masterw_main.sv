//------------------------------------------------------------------------------
// The main board: the 68000, its address decode, main RAM and the palette.
//
//   000000-07FFFF  program ROM, 512 KB     through the cache below
//   200000-203FFF  main RAM, 16 KB
//   400000-47FFFF  TC0180VCU
//   600000-601FFF  palette RAM, 4096 words
//   800000-800003  TC0040IOC, upper byte
//   A00000-A00003  PC060HA, upper byte
//
// Interrupts.  The chip asserts INTH at the top of vblank and INTL eight
// lines later; MAME wires both with HOLD_LINE, and a devcb built that way
// calls set_input_line only on a *non-zero* write (src/emu/devcb.h:1566), so
// the chip's own CLEAR calls do nothing and each interrupt stays pending
// until the 68000 acknowledges it.  That is what the two pending flags here
// reproduce: set on the chip's rising edge, cleared when the CPU
// acknowledges that level.
//------------------------------------------------------------------------------
`default_nettype none

module masterw_main (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_phi1,
    input  logic        cen_phi2,

    // program ROM, 512 KB in SDRAM
    output logic        rom_req,
    output logic [18:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // TC0180VCU
    output logic        vcu_cs,
    output logic [18:1] vcu_addr,
    output logic [15:0] vcu_din,
    output logic        vcu_we,
    output logic  [1:0] vcu_ben,
    input  logic [15:0] vcu_dout,
    input  logic        vcu_ack,
    input  logic        inth,
    input  logic        intl,

    // TC0040IOC
    output logic        ioc_sel_wr,
    output logic        ioc_data_wr,
    output logic        ioc_wdog_rd,
    output logic  [7:0] ioc_din,
    input  logic  [7:0] ioc_dout,

    // PC060HA, master side
    output logic        ciu_port_wr,
    output logic        ciu_comm_wr,
    output logic        ciu_comm_rd,
    output logic  [7:0] ciu_din,
    input  logic  [7:0] ciu_dout,

    // palette lookup for the video output
    input  logic [11:0] pal_index,
    output logic [23:0] pal_rgb,

    output logic        dbg_halted,
    output logic [23:1] dbg_addr
);
    // ---------------------------------------------------------------- CPU
    logic [23:1] cpu_addr;
    logic [15:0] cpu_dout, cpu_din;
    logic        as_n, uds_n, lds_n, rw_n, dtack_n, vpa_n;
    logic        fc0, fc1, fc2;
    logic        cpu_haltedn;
    logic        e_nc, vman_nc, bgn_nc, resetn_nc;
    wire _unused = &{1'b0, e_nc, vman_nc, bgn_nc, resetn_nc, 1'b0};

    logic [2:0] ipl_n;

    fx68k cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
        .E(e_nc), .VMAn(vman_nc),
        .FC0(fc0), .FC1(fc1), .FC2(fc2),
        .BGn(bgn_nc), .oRESETn(resetn_nc), .oHALTEDn(cpu_haltedn),
        .DTACKn(dtack_n), .VPAn(vpa_n), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
        .iEdb(cpu_din), .oEdb(cpu_dout), .eab(cpu_addr)
    );
    assign dbg_halted = ~cpu_haltedn;
    assign dbg_addr   = cpu_addr;

    // ----------------------------------------------------------- interrupts
    logic inth_d, intl_d, irq5, irq4;
    wire  iack = fc0 & fc1 & fc2 & ~as_n;
    wire  [2:0] iack_level = cpu_addr[3:1];
    wire  [2:0] ipl = irq5 ? 3'd5 : irq4 ? 3'd4 : 3'd0;
    assign ipl_n = ~ipl;
    assign vpa_n = ~iack;               // autovectored

    always_ff @(posedge clk) begin
        if (rst) begin
            irq5 <= 1'b0; irq4 <= 1'b0;
            inth_d <= 1'b0; intl_d <= 1'b0;
        end else begin
            inth_d <= inth;
            intl_d <= intl;
            if (inth && !inth_d) irq5 <= 1'b1;
            if (intl && !intl_d) irq4 <= 1'b1;
            if (iack && iack_level == 3'd5) irq5 <= 1'b0;
            if (iack && iack_level == 3'd4) irq4 <= 1'b0;
        end
    end

    // --------------------------------------------------------------- decode
    wire bus    = ~as_n & (~uds_n | ~lds_n) & ~iack;
    wire wr     = ~rw_n;
    wire [1:0] ben = {~uds_n, ~lds_n};

    wire sel_rom = bus & (cpu_addr[23:19] == 5'b00000);
    wire sel_ram = bus & (cpu_addr[23:14] == 10'b00_1000_0000);   // 200000-203FFF
    wire sel_vcu = bus & (cpu_addr[23:19] == 5'b01000);           // 400000-47FFFF
    wire sel_pal = bus & (cpu_addr[23:13] == 11'b011_0000_0000);  // 600000-601FFF
    wire sel_ioc = bus & (cpu_addr[23:2]  == 22'h200000);         // 800000-800003
    wire sel_ciu = bus & (cpu_addr[23:2]  == 22'h280000);         // A00000-A00003
    wire sel_oth = bus & ~(sel_rom | sel_ram | sel_vcu | sel_pal | sel_ioc | sel_ciu);

    // one-clock strobes at the start of an access
    logic started, done;
    logic [15:0] din_r;
    wire  first = bus & ~started;

    // ------------------------------------------------------------ main RAM
    (* ramstyle = "M10K" *) logic [1:0][7:0] ram [0:8191];
    logic [15:0] ram_q;
    always_ff @(posedge clk) begin
        if (sel_ram && wr && first) begin
            if (ben[1]) ram[cpu_addr[13:1]][1] <= cpu_dout[15:8];
            if (ben[0]) ram[cpu_addr[13:1]][0] <= cpu_dout[7:0];
        end
        ram_q <= ram[cpu_addr[13:1]];
    end

    // ---------------------------------------------------------- palette RAM
    // RGBx_444: red 15-12, green 11-8, blue 7-4, and each nibble expands by
    // multiplying by 0x11
    (* ramstyle = "M10K" *) logic [1:0][7:0] pal [0:4095];
    logic [15:0] pal_cpu_q, pal_vid_q;
    always_ff @(posedge clk) begin
        if (sel_pal && wr && first) begin
            if (ben[1]) pal[cpu_addr[12:1]][1] <= cpu_dout[15:8];
            if (ben[0]) pal[cpu_addr[12:1]][0] <= cpu_dout[7:0];
        end
        pal_cpu_q <= pal[cpu_addr[12:1]];
        pal_vid_q <= pal[pal_index];
    end
    assign pal_rgb = {{2{pal_vid_q[15:12]}}, {2{pal_vid_q[11:8]}}, {2{pal_vid_q[7:4]}}};

    // -------------------------------------------------- program ROM cache
    // Direct mapped, 2048 words.  The ROM never changes, so an entry can
    // never go stale and there is nothing to invalidate.
    localparam int CLINES = 2048;
    (* ramstyle = "M10K" *) logic [15:0] crom_data [0:CLINES-1];
    (* ramstyle = "M10K" *) logic  [7:0] crom_tag  [0:CLINES-1];
    logic crom_valid [0:CLINES-1];

    wire [10:0] cidx = cpu_addr[11:1];
    wire  [7:0] ctag = cpu_addr[19:12];
    logic [15:0] cdata_q;
    logic  [7:0] ctag_q;
    logic        cvalid_q;
    always_ff @(posedge clk) begin
        cdata_q  <= crom_data[cidx];
        ctag_q   <= crom_tag[cidx];
        cvalid_q <= crom_valid[cidx];
    end
    wire cache_hit = cvalid_q && (ctag_q == ctag);

    typedef enum logic [1:0] { R_IDLE, R_LOOK, R_FETCH, R_DONE } rstate_t;
    rstate_t rstate;
    logic [15:0] rom_data;
    logic        rom_done;

    always_ff @(posedge clk) begin
        if (rst) begin
            rstate   <= R_IDLE;
            rom_req  <= 1'b0;
            rom_done <= 1'b0;
            for (int i = 0; i < CLINES; i++) crom_valid[i] <= 1'b0;
        end else begin
            rom_done <= 1'b0;
            case (rstate)
                R_IDLE: if (sel_rom && !done) rstate <= R_LOOK;
                R_LOOK: begin
                    if (cache_hit) begin
                        rom_data <= cdata_q;
                        rom_done <= 1'b1;
                        rstate   <= R_DONE;
                    end else begin
                        rom_addr <= cpu_addr[18:1];
                        rom_req  <= 1'b1;
                        rstate   <= R_FETCH;
                    end
                end
                R_FETCH: if (rom_ack) begin
                    rom_req  <= 1'b0;
                    rom_data <= rom_q;
                    rom_done <= 1'b1;
                    crom_data[cidx]  <= rom_q;
                    crom_tag[cidx]   <= ctag;
                    crom_valid[cidx] <= 1'b1;
                    rstate   <= R_DONE;
                end
                R_DONE: if (!bus) rstate <= R_IDLE;
                default: rstate <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------- the VCU port
    assign vcu_cs   = sel_vcu;
    assign vcu_addr = cpu_addr[18:1];
    assign vcu_din  = cpu_dout;
    assign vcu_we   = wr;
    assign vcu_ben  = ben;

    // ------------------------------------------- byte-wide chips, upper byte
    assign ioc_din     = cpu_dout[15:8];
    assign ioc_data_wr = sel_ioc && first && wr && !cpu_addr[1];
    assign ioc_sel_wr  = sel_ioc && first && wr &&  cpu_addr[1];
    assign ioc_wdog_rd = sel_ioc && first && !wr &&  cpu_addr[1];

    // A read of the CIU advances its mode, so the byte is captured on the
    // first clock of the bus cycle -- before the strobe moves the mode on --
    // and that capture is what the CPU is given.
    assign ciu_din     = cpu_dout[15:8];
    assign ciu_port_wr = sel_ciu && first && wr && !cpu_addr[1];
    assign ciu_comm_wr = sel_ciu && first && wr &&  cpu_addr[1];
    assign ciu_comm_rd = sel_ciu && first && !wr && cpu_addr[1];
    logic [7:0] ciu_q;
    always_ff @(posedge clk) if (sel_ciu && first) ciu_q <= ciu_dout;

    // ---------------------------------------------- bus cycle bookkeeping
    always_ff @(posedge clk) begin
        if (rst) begin
            started <= 1'b0;
            done    <= 1'b0;
            din_r   <= 16'd0;
        end else if (!bus) begin
            started <= 1'b0;
            done    <= 1'b0;
        end else begin
            started <= 1'b1;
            if (sel_rom && rom_done)       begin done <= 1'b1; din_r <= rom_data; end
            if (sel_vcu && vcu_ack)        begin done <= 1'b1; din_r <= vcu_dout; end
            if (sel_ram && started)        begin done <= 1'b1; din_r <= ram_q; end
            if (sel_pal && started)        begin done <= 1'b1; din_r <= pal_cpu_q; end
            if (sel_ioc && started)        begin done <= 1'b1;
                din_r <= cpu_addr[1] ? 16'h0000 : {ioc_dout, 8'h00}; end
            if (sel_ciu && started)        begin done <= 1'b1; din_r <= {ciu_q, 8'h00}; end
            if (sel_oth && started)        begin done <= 1'b1; din_r <= 16'h0000; end
        end
    end

    assign dtack_n = ~done;
    assign cpu_din = din_r;
endmodule

`default_nettype wire
