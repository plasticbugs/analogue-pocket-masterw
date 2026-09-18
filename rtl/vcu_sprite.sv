//------------------------------------------------------------------------------
// The TC0180VCU's sprite engine: once per vblank, walk the 408-entry sprite
// table backwards and paint every sprite into the framebuffer page the next
// frame will show.
//
// Written against tools/vcu_model.py, which is MAME's draw_sprites and
// gfx_element::zoom_transpen_raw and is pixel-identical to MAME.  Three things
// from there matter more than they look:
//
//   * The table is walked from entry 407 down to entry 0, painting over what
//     is already there, so entry 0 finishes on top.
//   * There is only one blitter.  MAME's unscaled path is exactly its scaled
//     path with a step of 1.0: the chip hands MAME `(zx << 16) / 16` as the
//     scale, an unzoomed sprite has zx = 16, and that is 0x10000.  So this
//     does the fixed-point stepping always and needs no separate case.
//   * A non-zero word 5 starts a "big sprite" whose following entries are its
//     tiles, stepping Y first then X, all sharing the first entry's position
//     and zoom.  That state carries across entries, so it lives in registers
//     here exactly as it lives in locals in MAME's loop.
//
// Budget (docs/core-design.md): 29 lines of vblank is 183,500 clocks at
// 96 MHz.  Walking the table costs a dozen clocks an entry whether or not
// anything is drawn; an on-screen sprite adds 32 graphics words and up to 256
// pixel writes.  120 seconds of play never put more than 176 entries on screen
// at once (tools/probe_sprites.lua), about 76,000 clocks; even all 408 at once
// would fit.
//------------------------------------------------------------------------------
`default_nettype none

module vcu_sprite #(
    parameter int VIS_X0 = 0,
    parameter int VIS_X1 = 319,
    parameter int VIS_Y0 = 16,
    parameter int VIS_Y1 = 239
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,          // one pulse at the top of vblank
    output logic        busy,

    // sprite RAM, word addressed, one-clock registered read
    output logic [11:0] spr_addr,
    input  logic [15:0] spr_q,

    // Graphics ROM, as a 32-word burst: the whole 16x16 tile is 32
    // consecutive image words, so the engine names the first and the memory
    // delivers them in order, one ack apiece.  That is what keeps the tile
    // fetch inside the vblank budget -- 32 random reads with auto-precharge
    // would cost five times as much.
    output logic        gfx_req,
    output logic [17:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [31:0] gfx_q,

    // framebuffer write port
    output logic        fb_we,
    output logic [16:0] fb_addr,
    output logic  [9:0] fb_data
);
    localparam int WIDTH = VIS_X1 - VIS_X0 + 1;
    localparam logic signed [12:0] CX0 = 13'(VIS_X0);
    localparam logic signed [12:0] CX1 = 13'(VIS_X1);
    localparam logic signed [12:0] CY0 = 13'(VIS_Y0);
    localparam logic signed [12:0] CY1 = 13'(VIS_Y1);
    localparam logic        [16:0] ROW_BIAS = 17'(VIS_Y0 * WIDTH);

    // ------------------------------------------------------------ tile data
    // A 16x16 tile is 32 consecutive 32-bit image words: rows 0-7 left half,
    // rows 0-7 right half, rows 8-15 left, rows 8-15 right.  Kept as pens,
    // pixel 0 in the top nibble of each half.
    logic [31:0] lbuf [0:15];
    logic [31:0] rbuf [0:15];
    logic [63:0] cur_row;

    // One image word is eight pens.  Its four bytes are pen bits 3, 2, 1, 0 --
    // MAME's gfx_layout lists bit planes most significant first -- and bit 7
    // of each byte is the leftmost pixel.
    function automatic logic [31:0] expand(input logic [31:0] w);
        logic [31:0] r;
        for (int j = 0; j < 8; j++)
            r[28 - 4*j +: 4] = {w[31-j], w[23-j], w[15-j], w[7-j]};
        return r;
    endfunction

    // -------------------------------------------------------------- entry
    logic [11:0] offs;
    logic [15:0] e_code, e_col, e_x, e_y, e_zoom;
    logic  [7:0] zoomx, zoomy;

    // big-sprite state, carried between entries as MAME carries its locals
    logic        big;
    logic  [7:0] x_no, y_no, x_num, y_num;
    logic signed [12:0] xlatch, ylatch;
    logic  [7:0] zoomxl, zoomyl;

    // this piece
    logic signed [12:0] sx, sy;
    logic signed [13:0] zx, zy;         // destination size: MAME's dstwidth
    logic        flipx, flipy;
    logic  [9:0] color;

    // blit
    logic signed [12:0] destx, desty, destendx, destendy, curx, cury;
    // 16.16 source positions and steps.  The step is at most 0x100000 (a
    // one-pixel-wide sprite) and a position at most a tile's worth of steps,
    // so 24 bits carries both with room; the full 32 made the clip multiply
    // wide enough to need two DSPs in series and it became the critical path.
    logic signed [23:0] srcx, srcy, cursrcx, dx, dy;
    logic [11:0] clipx_r, clipy_r;
    logic signed [23:0] flipx_t, flipy_t;
    logic  [5:0] fetch_i;
    logic [17:0] tile_base;
    logic [16:0] row_base;

    // ------------------------------------------------- combinational helpers
    // MAME: latch + (n * (0xff - zoom) + 15) / 16, for the piece at index n
    // of a big sprite and for the one after it, which together give its size.
    wire  [7:0] xinv = 8'hff - zoomxl;
    wire  [7:0] yinv = 8'hff - zoomyl;
    wire  [8:0] x_no1 = {1'b0, x_no} + 9'd1;
    wire  [8:0] y_no1 = {1'b0, y_no} + 9'd1;
    wire [15:0] step_a  = 16'({8'd0, x_no}  * {8'd0, xinv}) + 16'd15;
    wire [15:0] step_b  = 16'({7'd0, x_no1} * {8'd0, xinv}) + 16'd15;
    wire [15:0] step_ay = 16'({8'd0, y_no}  * {8'd0, yinv}) + 16'd15;
    wire [15:0] step_by = 16'({7'd0, y_no1} * {8'd0, yinv}) + 16'd15;

    // The products are registered before anything is done with them: as one
    // combinational cone -- multiply, add the latch, subtract -- this was the
    // design's critical path at 96 MHz, 3.3 ns over.  The sprite engine has
    // clocks to spare, so it spends one.
    logic [11:0] stepa_r, stepb_r, stepay_r, stepby_r;
    logic        was_big;

    wire signed [12:0] x_signed = {{3{e_x[9]}}, e_x[9:0]};
    wire signed [12:0] y_signed = {{3{e_y[9]}}, e_y[9:0]};

    // the piece's size, signed, for the position arithmetic
    wire signed [12:0] zxs = $signed(zx[12:0]);
    wire signed [12:0] zys = $signed(zy[12:0]);

    wire  [3:0] src_col = cursrcx[19:16];
    wire  [3:0] src_row = srcy[19:16];
    wire  [3:0] pen     = cur_row[60 - 4*src_col +: 4];

    // clipping distances, always non-negative where they are used
    wire [13:0] clip_l = 14'(CX0 - destx);
    wire [13:0] clip_t = 14'(CY0 - desty);

    // y * 320 = (y << 8) + (y << 6), without a multiplier
    wire [16:0] y_times_w = {cury[8:0], 8'd0} + {2'd0, cury[8:0], 6'd0};

    // ------------------------------------------------------------- divider
    // dx = (16 << 16) / dstwidth.  Restoring division, one bit a clock; the
    // numerator is 2^20 so only the first step shifts in a one.
    logic        div_go, div_busy;
    logic [20:0] div_quo;
    logic [13:0] div_den;
    logic [21:0] div_rem, div_sh;
    logic  [4:0] div_bit;

    assign div_sh = {div_rem[20:0], (div_bit == 5'd20) ? 1'b1 : 1'b0};

    always_ff @(posedge clk) begin
        if (rst) begin
            div_busy <= 1'b0;
        end else if (div_go) begin
            div_rem  <= '0;
            div_quo  <= '0;
            div_bit  <= 5'd20;
            div_busy <= 1'b1;
        end else if (div_busy) begin
            if (div_sh >= {8'd0, div_den}) begin
                div_rem          <= div_sh - {8'd0, div_den};
                div_quo[div_bit] <= 1'b1;
            end else begin
                div_rem <= div_sh;
            end
            if (div_bit == 5'd0) div_busy <= 1'b0;
            else div_bit <= div_bit - 5'd1;
        end
    end

    // ---------------------------------------------------------------- FSM
    typedef enum logic [4:0] {
        S_IDLE, S_E0, S_E1, S_E2, S_E3, S_E4, S_E5, S_E6, S_E7,
        S_PIECE, S_ADVANCE, S_ADVANCE2, S_SKIPCHK, S_DIVX, S_DIVXW, S_DIVY, S_DIVYW,
        S_CLIPX, S_CLIPY, S_MULX, S_MULY, S_FLIPM, S_FLIP,
        S_FETCH, S_ROWSET, S_PIX, S_NEXT, S_DONE
    } state_t;
    state_t st;

    always_ff @(posedge clk) begin
        fb_we  <= 1'b0;
        div_go <= 1'b0;

        if (rst) begin
            st      <= S_IDLE;
            busy    <= 1'b0;
            big     <= 1'b0;
            gfx_req <= 1'b0;
        end else case (st)

        S_IDLE: begin
            busy <= 1'b0;
            if (start) begin
                offs <= 12'd3256;       // (0x1980 - 16) / 2
                big  <= 1'b0;
                busy <= 1'b1;
                st   <= S_E0;
            end
        end

        // the six words of the entry that matter.  The RAM registers its
        // output, so a word read with the address set in state N arrives in
        // state N+2.
        S_E0: begin spr_addr <= offs;                              st <= S_E1; end
        S_E1: begin spr_addr <= offs + 12'd1;                      st <= S_E2; end
        S_E2: begin e_code <= spr_q; spr_addr <= offs + 12'd2;     st <= S_E3; end
        S_E3: begin e_col  <= spr_q; spr_addr <= offs + 12'd3;     st <= S_E4; end
        S_E4: begin e_x    <= spr_q; spr_addr <= offs + 12'd4;     st <= S_E5; end
        S_E5: begin e_y    <= spr_q; spr_addr <= offs + 12'd5;     st <= S_E6; end
        S_E6: begin e_zoom <= spr_q;                               st <= S_E7; end
        S_E7:                                                      st <= S_PIECE;

        // spr_q now holds word 5 and stays there: MAME's `data`
        S_PIECE: begin
            flipx <= e_col[14];
            flipy <= e_col[15];
            color <= {e_col[5:0], 4'd0};
            if (spr_q != 16'd0 && !big) begin
                // first entry of a big sprite: latch everything it shares
                big    <= 1'b1;
                x_num  <= spr_q[15:8];
                y_num  <= spr_q[7:0];
                x_no   <= 8'd0;
                y_no   <= 8'd0;
                xlatch <= x_signed;
                ylatch <= y_signed;
                zoomxl <= e_zoom[15:8];
                zoomyl <= e_zoom[7:0];
            end
            st <= S_ADVANCE;
        end

        // first clock: the four products, and the big sprite's own advance
        S_ADVANCE: begin
            was_big  <= big;
            stepa_r  <= step_a[15:4];
            stepb_r  <= step_b[15:4];
            stepay_r <= step_ay[15:4];
            stepby_r <= step_by[15:4];
            if (big) begin
                zoomx <= zoomxl;
                zoomy <= zoomyl;
                // step Y first, then X, then the big sprite is finished
                if (y_no >= y_num) begin
                    y_no <= 8'd0;
                    if (x_no >= x_num) big <= 1'b0;
                    else x_no <= x_no + 8'd1;
                end else begin
                    y_no <= y_no + 8'd1;
                end
            end else begin
                zoomx <= e_zoom[15:8];
                zoomy <= e_zoom[7:0];
            end
            st <= S_ADVANCE2;
        end

        // second clock: this piece's position and size
        S_ADVANCE2: begin
            if (was_big) begin
                sx <= xlatch + $signed({1'b0, stepa_r});
                sy <= ylatch + $signed({1'b0, stepay_r});
                zx <= $signed({2'b0, stepb_r}) - $signed({2'b0, stepa_r});
                zy <= $signed({2'b0, stepby_r}) - $signed({2'b0, stepay_r});
            end else begin
                sx <= x_signed;
                sy <= y_signed;
                zx <= $signed({5'd0, (9'h100 - {1'b0, e_zoom[15:8]}) >> 4});
                zy <= $signed({5'd0, (9'h100 - {1'b0, e_zoom[7:0]})  >> 4});
            end
            st <= S_SKIPCHK;
        end

        // nothing to draw if the piece has no size or lies outside the window
        S_SKIPCHK: begin
            destx    <= sx;
            desty    <= sy;
            destendx <= sx + zxs - 13'sd1;
            destendy <= sy + zys - 13'sd1;
            if (zx <= 14'sd0 || zy <= 14'sd0
                || sx > CX1 || (sx + zxs - 13'sd1) < CX0
                || sy > CY1 || (sy + zys - 13'sd1) < CY0)
                st <= S_NEXT;
            else begin
                div_den <= zx;
                div_go  <= 1'b1;
                st      <= S_DIVX;
            end
        end

        S_DIVX:  st <= S_DIVXW;
        S_DIVXW: if (!div_busy) begin
            dx      <= $signed({3'd0, div_quo});
            div_den <= zy;
            div_go  <= 1'b1;
            st      <= S_DIVY;
        end
        S_DIVY:  st <= S_DIVYW;
        S_DIVYW: if (!div_busy) begin
            dy <= $signed({3'd0, div_quo});
            st <= S_CLIPX;
        end

        // The clip amount, the step multiply and the flip's mirror term each
        // get their own clock: as one cone -- subtract, multiply, subtract --
        // this was the critical path at 96 MHz once the big-sprite arithmetic
        // was pipelined.  Four clocks a sprite is nothing against the 183,500
        // in vblank.
        S_CLIPX: begin
            clipx_r <= (destx < CX0) ? clip_l[11:0] : 12'd0;
            if (destx < CX0) destx <= CX0;
            if (destendx > CX1) destendx <= CX1;
            st <= S_CLIPY;
        end

        S_CLIPY: begin
            clipy_r <= (desty < CY0) ? clip_t[11:0] : 12'd0;
            if (desty < CY0) desty <= CY0;
            if (destendy > CY1) destendy <= CY1;
            st <= S_MULX;
        end

        S_MULX: begin
            srcx <= $signed({12'd0, clipx_r}) * dx;
            st   <= S_MULY;
        end

        S_MULY: begin
            srcy <= $signed({12'd0, clipy_r}) * dy;
            st   <= S_FLIPM;
        end

        // the mirror terms, MAME's (dstwidth - 1) * dx and its Y twin
        S_FLIPM: begin
            flipx_t <= ($signed({{10{zx[13]}}, zx}) - 24'sd1) * dx;
            flipy_t <= ($signed({{10{zy[13]}}, zy}) - 24'sd1) * dy;
            st      <= S_FLIP;
        end

        S_FLIP: begin
            if (flipx) begin
                srcx <= flipx_t - srcx;
                dx   <= -dx;
            end
            if (flipy) begin
                srcy <= flipy_t - srcy;
                dy   <= -dy;
            end
            tile_base <= {e_code[12:0], 5'd0};   // code % 8192, 32 words each
            fetch_i   <= 6'd0;
            gfx_addr  <= {e_code[12:0], 5'd0};
            gfx_req   <= 1'b1;
            st        <= S_FETCH;
        end

        S_FETCH: if (gfx_ack) begin
            case (fetch_i[5:3])
                3'd0: lbuf[{1'b0, fetch_i[2:0]}] <= expand(gfx_q);
                3'd1: rbuf[{1'b0, fetch_i[2:0]}] <= expand(gfx_q);
                3'd2: lbuf[{1'b1, fetch_i[2:0]}] <= expand(gfx_q);
                default: rbuf[{1'b1, fetch_i[2:0]}] <= expand(gfx_q);
            endcase
            if (fetch_i == 6'd31) begin
                gfx_req <= 1'b0;
                cury    <= desty;
                st      <= S_ROWSET;
            end else begin
                fetch_i <= fetch_i + 6'd1;
            end
        end

        S_ROWSET: begin
            cur_row  <= {lbuf[src_row], rbuf[src_row]};
            row_base <= y_times_w - ROW_BIAS;
            cursrcx  <= srcx;
            curx     <= destx;
            srcy     <= srcy + dy;
            st       <= S_PIX;
        end

        // one clock per destination pixel
        S_PIX: begin
            if (pen != 4'd0) begin
                fb_we   <= 1'b1;
                fb_addr <= row_base + 17'(curx - CX0);
                fb_data <= color + {6'd0, pen};
            end
            cursrcx <= cursrcx + dx;
            if (curx >= destendx) begin
                if (cury >= destendy) st <= S_NEXT;
                else begin
                    cury <= cury + 13'sd1;
                    st   <= S_ROWSET;
                end
            end else begin
                curx <= curx + 13'sd1;
            end
        end

        S_NEXT: begin
            if (offs == 12'd0) st <= S_DONE;
            else begin
                offs <= offs - 12'd8;
                st   <= S_E0;
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
