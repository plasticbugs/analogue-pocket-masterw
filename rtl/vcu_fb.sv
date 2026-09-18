//------------------------------------------------------------------------------
// The TC0180VCU's sprite framebuffer: two pages of the visible window, each a
// separate memory so the chip can clear one while it paints the other.
//
// A page holds 320x224 ten-bit values -- `(colour & 0x3F) * 16 + pen`, with
// pen 0 never written, so zero means "nothing here".  Only the visible window
// matters: MAME clips both the clear and the sprite drawing to it, and Master
// of Weapon never reads or writes the framebuffer through the CPU
// (docs/hardware.md section 9).  Addresses are `(y - 16) * 320 + x`.
//
// Each page is simple dual-port: one write port for whichever of the clear
// and the sprite engine owns it this frame, one read port for the line
// renderer.
//------------------------------------------------------------------------------
`default_nettype none

module vcu_fb #(
    parameter int W = 320,
    parameter int H = 224
) (
    input  logic        clk,

    // page 0
    input  logic        p0_we,
    input  logic [16:0] p0_waddr,
    input  logic  [9:0] p0_wdata,
    input  logic [16:0] p0_raddr,
    output logic  [9:0] p0_q,

    // page 1
    input  logic        p1_we,
    input  logic [16:0] p1_waddr,
    input  logic  [9:0] p1_wdata,
    input  logic [16:0] p1_raddr,
    output logic  [9:0] p1_q
);
    localparam int N = W * H;

    (* ramstyle = "M10K" *) logic [9:0] page0 [0:N-1];
    (* ramstyle = "M10K" *) logic [9:0] page1 [0:N-1];

    always_ff @(posedge clk) begin
        if (p0_we) page0[p0_waddr] <= p0_wdata;
        p0_q <= page0[p0_raddr];
    end

    always_ff @(posedge clk) begin
        if (p1_we) page1[p1_waddr] <= p1_wdata;
        p1_q <= page1[p1_raddr];
    end
endmodule

`default_nettype wire
