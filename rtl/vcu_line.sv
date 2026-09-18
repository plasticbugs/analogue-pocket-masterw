//------------------------------------------------------------------------------
// The TC0180VCU's line renderer: fill one scanline of palette indices in the
// order taitob_state::screen_update composes them.
//
//   1. bg tilemap, opaque -- it defines the background
//   2. framebuffer pixels whose bit 4 is set ("obj1")
//   3. fg tilemap, pen 0 transparent
//   4. framebuffer pixels whose bit 4 is clear ("obj0")
//   5. tx tilemap, pen 0 transparent
//
// Video control bit 3 would instead draw the framebuffer once, between fg and
// tx; Master of Weapon never sets it, but supporting it costs one pass.
// Bit 5 clear blanks the line to palette entry 0.
//
// Scrolling follows tc0180vcu_device::tilemap_draw through MAME's
// effective_rowscroll, which negates the driver's already-negated value, so
// the net mapping is tilemap = screen - scroll register, modulo the
// 1024-pixel map.  The screen is cut into blocks of `256 - ctrl[2+plane]`
// lines, each with its own scroll pair.  MAME divides 256 by that, so the
// block size is always a power of two and the division here is a shift;
// Master of Weapon always uses one block of 256 lines.
//
// Budget: a line is 6,328 clocks at 96 MHz.  This costs about 3,500 -- 21
// tiles each for bg and fg, 40 characters for tx, and two passes of 320
// framebuffer reads.
//------------------------------------------------------------------------------
`default_nettype none

module vcu_line #(
    parameter int VIS_X0 = 0,
    parameter int VIS_X1 = 319,
    parameter int VIS_Y0 = 16,
    parameter int VIS_Y1 = 239,   // for symmetry with the sprite engine; the
                                  // line renderer is told which line to draw
    // colour bases for Master of Weapon (taito_b.cpp, masterw machine config)
    parameter logic [7:0] TX_BASE = 8'h00,
    parameter logic [7:0] FB_BASE = 8'h10,
    parameter logic [7:0] FG_BASE = 8'h20,
    parameter logic [7:0] BG_BASE = 8'h30
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,          // render the line in `line`
    input  logic  [8:0] line,           // screen y, VIS_Y0..VIS_Y1
    output logic        busy,

    // control registers, as the chip decodes them
    input  logic  [7:0] video_control,
    input  logic  [2:0] fg_page0, fg_page1,
    input  logic  [2:0] bg_page0, bg_page1,
    input  logic  [7:0] fg_blocks, bg_blocks,
    input  logic  [5:0] tx_bank0, tx_bank1,
    input  logic  [3:0] tx_page,

    // VRAM, word addressed
    output logic        vram_req,
    output logic [14:0] vram_addr,
    input  logic        vram_ack,
    input  logic [15:0] vram_q,

    // scroll RAM, word addressed, one-clock registered read
    output logic  [9:0] scr_addr,
    input  logic [15:0] scr_q,

    // graphics ROM: 32-bit words, one per 8-pixel row
    output logic        gfx_req,
    output logic [17:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [31:0] gfx_q,

    // the framebuffer page being displayed, one-clock registered read
    output logic [16:0] fb_addr,
    input  logic  [9:0] fb_q,

    // the line buffer being filled
    output logic        lb_we,
    output logic  [8:0] lb_addr,
    output logic [11:0] lb_data
);
    localparam int WIDTH = VIS_X1 - VIS_X0 + 1;
    localparam logic signed [10:0] LX1 = 11'(VIS_X1 - VIS_X0);
    localparam logic        [16:0] ROW_BIAS = 17'(VIS_Y0 * WIDTH);

    // One image word is eight pens: its four bytes are pen bits 3, 2, 1, 0
    // (MAME lists bit planes most significant first) and bit 7 of each byte
    // is the leftmost pixel.
    function automatic logic [31:0] expand(input logic [31:0] w);
        logic [31:0] r;
        for (int j = 0; j < 8; j++)
            r[28 - 4*j +: 4] = {w[31-j], w[23-j], w[15-j], w[7-j]};
        return r;
    endfunction

    // log2 of the scroll block size, which MAME's 256 / lines_per_block makes
    // a power of two
    function automatic logic [3:0] block_shift(input logic [7:0] blocks);
        logic [8:0] lpb;
        lpb = 9'd256 - {1'b0, blocks};
        if      (lpb[8]) return 4'd8;
        else if (lpb[7]) return 4'd7;
        else if (lpb[6]) return 4'd6;
        else if (lpb[5]) return 4'd5;
        else if (lpb[4]) return 4'd4;
        else if (lpb[3]) return 4'd3;
        else if (lpb[2]) return 4'd2;
        else if (lpb[1]) return 4'd1;
        else             return 4'd0;
    endfunction

    // ------------------------------------------------------------ the passes
    localparam logic [2:0] K_BG = 3'd0, K_FG = 3'd1, K_FBH = 3'd2,
                           K_FBL = 3'd3, K_FBA = 3'd4, K_TX = 3'd5, K_END = 3'd6;
    logic [2:0] step;
    logic [2:0] kind;
    always_comb begin
        if (video_control[3]) begin
            case (step)
                3'd0:    kind = K_BG;
                3'd1:    kind = K_FG;
                3'd2:    kind = K_FBA;
                3'd3:    kind = K_TX;
                default: kind = K_END;
            endcase
        end else begin
            case (step)
                3'd0:    kind = K_BG;
                3'd1:    kind = K_FBH;
                3'd2:    kind = K_FG;
                3'd3:    kind = K_FBL;
                3'd4:    kind = K_TX;
                default: kind = K_END;
            endcase
        end
    end

    // ---------------------------------------------------------------- state
    logic  [8:0] y;
    logic [15:0] scrollx, scrolly;
    logic  [9:0] mx0, my;
    logic  [5:0] tcol;
    logic signed [10:0] px;
    logic [15:0] code, attr;
    logic [63:0] pens;
    logic  [4:0] pix;
    logic  [8:0] fbx;

    logic  [2:0] page0, page1;
    logic  [7:0] cbase;
    logic        opaque;
    logic        fb_want;              // which framebuffer half this pass draws
    logic        fb_all;

    wire  [3:0] prow_raw = my[3:0];
    wire  [3:0] prow     = attr[7] ? ~prow_raw : prow_raw;      // attribute flip Y
    wire  [5:0] tcol_map = mx0[9:4] + tcol;
    wire [14:0] tindex   = {page0, my[9:4], tcol_map};
    wire [14:0] tindex_a = {page1, my[9:4], tcol_map};
    // a 16x16 tile is 32 consecutive image words: rows 0-7 left, 0-7 right,
    // 8-15 left, 8-15 right
    wire [17:0] tile_w   = {code[12:0], 5'd0}
                           + {13'd0, prow[3], 1'b0, prow[2:0]};
    wire  [3:0] cidx     = attr[6] ? ~pix[3:0] : pix[3:0];      // attribute flip X
    wire  [3:0] pen      = pens[60 - 4*cidx +: 4];
    wire  [3:0] tpen     = pens[60 - 4*{1'b0, pix[2:0]} +: 4];
    wire signed [10:0] sxpix = px + $signed({7'd0, pix[3:0]});

    // text layer: one word per character, its bit 11 choosing a 2048-character
    // bank, its top nibble the colour
    wire [14:0] tx_index = {tx_page, y[7:3], tcol};
    wire [14:0] tx_code  = {(code[11] ? tx_bank1[3:0] : tx_bank0[3:0]), code[10:0]};
    wire [17:0] tx_word  = {tx_code, 3'd0} + {15'd0, y[2:0]};

    // scroll pair for this line's block
    wire  [3:0] shft    = block_shift((kind == K_BG) ? bg_blocks : fg_blocks);
    wire  [8:0] blk_y   = (y >> shft) << shft;
    wire  [9:0] scr_idx = ((kind == K_BG) ? 10'h200 : 10'h000) + {blk_y, 1'b0};

    wire  [9:0] mx0_next = 10'd0 - scrollx[9:0];
    // y * 320 = (y << 8) + (y << 6), less the bias for the first visible line
    wire  [16:0] fb_base = {y, 8'd0} + {2'd0, y, 6'd0} - ROW_BIAS;

    typedef enum logic [4:0] {
        S_IDLE, S_BLANK, S_PASS,
        S_SCR0, S_SCR1, S_SCR2, S_SETUP,
        S_TF0, S_TF1, S_TF2, S_TG0, S_TG1, S_TG2, S_TPIX,
        S_XF0, S_XF1, S_XG0, S_XG1, S_XPIX,
        S_FB0, S_FB1, S_FB2,
        S_DONE
    } state_t;
    state_t st;

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;

        if (rst) begin
            st       <= S_IDLE;
            busy     <= 1'b0;
            vram_req <= 1'b0;
            gfx_req  <= 1'b0;
        end else case (st)

        S_IDLE: begin
            busy <= 1'b0;
            if (start) begin
                y    <= line;
                busy <= 1'b1;
                if (!video_control[5]) begin
                    lb_addr <= 9'd0;
                    st      <= S_BLANK;
                end else begin
                    step <= 3'd0;
                    st   <= S_PASS;
                end
            end
        end

        // the video is disabled: the whole line is palette entry 0
        S_BLANK: begin
            lb_we   <= 1'b1;
            lb_data <= 12'd0;
            if (lb_addr == 9'(WIDTH - 1)) st <= S_DONE;
            else lb_addr <= lb_addr + 9'd1;
        end

        S_PASS: begin
            case (kind)
                K_BG, K_FG: begin
                    page0    <= (kind == K_BG) ? bg_page0 : fg_page0;
                    page1    <= (kind == K_BG) ? bg_page1 : fg_page1;
                    cbase    <= (kind == K_BG) ? BG_BASE  : FG_BASE;
                    opaque   <= (kind == K_BG);
                    scr_addr <= scr_idx;
                    st       <= S_SCR0;
                end
                K_FBH, K_FBL, K_FBA: begin
                    fb_want <= (kind == K_FBH);
                    fb_all  <= (kind == K_FBA);
                    fbx     <= 9'd0;
                    fb_addr <= fb_base;
                    st      <= S_FB0;
                end
                K_TX: begin
                    tcol <= 6'd0;
                    st   <= S_XF0;
                end
                default: st <= S_DONE;
            endcase
        end

        // ------------------------------------------------ bg / fg tilemap
        // the scroll RAM registers its output: a word addressed in state N
        // arrives in state N+2
        S_SCR0: begin scr_addr <= scr_addr + 10'd1; st <= S_SCR1; end
        S_SCR1: begin scrollx <= scr_q;             st <= S_SCR2; end
        S_SCR2: begin
            scrolly <= scr_q;
            mx0     <= mx0_next;
            px      <= -$signed({7'd0, mx0_next[3:0]});
            tcol    <= 6'd0;
            st      <= S_SETUP;
        end
        S_SETUP: begin
            my <= {1'b0, y} - scrolly[9:0];
            st <= S_TF0;
        end

        S_TF0: begin
            vram_req  <= 1'b1;
            vram_addr <= tindex;
            st        <= S_TF1;
        end
        S_TF1: if (vram_ack) begin
            code      <= vram_q;
            vram_addr <= tindex_a;
            st        <= S_TF2;
        end
        S_TF2: if (vram_ack) begin
            attr     <= vram_q;
            vram_req <= 1'b0;
            st       <= S_TG0;
        end
        S_TG0: begin
            gfx_req  <= 1'b1;
            gfx_addr <= tile_w;
            st       <= S_TG1;
        end
        S_TG1: if (gfx_ack) begin
            pens[63:32] <= expand(gfx_q);
            gfx_addr    <= tile_w + 18'd8;
            st          <= S_TG2;
        end
        S_TG2: if (gfx_ack) begin
            pens[31:0] <= expand(gfx_q);
            gfx_req    <= 1'b0;
            pix        <= 5'd0;
            st         <= S_TPIX;
        end

        S_TPIX: begin
            if (sxpix >= 11'sd0 && sxpix <= LX1 && (opaque || pen != 4'd0)) begin
                lb_we   <= 1'b1;
                lb_addr <= sxpix[8:0];
                lb_data <= {cbase + {2'd0, attr[5:0]}, pen};
            end
            if (pix == 5'd15) begin
                if (px + 11'sd16 > LX1) begin
                    step <= step + 3'd1;
                    st   <= S_PASS;
                end else begin
                    px   <= px + 11'sd16;
                    tcol <= tcol + 6'd1;
                    st   <= S_TF0;
                end
            end else begin
                pix <= pix + 5'd1;
            end
        end

        // ---------------------------------------------------- text layer
        S_XF0: begin
            vram_req  <= 1'b1;
            vram_addr <= tx_index;
            st        <= S_XF1;
        end
        S_XF1: if (vram_ack) begin
            code     <= vram_q;
            attr     <= 16'd0;          // the text layer has no per-tile flip
            vram_req <= 1'b0;
            st       <= S_XG0;
        end
        S_XG0: begin
            gfx_req  <= 1'b1;
            gfx_addr <= tx_word;
            st       <= S_XG1;
        end
        S_XG1: if (gfx_ack) begin
            pens[63:32] <= expand(gfx_q);
            gfx_req     <= 1'b0;
            pix         <= 5'd0;
            px          <= $signed({2'd0, tcol, 3'd0});
            st          <= S_XPIX;
        end
        S_XPIX: begin
            if (tpen != 4'd0) begin
                lb_we   <= 1'b1;
                lb_addr <= sxpix[8:0];
                lb_data <= {TX_BASE + {4'd0, code[15:12]}, tpen};
            end
            if (pix == 5'd7) begin
                if (tcol == 6'(WIDTH / 8 - 1)) begin
                    step <= step + 3'd1;
                    st   <= S_PASS;
                end else begin
                    tcol <= tcol + 6'd1;
                    st   <= S_XF0;
                end
            end else begin
                pix <= pix + 5'd1;
            end
        end

        // ---------------------------------------------------- framebuffer
        // the read runs one pixel ahead of the write
        S_FB0: begin fb_addr <= fb_addr + 17'd1; st <= S_FB1; end
        S_FB1: st <= S_FB2;
        S_FB2: begin
            if (fb_q != 10'd0 && (fb_all || fb_q[4] == fb_want)) begin
                lb_we   <= 1'b1;
                lb_addr <= fbx;
                lb_data <= {FB_BASE, 4'd0} + {2'd0, fb_q};
            end
            if (fbx == 9'(WIDTH - 1)) begin
                step <= step + 3'd1;
                st   <= S_PASS;
            end else begin
                fbx     <= fbx + 9'd1;
                fb_addr <= fb_addr + 17'd1;
            end
        end

        S_DONE: begin
            busy <= 1'b0;
            st   <= S_IDLE;
        end

        default: st <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
