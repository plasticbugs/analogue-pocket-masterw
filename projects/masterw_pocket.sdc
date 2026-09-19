# ==============================================================================
# Master of Weapon on the Pocket: timing constraints beyond the BSP's
# sys_constr.sdc. The 96 MHz system clock, its 6.857 MHz video pair and the
# shifted SDRAM clock all come from core_pll and are timed as one related
# group; the two 74.25 MHz inputs and the audio PLL are asynchronous to it.
# The PLL's fifth output drives nothing in core_top, so no clock of its own
# reaches the netlist and it is not named here -- naming it only bought an
# ignored-filter warning that hid the ones that mattered.
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# SDRAM: the chip is clocked by the phase-shifted PLL output.  The shift
# divides the budget between two checks that pull opposite ways: the data the
# chip returns is captured by an I/O-cell register on the core clock, so a
# larger shift leaves that less time, while the address and command the core
# drives are captured by the chip, so a larger shift leaves those more.
#
# Both checks on the captured data move with the shift, and in opposite
# directions: setup gets 2T - shift, hold gets T - shift, so a nanosecond
# taken off the shift is a nanosecond onto setup and a nanosecond off hold.
# Measured on this design, at the corner where each is worst:
#
#     setup slack (slow 85C) = 6.241 - shift
#     hold  slack (fast  0C) = shift - 5.519
#
# The Gaiapolis core's 6.51 ns put setup at -0.27, and 5.208 overshot the
# other way and put hold at -0.31.  They meet at 5.880; 5.859 is the nearest
# step the 960 MHz VCO can resolve, and leaves about 0.35 ns on both.
create_generated_clock -name dram_clk -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {dram_clk}]
set_input_delay -max -clock dram_clk 7.0 [get_ports {dram_dq[*]}]
set_input_delay -min -clock dram_clk 2.5 [get_ports {dram_dq[*]}]
set SDRAM_OUT [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -max -clock dram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock dram_clk -0.8 $SDRAM_OUT
set_multicycle_path -setup 2 -from [get_clocks {dram_clk}] -to [get_registers {*|sdram_ctrl:*|dq_in[*]}]
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# The pixel hand-over to the 6.857 MHz video clock. The dot enable's phase is
# pinned to clk_vid (core_top.sv's pix_sync into clk_enables.sv), so the
# colour and sync registers are launched a fixed number of system clocks
# before the clk_vid edge that samples them, and the setup check starts from
# that launch edge. The toggle the other way (vt -> vt_s) is a plain
# flop-to-flop path, checked as it stands.
set VID_OUT [get_registers {ic|vr_q[*] ic|vg_q[*] ic|vb_q[*] ic|vhs_q ic|vvs_q ic|vde_q}]
set_multicycle_path -setup 3 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT
set_multicycle_path -hold  2 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT

# SRAM: registered pins held for whole system cycles, a read sampled several
# cycles after the address (target/pocket/sram_port.sv), so the pins are not
# timed against a clock.
set_false_path -to   [get_ports {sram_*}]
set_false_path -from [get_ports {sram_dq[*]}]

# The PSRAMs are unused on this board; the BSP still brings their pins out.
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]

# fx68k steps on its two phase enables, one pair every 8 system clocks, so a
# path inside it and from it to the board's decode really has that long. The
# two phases are 4 clocks apart, which is the shorter of the two, so 4 is
# what is claimed.
set M68K [get_keepers {*|fx68k:*|*}]
set_multicycle_path -setup 4 -from $M68K -to $M68K
set_multicycle_path -hold  3 -from $M68K -to $M68K
set_multicycle_path -setup 4 -from $M68K -to [get_keepers {*|masterw_main:*|*}]
set_multicycle_path -hold  3 -from $M68K -to [get_keepers {*|masterw_main:*|*}]

# The Z80 (tv80) steps on cen_z80, one clock in sixteen: its registers, and
# the sound board's registers and RAM ports it drives, change only at those
# steps, and what the board hands back is sampled only there.
set Z80 [get_keepers {*|tv80s_cen:*|*}]
set SND [get_keepers {*|masterw_sound:*|*}]
set_multicycle_path -setup 4 -from $Z80 -to $SND
set_multicycle_path -hold  3 -from $Z80 -to $SND
set_multicycle_path -setup 4 -from $SND -to $Z80
set_multicycle_path -hold  3 -from $SND -to $Z80

# The YM2203 steps on cen_ym, one clock in thirty-two.
set YM [get_keepers {*|jt03:*|*}]
set_multicycle_path -setup 4 -from $YM -to $YM
set_multicycle_path -hold  3 -from $YM -to $YM

# The scan-out stage -- the line-buffer read, the palette read and the RGB
# expansion -- re-evaluates once per dot, fourteen clocks apart. Only the
# registers that genuinely latch at that rate get the multicycle: the line
# renderer and the sprite engine run every clock and must not be given one.
# The palette read used to be given a multicycle here too.  It never took:
# pal_vid_q is the M10K's own output register, so Quartus merges it into the
# altsyncram and no register by that name survives to be constrained -- the
# fit log said so in Warning (332174) every build, and the constraint did
# nothing.  It is gone rather than re-aimed at the RAM instance, because both
# ports of that RAM merge into the one instance and the CPU's port is not on
# the dot's fourteen-clock cadence.  The read closes on a single clock as it
# stands, which is the stricter claim of the two.
# The line-buffer readout had a multicycle here as well, when the buffers
# were 7,000 flops behind a 640-way multiplexer that took 16.8 ns to settle.
# They are one block RAM now (rtl/tc0180vcu.sv), its output register is the
# RAM's own, and a RAM read closes on a single clock -- so, like the palette
# read above, it is left to be timed as what it is.
