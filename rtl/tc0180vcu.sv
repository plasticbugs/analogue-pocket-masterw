//------------------------------------------------------------------------------
// Taito TC0180VCU: tilemaps, sprites, video timing and the two interrupts.
//
// The chip does two jobs at two different times and this keeps them apart:
//
//   * at the top of vblank it clears the framebuffer page it is leaving,
//     flips, and paints every sprite into the page the next frame will show
//     (vcu_sprite.sv);
//   * during each visible line it fills a line buffer with the next line's
//     palette indices (vcu_line.sv), which is read out a pixel at a time
//     while the line after is being built.
//
// The 64 KB of tilemap VRAM lives outside the chip -- on the board in eight
// SRAMs, in this core in the Pocket's SRAM -- so it is reached through a port
// the 68000 and the line renderer share.  Sprite RAM, scroll RAM and the
// framebuffer are inside.
//
// Behaviour is from docs/hardware.md section 4 and is checked against
// tools/vcu_model.py, which is pixel-identical to MAME.
//------------------------------------------------------------------------------
`default_nettype none

module tc0180vcu #(
    parameter int HTOTAL  = 452,
    parameter int VTOTAL  = 253,
    parameter int VIS_X0  = 0,
    parameter int VIS_X1  = 319,
    parameter int VIS_Y0  = 16,
    parameter int VIS_Y1  = 239,
    parameter logic [7:0] TX_BASE = 8'h00,
    parameter logic [7:0] FB_BASE = 8'h10,
    parameter logic [7:0] FG_BASE = 8'h20,
    parameter logic [7:0] BG_BASE = 8'h30
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        pix_ce,         // one pulse per dot clock

    // 68000 side: the chip's own 0x00000-0x7FFFF window, word addressed
    input  logic        cs,
    input  logic [18:1] addr,
    input  logic [15:0] din,
    input  logic        we,
    input  logic  [1:0] ben,            // byte enables, {upper, lower}
    output logic [15:0] dout,
    output logic        ack,

    // VRAM, outside the chip
    output logic        vram_req,
    output logic        vram_we,
    output logic [14:0] vram_addr,
    output logic [15:0] vram_din,
    output logic  [1:0] vram_ben,
    input  logic        vram_ack,
    input  logic [15:0] vram_q,

    // Graphics ROM, on two ports.  The line renderer asks for one word at a
    // time (the two halves of a 16x16 tile row are eight words apart, so they
    // are two requests); the sprite engine asks for a whole tile, 32
    // consecutive words delivered in order.  They are separate ports rather
    // than one arbitrated port because they want different things from the
    // SDRAM and they overlap on only one line of the frame.
    output logic        gfxl_req,
    output logic [17:0] gfxl_addr,
    input  logic        gfxl_ack,
    input  logic [31:0] gfxl_q,

    output logic        gfxs_req,
    output logic [17:0] gfxs_addr,
    input  logic        gfxs_ack,
    input  logic [31:0] gfxs_q,

    // video out
    output logic [11:0] pix_index,      // palette index for this dot
    output logic        pix_de,         // inside the visible window
    output logic        hsync, vsync,
    output logic        hblank, vblank,

    // interrupts: INTH is the 68000's IRQ 5, INTL its IRQ 4
    output logic        inth,
    output logic        intl,

    // Frozen-state loading, for sim/run_video.sh: writes straight into the
    // chip's own memories so a bench can put a dumped MAME frame into the
    // hardware and render it.  Tied off in the core.
    input  logic        ld_we,
    input  logic  [2:0] ld_sel,         // 0 sprite RAM, 1 scroll RAM,
                                        // 2 control, 3 fb page 0, 4 fb page 1
    input  logic [16:0] ld_addr,
    input  logic [15:0] ld_data,

    // for the diagnostic overlay and the benches
    output logic  [8:0] vpos,
    output logic        spr_busy,
    output logic [17:0] spr_cycles,     // clocks the last sprite pass took
    output logic [15:0] ren_cycles      // clocks the worst line render took
);
    localparam int WIDTH = VIS_X1 - VIS_X0 + 1;
    // the visible window starts at dot 0 on this board; keep the comparison
    // out of the logic rather than letting it fold into a constant
    localparam bit LEFT_BORDER = (VIS_X0 != 0);
    localparam int HEIGHT = VIS_Y1 - VIS_Y0 + 1;
    localparam int FBN = WIDTH * HEIGHT;

    // ------------------------------------------------------ control registers
    logic [15:0] ctrl [0:15];
    wire  [7:0] video_control = ctrl[7][15:8];
    wire  [2:0] fg_page0 = ctrl[0][10:8];
    wire  [2:0] fg_page1 = ctrl[0][14:12];
    wire  [2:0] bg_page0 = ctrl[1][10:8];
    wire  [2:0] bg_page1 = ctrl[1][14:12];
    wire  [7:0] fg_blocks = ctrl[2][15:8];
    wire  [7:0] bg_blocks = ctrl[3][15:8];
    wire  [5:0] tx_bank0 = ctrl[4][13:8];
    wire  [5:0] tx_bank1 = ctrl[5][13:8];
    wire  [3:0] tx_page  = ctrl[6][11:8];

    // ------------------------------------------------------------ video timing
    logic [9:0] hpos;
    logic [8:0] vcnt;
    assign vpos = vcnt;

    wire last_dot  = (hpos == 10'(HTOTAL - 1));
    wire last_line = (vcnt == 9'(VTOTAL - 1));
    wire visible   = (vcnt >= 9'(VIS_Y0)) && (vcnt <= 9'(VIS_Y1))
                     && (!LEFT_BORDER || hpos >= 10'(VIS_X0)) && (hpos <= 10'(VIS_X1));

    always_ff @(posedge clk) begin
        if (rst) begin
            hpos <= '0;
            vcnt <= '0;
        end else if (pix_ce) begin
            if (last_dot) begin
                hpos <= '0;
                vcnt <= last_line ? 9'd0 : vcnt + 9'd1;
            end else begin
                hpos <= hpos + 10'd1;
            end
        end
    end

    // sync and blanking: the visible window sits inside a 452 x 253 raster,
    // with the blanking split around it the way the board's is
    assign hblank = (LEFT_BORDER && hpos < 10'(VIS_X0)) || (hpos > 10'(VIS_X1));
    assign vblank = (vcnt < 9'(VIS_Y0)) || (vcnt > 9'(VIS_Y1));
    assign hsync  = (hpos >= 10'(VIS_X1 + 12)) && (hpos < 10'(VIS_X1 + 12 + 40));
    assign vsync  = (vcnt >= 9'(VIS_Y1 + 3))  && (vcnt < 9'(VIS_Y1 + 6));


    // one pulse at the top of each line and at the top of vblank
    wire line_start  = pix_ce && last_dot;
    wire vbl_start   = line_start && (vcnt == 9'(VIS_Y1));            // entering line 240
    wire vbl_end     = line_start && (vcnt == 9'(VIS_Y0 - 1));        // entering line 16
    wire intl_time   = line_start && (vcnt == 9'(VIS_Y1 + 8));        // eight lines later

    // ------------------------------------------------------------- interrupts
    always_ff @(posedge clk) begin
        if (rst) begin
            inth <= 1'b0;
            intl <= 1'b0;
        end else begin
            if (vbl_start) inth <= 1'b1;
            if (intl_time) begin inth <= 1'b0; intl <= 1'b1; end
            if (vbl_end)   intl <= 1'b0;
        end
    end

    // ---------------------------------------------------------- sprite RAM
    // 0x10000-0x137FF of the chip's window: the 408 sprite entries and the
    // scratch behind them.  Dual port: the 68000 on one side, the sprite
    // engine on the other.
    localparam int SPRN = 'h1C00;
    (* ramstyle = "M10K" *) logic [1:0][7:0] sprram [0:SPRN-1];
    logic [15:0] spr_cpu_q, spr_eng_q;
    logic [11:0] spr_eng_addr;
    wire  [12:0] spr_cpu_addr = 13'(addr[18:1] - 18'h08000); // byte 0x10000
    wire         spr_sel = cs && (addr[18:1] >= 18'h08000) && (addr[18:1] < 18'h09C00);

    always_ff @(posedge clk) begin
        if (ld_we && ld_sel == 3'd0) begin
            sprram[ld_addr[12:0]] <= ld_data;
        end else if (spr_sel && we) begin
            if (ben[1]) sprram[spr_cpu_addr][1] <= din[15:8];
            if (ben[0]) sprram[spr_cpu_addr][0] <= din[7:0];
        end
        spr_cpu_q <= sprram[spr_cpu_addr];
        spr_eng_q <= sprram[{1'b0, spr_eng_addr}];
    end

    // ---------------------------------------------------------- scroll RAM
    localparam int SCRN = 1024;
    (* ramstyle = "M10K" *) logic [1:0][7:0] scrram [0:SCRN-1];
    logic [15:0] scr_cpu_q, scr_ren_q;
    logic  [9:0] scr_ren_addr;
    wire   [9:0] scr_cpu_addr = 10'(addr[18:1] - 18'h09C00); // byte 0x13800
    wire         scr_sel = cs && (addr[18:1] >= 18'h09C00) && (addr[18:1] < 18'h0A000);

    always_ff @(posedge clk) begin
        if (ld_we && ld_sel == 3'd1) begin
            scrram[ld_addr[9:0]] <= ld_data;
        end else if (scr_sel && we) begin
            if (ben[1]) scrram[scr_cpu_addr][1] <= din[15:8];
            if (ben[0]) scrram[scr_cpu_addr][0] <= din[7:0];
        end
        scr_cpu_q <= scrram[scr_cpu_addr];
        scr_ren_q <= scrram[scr_ren_addr];
    end

    // --------------------------------------------------------- framebuffer
    // Two pages.  MAME's vblank handler clears the page being displayed, then
    // flips, then paints sprites into the page now current -- different
    // pages, so the clear and the paint run at the same time here.
    logic        page;                  // the page the next frame will show
    logic        clearing;
    logic [16:0] clear_addr;

    logic        sp_fb_we;
    logic [16:0] sp_fb_addr;
    logic  [9:0] sp_fb_data;
    logic [16:0] ren_fb_addr;
    logic  [9:0] fb_q0, fb_q1;

    // the page being painted takes the sprite engine's writes; the other
    // takes the clear
    wire clear_page = ~page;
    wire ld_p0 = ld_we && ld_sel == 3'd3;
    wire ld_p1 = ld_we && ld_sel == 3'd4;
    wire clr0 = clearing && (clear_page == 1'b0);
    wire clr1 = clearing && (clear_page == 1'b1);
    wire p0_we = ld_p0 | clr0 | (sp_fb_we && page == 1'b0);
    wire p1_we = ld_p1 | clr1 | (sp_fb_we && page == 1'b1);
    wire [16:0] p0_waddr = ld_p0 ? ld_addr : (clr0 ? clear_addr : sp_fb_addr);
    wire [16:0] p1_waddr = ld_p1 ? ld_addr : (clr1 ? clear_addr : sp_fb_addr);
    wire  [9:0] p0_wdata = ld_p0 ? ld_data[9:0] : (clr0 ? 10'd0 : sp_fb_data);
    wire  [9:0] p1_wdata = ld_p1 ? ld_data[9:0] : (clr1 ? 10'd0 : sp_fb_data);

    vcu_fb #(.W(WIDTH), .H(HEIGHT)) u_fb (
        .clk(clk),
        .p0_we(p0_we), .p0_waddr(p0_waddr), .p0_wdata(p0_wdata),
        .p0_raddr(ren_fb_addr), .p0_q(fb_q0),
        .p1_we(p1_we), .p1_waddr(p1_waddr), .p1_wdata(p1_wdata),
        .p1_raddr(ren_fb_addr), .p1_q(fb_q1)
    );

    // the line renderer reads the page being displayed, which is the one the
    // sprite engine painted at the previous vblank
    wire [9:0] ren_fb_q = page ? fb_q1 : fb_q0;

    always_ff @(posedge clk) begin
        if (rst) begin
            page     <= 1'b0;
            clearing <= 1'b0;
        end else if (vbl_start) begin
            // 1. clear the page being displayed, unless bit 0 says not to
            // 2. flip, unless bit 7 pins the page to bit 6
            if (!video_control[0]) begin
                clearing   <= 1'b1;
                clear_addr <= '0;
            end
            page <= video_control[7] ? ~video_control[6] : ~page;
        end else if (clearing) begin
            if (clear_addr == 17'(FBN - 1)) clearing <= 1'b0;
            else clear_addr <= clear_addr + 17'd1;
        end
    end

    // ------------------------------------------------------- sprite engine
    logic        ren_vram_req, ren_vram_ack;
    logic [14:0] ren_vram_addr;
    logic        spr_busy_d;
    logic sp_start;
    // how long the sprite pass took, for the budget check in the benches and
    // the diagnostic overlay
    logic [17:0] spr_count;
    always_ff @(posedge clk) begin
        sp_start   <= vbl_start;
        spr_busy_d <= spr_busy;
        if (vbl_start)     spr_count <= '0;
        else if (spr_busy) spr_count <= spr_count + 18'd1;
        if (spr_busy_d && !spr_busy) spr_cycles <= spr_count;
    end

    vcu_sprite #(
        .VIS_X0(VIS_X0), .VIS_X1(VIS_X1), .VIS_Y0(VIS_Y0), .VIS_Y1(VIS_Y1)
    ) u_sprite (
        .clk(clk), .rst(rst),
        .start(sp_start), .busy(spr_busy),
        .spr_addr(spr_eng_addr), .spr_q(spr_eng_q),
        .gfx_req(gfxs_req), .gfx_addr(gfxs_addr),
        .gfx_ack(gfxs_ack), .gfx_q(gfxs_q),
        .fb_we(sp_fb_we), .fb_addr(sp_fb_addr), .fb_data(sp_fb_data)
    );

    // ------------------------------------------------------- line renderer
    // line N is built while line N-1 is on screen, into the buffer line N
    // will read
    logic       ren_start;
    logic [8:0] ren_line;
    logic       ren_busy;

    // A line is built while the line before it is on screen.  At line_start
    // the counter still holds the line just finished, so the line beginning
    // now is vcnt + 1 and the one to build during it is vcnt + 2.
    logic [15:0] ren_count;
    logic        ren_busy_d;
    always_ff @(posedge clk) begin
        ren_start  <= 1'b0;
        ren_busy_d <= ren_busy;
        if (ren_busy) ren_count <= ren_count + 16'd1;
        if (ren_busy_d && !ren_busy && ren_count > ren_cycles) ren_cycles <= ren_count;
        if (line_start) begin
            ren_count <= '0;
            // A line still being built when the next begins has overrun: it
            // goes on screen unfinished, stale beyond the point the renderer
            // reached, and the count that would have said so is thrown away
            // with it -- which is how the first hardware picture came out
            // striped while the panel read a comfortable 321.  Say so
            // instead: all ones, for the rest of the frame.
            if (ren_busy) ren_cycles <= 16'hFFFF;
            if (vcnt >= 9'(VIS_Y0 - 2) && vcnt <= 9'(VIS_Y1 - 2)) begin
                ren_line  <= vcnt + 9'd2;
                ren_start <= 1'b1;
            end
        end
        if (vbl_start) ren_cycles <= '0;
    end

    logic        lb_we;
    logic  [8:0] lb_addr;
    logic [11:0] lb_data;

    vcu_line #(
        .VIS_X0(VIS_X0), .VIS_X1(VIS_X1), .VIS_Y0(VIS_Y0), .VIS_Y1(VIS_Y1),
        .TX_BASE(TX_BASE), .FB_BASE(FB_BASE), .FG_BASE(FG_BASE), .BG_BASE(BG_BASE)
    ) u_line (
        .clk(clk), .rst(rst),
        .start(ren_start), .line(ren_line), .busy(ren_busy),
        .video_control(video_control),
        .fg_page0(fg_page0), .fg_page1(fg_page1),
        .bg_page0(bg_page0), .bg_page1(bg_page1),
        .fg_blocks(fg_blocks), .bg_blocks(bg_blocks),
        .tx_bank0(tx_bank0), .tx_bank1(tx_bank1), .tx_page(tx_page),
        .vram_req(ren_vram_req), .vram_addr(ren_vram_addr),
        .vram_ack(ren_vram_ack), .vram_q(vram_q),
        .scr_addr(scr_ren_addr), .scr_q(scr_ren_q),
        .gfx_req(gfxl_req), .gfx_addr(gfxl_addr),
        .gfx_ack(gfxl_ack), .gfx_q(gfxl_q),
        .fb_addr(ren_fb_addr), .fb_q(ren_fb_q),
        .lb_we(lb_we), .lb_addr(lb_addr), .lb_data(lb_data)
    );

    // ---------------------------------------------------------- line buffer
    // two buffers, chosen by the parity of the line they hold
    // Two line buffers, one being drawn while the other is on screen, held as
    // the two halves of one RAM: {buffer, x}, 512 entries a half so the
    // address is plain concatenation.
    //
    // This was `linebuf [0:1][0:WIDTH-1]`, a 2 x 320 array, and every bench
    // drew it correctly.  On the Pocket every other raster line showed, past
    // about x = 192, a ghost of its own first 128 pixels -- alternate lines
    // being one of the two buffers, and 192 being 512 - 320: the distance
    // between striding the second buffer by the array's 320 and by the 512
    // its nine-bit index could reach.  A simulator indexes a two-dimensional
    // array exactly as written; a synthesiser has to flatten it, and there is
    // no reason to make it choose.  One dimension, a power of two deep.
    // It is also 7,000 flops and a 640-way multiplexer fewer.
    (* ramstyle = "M10K" *) logic [11:0] linebuf [0:1023];
    logic        wr_buf;
    // the readout is registered, so the data-enable is too: both come out one
    // dot after the counters that produced them
    always_ff @(posedge clk) begin
        if (ren_start) wr_buf <= ren_line[0];
        if (lb_we) linebuf[{wr_buf, lb_addr}] <= lb_data;
        if (pix_ce) begin
            pix_index <= linebuf[{vcnt[0], hpos[8:0]}];
            pix_de    <= visible;
        end
    end

    // ------------------------------------------------------------- arbiter
    // VRAM is one port shared with the 68000; the line renderer has a
    // deadline, so it wins
    wire cpu_vram_sel = cs && (addr[18:1] < 18'h08000);
    assign vram_req  = ren_vram_req | cpu_vram_sel;
    assign vram_we   = ~ren_vram_req & cpu_vram_sel & we;
    assign vram_addr = ren_vram_req ? ren_vram_addr : addr[15:1];
    assign vram_din  = din;
    assign vram_ben  = ben;
    // The port's ack is one pulse with no name on it, and it is decided the
    // clock before it is seen: the port acks only if the request still
    // standing then is the one it began.  So whose ack it is depends on who
    // held the mux THEN, not now.  Routing it by the request lines of the
    // clock it arrives in handed the 68000's ack to the renderer whenever the
    // renderer raised its request on that very clock: it took the CPU's word
    // for its tile code and drew one wrong tile.  On the panel that was short
    // runs of noise in the first two raster lines -- the only ones built
    // while the vblank handlers are still writing the tilemaps -- which
    // vanished when the menu paused the CPU.
    logic ren_req_d;
    always_ff @(posedge clk) ren_req_d <= ren_vram_req;
    assign ren_vram_ack = vram_ack & ren_req_d & ren_vram_req;

    // ------------------------------------------------------------- CPU side
    wire ctrl_sel = cs && (addr[18:1] >= 18'h0C000) && (addr[18:1] < 18'h0C010);
    wire fb_sel   = cs && (addr[18:1] >= 18'h20000);

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 16; i++) ctrl[i] <= '0;
        end else if (ld_we && ld_sel == 3'd2) begin
            ctrl[ld_addr[3:0]] <= ld_data;
        end else if (ctrl_sel && we) begin
            if (ben[1]) ctrl[addr[4:1]][15:8] <= din[15:8];
            if (ben[0]) ctrl[addr[4:1]][7:0]  <= din[7:0];
        end
    end

    // Reads: the chip's RAMs answer a clock later, VRAM when its port acks.
    // The framebuffer is not reachable from the 68000 here -- Master of
    // Weapon never touches it (docs/hardware.md section 9) and giving it a
    // port would cost a third port on the busiest memory in the design.
    logic cpu_pend;
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        cpu_pend <= cs;
        if (cs && !cpu_pend) begin
            // one-clock accesses for everything inside the chip
            if (!cpu_vram_sel) ack <= 1'b1;
        end
        if (cpu_vram_sel && vram_ack && !ren_req_d) ack <= 1'b1;
    end

    always_comb begin
        if (spr_sel)      dout = spr_cpu_q;
        else if (scr_sel) dout = scr_cpu_q;
        else if (ctrl_sel) dout = ctrl[addr[4:1]];
        else if (fb_sel)  dout = 16'd0;
        else              dout = vram_q;
    end
endmodule

`default_nettype wire
