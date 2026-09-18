//------------------------------------------------------------------------------
// Taito TC0040IOC: the inputs, the DIP switches, the coin lockout and counter
// outputs, and the watchdog.
//
// From MAME's tc0040ioc_device (ref/mame/taitoio.cpp).  It is an indexed
// port: the 68000 writes a register number to one address and reads or writes
// that register at the other.  Reading the register-number address instead
// kicks the watchdog and returns zero.
//
//   index 0  DSWA      1  DSWB      2  player 1      3  player 2
//         4  coin lockout and counters, read back as written
//         7  system: tilt, service, coins, starts
//   anything else reads 0xFF.
//
// Every input is active low.
//------------------------------------------------------------------------------
`default_nettype none

module tc0040ioc (
    input  logic       clk,
    input  logic       rst,

    input  logic       sel_wr,          // write the register number (offset 1)
    input  logic       data_wr,         // write the selected register (offset 0)
    input  logic       wdog_rd,         // read at offset 1: kicks the watchdog
    input  logic [7:0] din,
    output logic [7:0] dout,

    input  logic [7:0] dswa, dswb,
    input  logic [7:0] in0, in1, in2,

    output logic [3:0] coin_ctrl,       // lockout 1,0 and counters 3,2
    output logic       watchdog_reset   // pulses when the watchdog runs out
);
    logic [7:0] port;
    logic [7:0] regs [0:7];

    always_comb begin
        case (port)
            8'h00:   dout = dswa;
            8'h01:   dout = dswb;
            8'h02:   dout = in0;
            8'h03:   dout = in1;
            8'h04:   dout = regs[4];
            8'h07:   dout = in2;
            default: dout = 8'hff;
        endcase
    end

    assign coin_ctrl = regs[4][3:0];

    // The board's watchdog is an MB3771 fed by the 68000's reads; MAME's
    // default is three seconds of no kick.  At 96 MHz that is 2^28 clocks,
    // near enough, and the game reads it many times a frame.
    logic [27:0] wdog;

    always_ff @(posedge clk) begin
        watchdog_reset <= 1'b0;
        if (rst) begin
            port <= 8'd0;
            for (int i = 0; i < 8; i++) regs[i] <= 8'd0;
            wdog <= '0;
        end else begin
            if (sel_wr) port <= din;
            if (data_wr && port < 8'd8) regs[port[2:0]] <= din;

            if (wdog_rd) begin
                wdog <= '0;
            end else begin
                wdog <= wdog + 28'd1;
                if (&wdog) watchdog_reset <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
