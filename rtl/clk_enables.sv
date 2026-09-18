//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md section 1).
//
// Every clock on the board's 24 MHz side is an exact divider of 96 MHz, so
// these are plain counters with no fractional accumulator anywhere:
//
//   cen_phi1 / cen_phi2   fx68k's two phases, alternating, 12 MHz apiece
//   cen_z80               6 MHz
//   cen_ym                3 MHz
//   cen_pix               the video dot clock, 96 / 14 = 6.857 MHz
//
// The dot clock is the one thing that is not the board's: see the table in
// docs/core-design.md for why, and what the raster totals do about it.
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic rst,
    output logic cen_phi1,
    output logic cen_phi2,
    output logic cen_z80,
    output logic cen_ym,
    output logic cen_pix
);
    logic [4:0] div;        // 0..31: the 68000, Z80 and YM2203 all divide this
    logic [3:0] dpix;       // 0..13

    always_ff @(posedge clk) begin
        if (rst) begin
            div  <= 5'd0;
            dpix <= 4'd0;
        end else begin
            div  <= div + 5'd1;
            dpix <= (dpix == 4'd13) ? 4'd0 : dpix + 4'd1;
        end
    end

    // 96 / 8 = 12 MHz, the two phases half a CPU clock apart
    assign cen_phi1 = (div[2:0] == 3'd0);
    assign cen_phi2 = (div[2:0] == 3'd4);
    assign cen_z80  = (div[3:0] == 4'd2);       // 96 / 16 = 6 MHz
    assign cen_ym   = (div      == 5'd6);       // 96 / 32 = 3 MHz
    assign cen_pix  = (dpix     == 4'd0);       // 96 / 14 = 6.857 MHz
endmodule

`default_nettype wire
