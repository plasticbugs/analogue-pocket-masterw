//------------------------------------------------------------------------------
// Taito PC060HA CIU: the mailbox between the 68000 and the Z80.
//
// A literal translation of MAME's tc0140syt_device (ref/mame/taitosnd.cpp),
// which is also its PC060HA -- MAME implements the two as one device and
// notes that the PC060HA has been decapped and found to be a ULA.
//
// Each side writes a mode nibble to its port address and then reads or writes
// data at the address above it.  Modes 0-3 are four nibbles in each
// direction, which is how a two-byte command crosses; mode 4 reads the status
// byte, and on the master side writing mode 4 drives the Z80's reset line.
// The slave uses modes 5 and 6 to disable and enable its own NMI.
//
// Reads have side effects -- each one advances the mode and can clear a full
// flag -- so `master_rd` and `slave_rd` must be one clock long, at the end of
// the access.
//------------------------------------------------------------------------------
`default_nettype none

module pc060ha (
    input  logic       clk,
    input  logic       rst,

    // 68000 side
    input  logic       master_port_wr,      // write the mode nibble
    input  logic       master_comm_wr,      // write data
    input  logic       master_comm_rd,      // read data, one clock
    input  logic [7:0] master_din,
    output logic [7:0] master_dout,

    // Z80 side
    input  logic       slave_port_wr,
    input  logic       slave_comm_wr,
    input  logic       slave_comm_rd,
    input  logic [7:0] slave_din,
    output logic [7:0] slave_dout,

    output logic       nmi,                 // to the Z80
    output logic       snd_reset            // holds the Z80 in reset
);
    localparam logic [7:0] PORT01_FULL        = 8'h01;
    localparam logic [7:0] PORT23_FULL        = 8'h02;
    localparam logic [7:0] PORT01_FULL_MASTER = 8'h04;
    localparam logic [7:0] PORT23_FULL_MASTER = 8'h08;

    logic [3:0] mainmode, submode;
    logic [7:0] status;
    logic       nmi_enabled;
    logic [3:0] slavedata  [0:3];      // 68000 -> Z80
    logic [3:0] masterdata [0:3];      // Z80 -> 68000

    assign nmi = nmi_enabled && |(status & (PORT01_FULL | PORT23_FULL));

    always_comb begin
        master_dout = 8'd0;
        case (mainmode)
            4'd0, 4'd1, 4'd2, 4'd3: master_dout = {4'd0, masterdata[mainmode[1:0]]};
            4'd4:                   master_dout = status;
            default: ;
        endcase
    end

    always_comb begin
        slave_dout = 8'd0;
        case (submode)
            4'd0, 4'd1, 4'd2, 4'd3: slave_dout = {4'd0, slavedata[submode[1:0]]};
            4'd4:                   slave_dout = status;
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mainmode    <= 4'd0;
            submode     <= 4'd0;
            status      <= 8'd0;
            nmi_enabled <= 1'b0;
            snd_reset   <= 1'b0;
            for (int i = 0; i < 4; i++) begin
                slavedata[i]  <= 4'd0;
                masterdata[i] <= 4'd0;
            end
        end else begin
            // ---- master side ----
            if (master_port_wr) mainmode <= master_din[3:0];

            if (master_comm_wr) begin
                case (mainmode)
                    4'd0: begin slavedata[0] <= master_din[3:0]; mainmode <= 4'd1; end
                    4'd1: begin slavedata[1] <= master_din[3:0]; mainmode <= 4'd2;
                                status <= status | PORT01_FULL; end
                    4'd2: begin slavedata[2] <= master_din[3:0]; mainmode <= 4'd3; end
                    4'd3: begin slavedata[3] <= master_din[3:0]; mainmode <= 4'd4;
                                status <= status | PORT23_FULL; end
                    4'd4: snd_reset <= |master_din;   // a high-low transition resets
                    default: ;
                endcase
            end

            if (master_comm_rd) begin
                case (mainmode)
                    4'd0: mainmode <= 4'd1;
                    4'd1: begin mainmode <= 4'd2; status <= status & ~PORT01_FULL_MASTER; end
                    4'd2: mainmode <= 4'd3;
                    4'd3: begin mainmode <= 4'd4; status <= status & ~PORT23_FULL_MASTER; end
                    default: ;
                endcase
            end

            // ---- slave side ----
            if (slave_port_wr) submode <= slave_din[3:0];

            if (slave_comm_wr) begin
                case (submode)
                    4'd0: begin masterdata[0] <= slave_din[3:0]; submode <= 4'd1; end
                    4'd1: begin masterdata[1] <= slave_din[3:0]; submode <= 4'd2;
                                status <= status | PORT01_FULL_MASTER; end
                    4'd2: begin masterdata[2] <= slave_din[3:0]; submode <= 4'd3; end
                    4'd3: begin masterdata[3] <= slave_din[3:0]; submode <= 4'd4;
                                status <= status | PORT23_FULL_MASTER; end
                    4'd5: nmi_enabled <= 1'b0;
                    4'd6: nmi_enabled <= 1'b1;
                    default: ;
                endcase
            end

            if (slave_comm_rd) begin
                case (submode)
                    4'd0: submode <= 4'd1;
                    4'd1: begin submode <= 4'd2; status <= status & ~PORT01_FULL; end
                    4'd2: submode <= 4'd3;
                    4'd3: begin submode <= 4'd4; status <= status & ~PORT23_FULL; end
                    default: ;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
