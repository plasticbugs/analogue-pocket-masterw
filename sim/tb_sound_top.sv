// Sound-board bench: the Z80, the YM2203 and the CIU, with the 68000 side
// driven from a log of what MAME's 68000 actually sent (tools/probe_ciu.lua).
//
// The board is almost independent once it has been told what to play -- eight
// seconds of play is a dozen bytes across the CIU -- so replaying those bytes
// at the same moments reproduces the same music without the video in the way,
// which makes the audio comparison minutes instead of half an hour.
`default_nettype none

module tb_sound_top (
    input  logic        clk,
    input  logic        reset,

    // the sound ROM, 64 KB
    input  logic        dl_we,
    input  logic [15:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic  [3:0] lat_rom,

    // the 68000 side of the CIU
    input  logic        m_port_wr,
    input  logic        m_comm_wr,
    input  logic        m_comm_rd,
    input  logic  [7:0] m_din,
    output logic  [7:0] m_dout,

    output logic signed [15:0] fm_snd,
    output logic  [7:0] psg_a, psg_b, psg_c,
    output logic signed [15:0] ym_snd,
    output logic        z80_m1
);
    logic [7:0] rom [0:65535];
    logic        rom_req, rom_ack;
    logic [15:0] rom_addr;
    logic  [7:0] rom_q;
    logic  [3:0] rom_cnt;

    always_ff @(posedge clk) begin
        if (dl_we) rom[dl_addr] <= dl_data;
        rom_ack <= 1'b0;
        if (!rom_req) rom_cnt <= '0;
        else if (!rom_ack) begin
            if (rom_cnt >= lat_rom) begin
                rom_cnt <= '0; rom_ack <= 1'b1; rom_q <= rom[rom_addr];
            end else rom_cnt <= rom_cnt + 4'd1;
        end
    end

    logic       s_port_wr, s_comm_wr, s_comm_rd;
    logic [7:0] s_din, s_dout;
    logic       ciu_nmi, ciu_reset;

    pc060ha u_ciu (
        .clk(clk), .rst(reset),
        .master_port_wr(m_port_wr), .master_comm_wr(m_comm_wr),
        .master_comm_rd(m_comm_rd), .master_din(m_din), .master_dout(m_dout),
        .slave_port_wr(s_port_wr), .slave_comm_wr(s_comm_wr),
        .slave_comm_rd(s_comm_rd), .slave_din(s_din), .slave_dout(s_dout),
        .nmi(ciu_nmi), .snd_reset(ciu_reset)
    );

    logic cen_z80, cen_ym;
    logic [4:0] div;
    always_ff @(posedge clk) div <= reset ? 5'd0 : div + 5'd1;
    assign cen_z80 = (div[3:0] == 4'd2);
    assign cen_ym  = (div      == 5'd6);

    masterw_sound u_sound (
        .clk(clk), .rst(reset), .cen_z80(cen_z80), .cen_ym(cen_ym),
        .ciu_nmi(ciu_nmi), .ciu_reset(ciu_reset),
        .ciu_port_wr(s_port_wr), .ciu_comm_wr(s_comm_wr), .ciu_comm_rd(s_comm_rd),
        .ciu_dout(s_din), .ciu_din(s_dout),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_q(rom_q),
        .fm_snd(fm_snd), .psg_a(psg_a), .psg_b(psg_b), .psg_c(psg_c),
        .z80_m1(z80_m1)
    );

    // jt03's own combined output, for comparison with the hand-built mix
    assign ym_snd = u_sound.ym_snd;
endmodule

`default_nettype wire
