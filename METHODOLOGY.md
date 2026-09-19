# Building an arcade-accurate openFPGA core

Method, tooling and hard-won lessons from the Xenophobe (Midway MCR-68000)
core, written to bootstrap Time Pilot. Everything here was learned by doing it
once; the sections marked **cost me time** are the ones worth reading twice.

§5.8 onward, and the recipes and list items marked the same way, were added
after the Pleiads / Phoenix core (Amstar, 8085, discrete sound), which was
built from this document. They are the things it did not yet say.

§5.16 onward, marked *(Master of Weapon)*, were added after the Master of
Weapon core (Taito B System: 68000, Z80, YM2203, TC0180VCU), built from this
document in turn. Its simulation was green for days before it met a Pocket, and
its first four hardware runs found four faults no bench had shown. Those
sections are about that gap.

---

## 1. The central idea

Three artefacts, in this order. Each one makes the next cheaper.

**MAME is the oracle.** Not a reference to read — a program to interrogate. Its
Lua interface can tap memory writes, force inputs, dump RAM, record audio and
snapshot frames. Nearly every question about "what does the real hardware do
here" is answerable in a few minutes with a Lua script, and the answer is
authoritative. Guessing instead is what cost me the most time on Xenophobe.

**A reference renderer is the executable spec.** Before writing video RTL, write
a Python program that reads a dumped machine state (VRAM, sprite RAM, palette)
and produces the exact frame MAME produces. Iterate until it is pixel-identical
on a spread of frames. Now you own a precise, readable statement of the video
hardware's semantics — priority rules, transparency, coordinate maths — and you
can consult it while writing RTL instead of re-deriving from MAME's C++.

**Frozen-state benches are the regression gate.** Load a dumped state directly
into the RTL's memories, render one frame in Verilator, diff against the
reference renderer. Roughly 30 seconds per run. Every video change gets checked
against a set of states before it goes near hardware. On Xenophobe this held at
zero differing pixels across seven states, including the heaviest sprite load
found in real play, and caught several "optimisations" that were wrong.

The pattern generalises: **make the correct answer cheap to compute, then check
against it constantly.**

---

## 2. Toolchain

| Tool | Role | Notes |
|---|---|---|
| MAME (`brew install mame`) | Oracle | `-video none -sound none -nothrottle -skip_gameinfo`, always `-cfg_directory`/`-nvram_directory` somewhere disposable, and the four flags below that keep it off the screen |
| MAME Lua (`-autoboot_script`) | Instrumentation | `install_write_tap`, `register_frame_done`, `ioport` fields, `machine.video:snapshot()`, `-wavwrite` |
| Verilator | RTL simulation | Fast enough for whole-frame and whole-second simulations |
| Quartus 18.1 in Docker | Synthesis | `raetro/quartus:pocket`, `--platform linux/amd64` on Apple silicon |
| Ghidra (optional, via MCP) | Disassembly | Only as far as needed to answer specific questions |
| Python 3 | Everything else | Reference renderer, image diffing, ROM building, audio analysis. No numpy needed |

**Keep MAME off the display** *(Master of Weapon)*. `-video none` stops MAME
rendering to a window but not creating one, and MAME's defaults are fullscreen
(`window 0`, `maximize 1`) — so on macOS the desktop jumps to another Space
every time a probe runs, which during a capture session is several times a
minute and lands on whatever the user was doing. Three measures, because they
fail independently:

```sh
SDL_VIDEODRIVER=dummy \            # SDL never opens the display; read before MAME parses anything
mame ... -videodriver dummy \      # the same instruction through MAME's own option
         -window -nomaximize       # and if a window appears anyway it steals no Space
```

Snapshots come out byte-identical, so nothing about the capture changes. Put
it in the wrapper script, not in each invocation, so no ad-hoc probe can
forget it.

Two Quartus habits worth keeping:

- `quartus_map` alone (~2 min) catches syntax and inference errors without a
  full fit. Run it before every push. I once pushed a "fix" that referenced a
  nonexistent bit and burned a CI cycle discovering it.
- The full compile runs in CI on every push. Builds take ~20 minutes, so treat
  a build as expensive and verify everything verifiable beforehand.

---

## 3. Workflow

**Phase 1 — map the hardware.** Read MAME's driver for memory maps, IRQ sources,
clock rates and input bit assignments. Write it into `docs/hardware.md` as you
go; you will consult it constantly. Record exact clock frequencies — they matter
more than you expect (see §5.3).

**Phase 2 — build the ROM path first.** Write the tool that turns the user's
MAME romset into whatever image the core loads, and verify each ROM's CRC while
doing it. Get this right early: every later test depends on having correct data
in the right place.

**Phase 3 — reference renderer.** Dump states from MAME with Lua, render them in
Python, diff against MAME's snapshots until pixel-identical. Expect to discover
non-obvious semantics here — Xenophobe's sprite priority turned out to be
first-wins per priority class, with pen 8 claiming a pixel invisibly, which no
amount of staring at RTL would have revealed.

**Phase 4 — RTL against the frozen bench.** Build the video core and check every
change against the reference renderer. Only then integrate into the platform.

**Phase 5 — full system.** Both CPUs, real memory paths, audio capture. Slower
(~20 min for a few hundred frames), so use it for integration questions, not
iteration.

**Phase 6 — hardware.** Reserve for faults that cannot be reproduced in
simulation. Add an on-screen diagnostic overlay before you need it.

---

## 4. Verification recipes

**Dump a machine state from MAME:**

```lua
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local f = io.open("state.txt", "w")
f:write("VRAM\n")
for i = 0, 2047 do f:write(string.format("%04x\n", sp:read_u16(VRAM_BASE + i*2))) end
f:close()
manager.machine.video:snapshot()
```

**Drive the game to a specific situation** with `ioport` fields and a frame
counter — coin at frame N, start at N+20, and so on. This is how you reach
gameplay states worth capturing.

**Watch a value the CPU writes** with `install_write_tap` on the relevant range.
Note that a tap may not see accesses that go through an installed write handler;
if a tap comes back empty, instrument your own RTL instead.

**Compare audio against MAME** by sending the same sound command in both and
recording with `-wavwrite`. Compare peak, RMS and per-band energy. This is how I
proved our output was 6 dB low: same command, same window, ratio 2.06.

**Hold a CPU to MAME one bus transaction at a time** *(Pleiads/Phoenix)*. Log
every read and write — address, data, direction — from MAME with memory taps,
log the same from the RTL's bus strobe, and diff the two from reset. It needs no
test program and it localises a fault to the instruction that caused it: a
missing address line in the decode showed up as one write landing on the wrong
register at transaction 50,668. Check cycle counts separately, per instruction,
against the emulator's own table. Two things to know before trusting a
mismatch: MAME does not perform the operand reads of a conditional jump it does
not take, and its first frame starts at vblank rather than line 0. Anything the
CPU *polls* — a vblank bit, here — will eventually sample differently, and the
trace is only comparable up to there; say so in the bench rather than masking it.

**Compare audio where it sounds, with a metric that suits it** *(Pleiads/Phoenix)*.
Drive the game into play before recording; attract mode exercises a fraction of
the sound hardware. Then look at the whole capture second by second, not at one
window. Waveform correlation is the right measure when the CPU restarts the
oscillators on every note, because they stay phase-locked to the emulator's —
one game here held +1.0000 for twenty seconds. For anything free-running it is
the wrong one: two square-wave synthesisers with a sub-note timing offset are
spectrally identical and correlate at zero. Use band energy per second as a
ratio to the emulator, skip the seconds where the reference is silent, and
summarise as mean |log ratio| so that 0 means the same spectrum. See §5.9.

**Capture what the whole core does, not only what a block does when fed**
*(Pleiads/Phoenix)*. Give the system bench a mode that runs from reset, records
the core's own audio output, and logs the sound-command writes it makes in the
same format the emulator trace uses. Then the model can be run on *the core's
own commands* and compared sample for sample, with no dependence on the
emulator's recorded session matching yours. See §5.10.

**Diagnostic overlay on hardware:** a few rows of coloured squares on the bottom
scanlines, each a status bit, hidden behind a menu option. Cheap in logic, and
the only way to see inside a fault that only appears on real hardware.

---

## 5. Key learnings

### 5.1 Measure before you diagnose — and check the instrument

**Cost me time, repeatedly.** I announced confident causes three times on the
audio problem alone: bus contention, then downstream clipping, then a truncation
bug. Measurement killed all three. What eventually found it was one user
observation I could not explain away.

Worse, I once "fixed" a bug that existed only in my measurement harness:
Verilator exposes ports unsigned, so reading a signed 16-bit sample without a
cast made clean audio look railed and full of harmonics. **When a measurement
shows something shocking, suspect the harness first.**

Practical rules that emerged:

- A theory that explains only some of the observations is wrong, not incomplete.
- If a change is meant to fix something, predict the measurement it should move,
  and check that specific number.
- State plainly when you cannot reproduce something. Shipping a speculative fix
  costs the user a build cycle and teaches you nothing.

### 5.2 Budget bandwidth explicitly

Write down the cycle budget per scanline and what consumes it. On Xenophobe:
1270 clocks per line; a full sprite-table scan cost 512 of them; each sprite cost
~75 more (38 fetch, 32 blend, ~5 attribute reads). That arithmetic said ~10
sprites per line, and sampling real gameplay in MAME found lines needing 17. The
mismatch *was* the flicker — the engine ran out of time, skipped starting the
next line, and rendered sprites on alternating lines.

Two fixes, both measurable: snapshot sprite RAM during vblank and record the
highest used entry so the scan stops there; and overlap each sprite's fetch with
the previous sprite's blend so cost becomes `max(38, 32)` rather than the sum.
Worst line went from 1270 clocks and overrunning to 807 with room spare.

**For Time Pilot this whole category likely disappears** — see §6.

### 5.3 Sound boards have no slack

The Sounds Good board has no timer. Its only interrupt is a command handshake,
so the sound CPU's *execution rate is the sample rate*: bandwidth it loses
becomes pitch and tempo error, directly. Ours ran ~20% slow because its ROM
fetches crossed SDRAM with wait states that real hardware does not have.

Two general lessons:

- **Find out what paces the audio.** If it is a timer, CPU speed only affects
  whether it keeps up. If it is the CPU itself, every stall is audible.
- Game logic is usually frame-locked to the video interrupt, so it tolerates
  stalls invisibly. Audio does not. A core can feel perfect and still have
  audibly wrong sound.

Fix was a small direct-mapped cache over the sound ROM — trivially safe because
the ROM is read-only, so entries can never go stale. Restored 99.6–99.9% of
hardware rate.

### 5.4 Clock domain crossings — the bug that hid from everything

**The most valuable lesson here.** Audio conditioning ran on the 40 MHz core
clock; the Pocket's audio filter runs on a PLL derived from `clk_74b`. The
16-bit sample bus crossed between them unsynchronised. The audio side could latch
a mix of old and new bits, and a torn 16-bit sample is not a small error — one
flipped high bit throws the value across the range. Heard as clicks and static.

It defeated every measurement because **both sides were individually correct**.
Our rendering matched MAME within a few percent across 8 seconds of music; the
mixer measured at unity gain with no saturation. The fault existed only in the
handoff, which no simulation of either side can show.

Most cores never hit this: their audio changes only at the sound chip's sample
rate, so the bus is still between updates. Ours carried a filtered value moving
every 40 MHz cycle — never stable.

```systemverilog
// sample at ~48 kHz, hold, hand over with a toggle flag
always_ff @(posedge clk_sys) begin
    snd_div <= snd_div + 1'd1;
    if (snd_div == DIV_48K) begin
        snd_div <= '0; snd_hold <= snd_pcm; snd_tog <= ~snd_tog;
    end
end
always_ff @(posedge clk_74b) begin
    snd_tog_s <= {snd_tog_s[1:0], snd_tog};
    if (snd_tog_s[2] != snd_tog_s[1]) snd_xfer <= snd_hold;  // stable by now
end
```

**Audit every multi-bit signal that crosses a clock domain, at the start.** For
Time Pilot the AY-3-8910 outputs will cross exactly this boundary.

### 5.5 openFPGA platform traps

**`input.json` does not mean what it looks like.** List *position* selects the
physical button, in the order **B, A, X** (Game Boy convention, not A first).
The `key` field does **not** choose the button — it names the `cont1_key` bit the
core reads when that button is pressed. So an entry declaring `pad_btn_x` in
position 2 is correct and deliberate: A sits in position 2 and asserts the bit
the gateware routes to that function. Reordering entries changes which pad does
what; changing a key changes which game input it drives.

**The Pocket persists a per-`id` remap** in
`/Settings/<core>/Input/_core/input_persist.json`, binding entry ids to physical
buttons. Reuse an id whose meaning changed and the saved file silently overrides
your defaults — buttons appear rotated. **Give entries fresh ids whenever the
layout changes.** This cost several rounds of confusing hardware testing.

**Valid keycodes** are `pad_btn_a/b/x/y`, `pad_trig_l/r`, `pad_btn_start`,
`pad_btn_select`. `pad_select` is not one; an invalid key silently does nothing.

**`info.txt`** drives the core's detail page: max 32 lines, plain characters,
`*` for bullets.

**The framework names pad buttons by position, not by number** *(Pleiads/Phoenix)*:
`m_btn1` is Y, `m_btn2` is B, `m_btn3` is A, `m_btn4` is X. Taking them in
numeric order puts fire on Y.

**The Pocket shows `core.json`'s `version`, not your tag.** It sat at 0.1.0
through three releases here. Have the release script refuse a tag that
disagrees with it.

**Artwork is two raw files** *(Pleiads/Phoenix)*: `Cores/<id>/icon.bin`, 36×36,
and `Platforms/_images/<platform>.bin`, 521×165. Both are 16 bits per pixel
with brightness in the first byte, and both are stored rotated a quarter turn,
so the file is height-wide and width-tall. The sizes are therefore exactly 2,592
and 171,930 bytes, which is a quick check that a file is what it claims to be;
decode it to a PNG and look at it before shipping it.

**The aspect ratio in `video.json` describes the raster before the scaler
rotates it** *(Master of Weapon; Time Pilot found it first)*. With a `rotation`
of 90 or 270 the shape that reaches the panel is `aspect_h:aspect_w`. A vertical
game written the intuitive way round, `3:4`, comes out landscape. A mode that
fills the Pocket's 10:9 panel is written `9:10`.

**Do not list the d-pad in `input.json`** *(Master of Weapon)*. The Pocket's
controls menu showed "Up" and three blank rows. The core reads the pad from
`cont1_key` whether or not it is listed; list only what is worth remapping.

**`pause_core` is not a reset** *(Master of Weapon and Cadash)*. It is the
Pocket's menu being open. ORed into the core's reset it holds the board in
reset for as long as the menu is up and boots the game from scratch when it
closes. Freeze the clock-enable divider instead and mask the CPU and sound
enables with the same term, so that no pulse is skipped and none fires twice
and a two-phase CPU resumes in the order it stopped; leave the dot divider
running and the picture stays up behind the menu. Note what else counts
wall-clock time while the CPU is stopped — a watchdog will expire.

**Every menu entry is a claim that the gateware does something**
*(Master of Weapon)*. The DIP bank was transcribed whole from MAME, including
Cabinet and Flip Screen, which on this board both come down to a video-chip
bit the core never implemented. Toggle each entry on hardware once and watch
for its effect; remove what has none, or what has one nobody holding a Pocket
wants.

**Copying to the SD card from macOS** *(Master of Weapon)*: use `cp -X` with
`COPYFILE_DISABLE=1`, or the card fills with `._*` AppleDouble files. If you
clean them up afterwards, name the files; a `find -delete` aimed at
`Platforms/` sweeps every other core's as well.

**Byte-enable inference:** partial-select writes like `mem[a][7:0] <= x` fail to
infer byte enables in Quartus and explode into registers. Use 2D-packed
(`logic [1:0][7:0]`) and word-buffered writes.

### 5.6 Release engineering

- **Release the bitstream you tested**, not a fresh compile of the same source.
  Quartus is not reproducible, and a rebuild is an unverified artefact.
  `tools/cut-release.sh <tag> <run-id>` pulls the bitstream from a named CI run
  and takes everything else from the working tree — which also means a
  definition-only change ships without a rebuild.
- **Never ship ROMs.** A gitignored test ROM in the package directory nearly went
  into a published zip; the release script's final check caught it. Exclude at
  the copy step *and* keep the check as a backstop.
- **Releases are immutable.** Tools track assets by tag; replacing a file leaves
  people holding a stale copy silently. Cut a new tag.
- Verify the published zip by downloading it: version, bitstream checksum, no
  ROM, expected files present.
- *(Pleiads/Phoenix)* **Anchor `.gitignore` patterns.** `pleiads/`, meant for
  the romset directory at the root, matches a directory of that name at *any*
  depth, and it swallowed the package's asset folder and both directories of
  captured reference states. CI failed or skipped for the project's first ten
  pushes as a result. Write `/pleiads/` and `/*.bin`.
- *(Master of Weapon)* **A rebuild is never byte-identical, even when the fit
  is.** The same container and the same source gave the same slack to three
  decimals on my machine and in CI, every time — and a different bitstream,
  because the framework stamps the date, the time and a random id into
  `build_id.mif` on every compile. So "CI rebuilt it and timing passed" is a
  twin of the binary you tested, not that binary. I released twins twice here;
  the first bullet of this section is still the right rule.
- *(Master of Weapon)* **Because the fit is deterministic, never push to find
  out whether timing closed.** A local compile answers the same question with
  the same numbers, and can be interrogated with `quartus_sta` afterwards.
  Eleven CI runs were spent learning what local builds would have said.
- *(Pleiads/Phoenix)* **Decide the pre-release flag from the tag**, not by
  hard-coding it. A script that always passes `--prerelease` is right until the
  first release that isn't one, and then mislabels it silently.

### 5.7 ROM distribution

A core is FPGA gateware — it cannot unzip a romset or run a script. The ROM must
be assembled on a computer. Ship an **MRA file** (the arcade standard, so
existing tools work) plus a dependency-free Python builder that reads the MAME
zip directly, checks each CRC, and verifies the finished image against a known
checksum.

MRA's `map` attribute: each digit is one byte of the output word, left to right;
the value is the 1-based byte of the input part. Verify against a known-good
reference — in MAME's `f1dreama` the even-offset ROM carries `map="10"`, which
establishes that the left digit is the first byte of the word.

### 5.8 The bench must talk to the core the way the platform does

**Cost me the most on Pleiads/Phoenix, and hid behind a green everything.**
Two games shared one core, told apart by a checksum summed over the program
region as the ROM loaded. Every bench strobed each byte's write enable for one
clock. The Pocket's `data_io` holds it for four, with address and data stable
underneath. A RAM write repeated four times is harmless, so the image always
loaded and the picture was always perfect. A sum repeated four times is four
times the sum, and matched neither game.

On hardware, then, nothing was ever recognised. One game worked because
"unrecognised" happened to fall through to it. The other ran its program on the
wrong sound board — no music, only beeps — and I spent a day improving a sound
section that was correct and had never once been selected. Every hardware
report in that time was a report about a different circuit from the one I was
fixing.

What generalises:

- **The benches were exact about the machine and approximate about the
  platform boundary.** Make the bench's loader, reset sequencing and strobes
  match the framework's real timing by default — hold lengths, gaps, the order
  things deassert — and keep the idealised version as the override, not the
  other way round.
- **Ask of every signal crossing in from the platform: is what I do with it
  idempotent?** Writes are. Counters, checksums, toggles, FIFO pushes and
  edge-triggered state are not. Count an event on the strobe's rising edge or
  an address change, never on its level.
- **A fallback that is itself a valid configuration hides the failure that
  triggers it.** If detection can fail, make failure look like failure — a
  status bit on the overlay, a refusal to start — and test the detector at
  several strobe lengths, since the framework's is a parameter someone can
  change.
- **Before fixing what the hardware does, establish which configuration the
  hardware is in.** One overlay square for "game recognised" would have ended
  this in a minute.

### 5.9 A number is a claim about a window, and a metric is a choice

The first Phoenix release went out on a measured correlation of +0.889 against
MAME. It was taken over the first four seconds of the capture. The game starts
at 3.4 s. The figure described attract mode, the bench never looked past seven
seconds, and the in-game effects were at about a sixth of their proper energy.

Then, chasing that, waveform correlation sent me after the melody for most of a
day — it collapsed to zero mid-capture — when the melody was spectrally exact
and merely out of phase (§4). And when I finally wrote the per-second spectral
check into the bench, it printed a row that could not be true: RMS 2900, band
energy 1e-23. The band-energy function had always taken a single 8192-sample
frame from the *start* of whatever window it was handed. Every "4 s window"
figure in the project had covered 0.17 s.

- State the window with the number, every time. If it does not cover the thing
  the user will hear, it is not evidence about that thing.
- §5.1 says suspect the harness when a result is shocking. Suspect it also when
  a result is *reassuring* and cheap.
- When a bench gains a new check, run it on old known-good data first. An
  impossible row there is the fastest instrument audit there is.
- Keep a metric that makes the bad version look bad. Rebuild the previously
  shipped gateware from git and measure it with the final instrument: that gave
  0.883 → 0.050, and is the only before/after worth quoting.

### 5.10 A replayed trace proves the block, not the core — and only what the trace reached

Feeding a sound block the emulator's recorded command stream is the right way
to iterate on it. Know what it leaves unproven:

- **That the core issues those commands, and that the platform selects that
  block at all.** §5.8 is what that gap looks like. Close it with a whole-core
  capture (§4): the core's own command log matched MAME's to six significant
  figures in value and time, and its audio matched the model run on those
  commands, which is the check on the wiring rather than on the filter.
- **Anything the captured session never exercised.** One of the two effect
  generators sat at its "off" code for the entire twenty-second capture. Its
  sweep constants were computed for the wrong sample rate *and* paired with the
  wrong targets, and replaying that trace forever would never have shown it.
  List which inputs a capture actually moves, and treat the rest as unverified
  in writing until a capture moves them.
- **A script that defaults to one target verifies one target.** The end-to-end
  script defaulted to one game and I reported its result as covering both.
  Loop over every target by default; make the narrow run the option.

### 5.11 "Timing met" is a statement about the constraints

Sound generators that do a burst of wide arithmetic once per sample are a
legitimate multicycle. Two ways that went wrong, in opposite directions:

- **A constraint scoped to a module does not cover a path that starts outside
  it.** Three builds in a row failed on paths that entered the audio section
  from the core — a control latch into a counter, the game-select into a rate
  constant — matching neither end of `-from audio -to audio`. Register every
  input once at the boundary of the constrained region, so that what the SDC
  describes and what exists are the same set of paths.
- **Anything you later put inside that boundary inherits the relaxation.** A
  reverb whose state machine reads block RAM on consecutive clocks, placed in
  the audio module for tidiness, would have been given eight clocks per path,
  met timing on paper, and been free to fail on hardware. It went outside, and
  the clock-domain handover that has to follow it moved out too.

The analyser can only tell you the design meets what you told it. When a region
is relaxed, write down *why everything in it qualifies*, and re-read that before
adding to it. It is the same shape of fault as §5.4 and §5.8: every tool reports
success.

### 5.12 Read the emulator's step function, not the netlist's comments

Porting MAME's discrete-sound and helper layers, the mistakes were almost all
in what I assumed a macro meant:

- `DISCRETE_SWITCH(node, enable, switch, in0, in1)` is `switch ? in1 : in0`. I
  had an amplitude select backwards, halving the level where it should double.
- `DISCRETE_NOTE` does not count at all while its preload equals its maximum,
  so that code is *silence*, not the fastest tone. Both generators sit there
  for most of a game; running them anyway put 128× too much energy above 4 kHz.
- A resistor mixer is Millman **with the feedback resistor in the denominator**.
  Leaving it out is why I concluded the netlist's final gain "could not be
  reasoned about" and fitted one instead. The fit was 1.95× short, and being a
  fit it quietly absorbed the inverted switch above as well.
- Defaults are part of the semantics: a palette normaliser's range defaults made
  every colour a fifth too dark; a tile layout's bit offsets counted from the
  MSB, mirroring every tile while 89% of pixels still matched.
- A 555 is high for (R1+R2)/(R1+2·R2), never half; and resets — of capacitors,
  of filters — are to zero, not to the resting value.

**Derive, do not fit.** A fitted constant is a place for other errors to hide,
and it has to be refitted every time one of them is found. If the emulator
computes a level from component values, so can you.

And model by frequency only what is *heard* only as frequency. A 555 clocking a
divider can be a lookup table and a phase accumulator. The oscillators upstream
that shape its control voltage cannot, when the game switches their timing
capacitor ten times a second: the emulator carries the capacitor's voltage
across the switch and a phase accumulator carries the fraction of a cycle, which
is a different waveform every time.

### 5.13 Fixed point: five ways it lies without a warning

All of these linted clean, and none produced an error anywhere.

- **A small coefficient truncates to zero and the filter never moves.** A
  1 Hz oscillator stepping 5 ppm of the way to its rail per tick computes
  `(delta * k) >> 24` as 0, forever. Keep a residue accumulator and commit only
  whole units: `acc += delta * k; v += acc >> 24; acc &= mask`. Write each step
  as two branches with a non-negative difference so the residue never needs a
  sign.
- **`a + b * c >>> 8` is `(a + b * c) >>> 8`.** Shifts bind looser than
  addition in SystemVerilog. It turned an interpolator into a differentiator,
  and the only symptom was one source missing from a mix.
- **`4096 * 1000000` overflows 32 bits** in a constant expression and goes
  negative. Use sized 64-bit literals for anything rate-like.
- **Python's `//` floors; C's `/` truncates.** They differ for negatives, and
  it was the *reference model* that was wrong. When the two disagree, neither
  is presumed innocent.
- **A task with `inout` arguments silently dropped its results** in synthesis;
  a function returning a packed `{counter, level}` did not.

And on cost: `x / 48000`, `i % 6` and `sum / voices` each infer a real divider
— one was 14,335 logic elements. Multiply by a reciprocal, and **verify the
reciprocal exhaustively over the operand's real range**, not the range you
tested: one was exact to 699,119 and wrong above it, with live values reaching
1.5 million. When DSP blocks run out and logic is spare, `DSP_BLOCK_BALANCING`
per entity moved 79 blocks' worth of multipliers to 23.

### 5.14 A module proven in another core is proven on that core's signal

The cabinet reverb was ported from cores where it has shipped for months, with
a bit-exact integer model to hold the port to. It matched on every sample and
was wrong for this board: the mix carries a DC offset, as MAME's does, and a
feedback comb has a gain of 1/(1−g) at 0 Hz. Three combs turned −2118 into
−6431 and put one sample in eight into the rails on the louder game.

Bit-exactness proves the port, not the fit. When reusing a block, measure it on
*this* core's signal for the things its original host never presented — DC,
full-scale peaks, sample rate, duty — and count samples at the rails as
routinely as you count differing pixels. The fix kept the block's sound: remove
DC from the send into the combs only and leave the dry path alone. And make
"off" provably off — the input returned sample for sample, the whole core
byte-identical to a capture taken before the feature existed — so the option
can never be the reason the default sounds different.

### 5.15 Give the user ears, and take their words literally

Publishing the simulator's output where the user could play it turned out to be
a bisection tool, not a courtesy. "In the artifacts I hear the correct music",
next to "on the Pocket it is silent and then beeps", cut the problem in half in
one sentence: the sound section was right, so the fault was in whether the
hardware ever used it. A picture did the rest — the same gateware rendered with
and without the game-select, the second being exactly what the user had
described.

That description was precise, and I had been treating reports like it as
impressions. "No intro tune, silent, then just beeps" is not "the audio is
bad"; it names which generator is absent and which is present. §8 item 9 says
to believe the report. Also *parse* it.

### 5.16 The platform's memory glue is part of the machine, and needs its own bench *(Master of Weapon)*

**Cost me the first hardware run, and would have cost a week without a sibling
core to diff against.** The whole-machine bench answered the CPUs from plain
arrays after a settable delay. It booted, drew the attract mode and ran for
minutes. On the Pocket: a black screen, frame counter running.

The Pocket's loader sends a byte every eight clocks and *cannot be told to
wait*. The download path held one pending word; when an SDRAM write sat behind
a refresh, the even byte of the next word landed in the high half of the word
still waiting, and what finally went out was this word's low byte under the
next word's high one. The image came out peppered with bad words. §5.8 is the
same family — the bench idealised the platform boundary — but this is the
half it does not say: **a client that cannot stall needs a FIFO, and the bench
has to push at the client's real rate.** My first real-memory run passed,
because I had guessed twelve clocks a byte. At eight it crashed exactly as the
hardware did, down to the number on the diagnostic panel.

What generalises:

- **Keep two whole-machine benches.** The fast one with ideal memories, for the
  game; and one with the real memory module, the real SDRAM controller and SRAM
  port, and behavioural chips beyond the pins, with the image sent through the
  download port. The second is slow. It is also the only simulation in which
  the arbitration, the download and the refresh exist at all.
- **Everything between the core's ports and the pins is unverified until that
  second bench exists.** Say so in the README rather than "the machine boots".
- **When a working sibling core exists, diff the platform layer against it
  before theorising.** The fault, the fix and a paragraph explaining both were
  sitting in the Cadash core's memory module. I found them after three wrong
  theories and one remark from the user. `diff` first.
- **A family of cores shares its bugs.** Cadash had inherited its menu-reset
  bug from this core's `core_top`, and this core had been cut from Cadash's
  memory module before its download fix. When you fix something in a file that
  was copied, grep the siblings for the same line the same day.

### 5.17 A shared port's acknowledge must say whose it is *(Master of Weapon)*

Tilemap RAM was one SRAM port shared by the 68000 and the line renderer. The
port answered with a single ack pulse, decided the clock *before* it was
visible: it acknowledged only if the request still standing then was the one
it had begun. The arbiter routed that pulse by the request lines of the clock
it *arrived* in. When the renderer raised its request on the very clock a CPU
access was acknowledged, the renderer took the ack, and the CPU's word as its
tile code, and drew sixteen pixels of the wrong tile.

It needs the CPU writing tilemaps while lines are being built, so: never on the
title screen, only in play, on one raster line at a time, sliding along it, and
gone when the menu paused the CPU. That last observation, from the user, was
the whole diagnosis — it said "caused by CPU activity" in one sentence.

- **Route a response by who owned the resource when the response was decided**,
  not by who is asking when it arrives. Latch the owner at grant. An untagged
  pulse on a shared port is a race with a very small window, which is the worst
  kind: rare enough to pass every bench and common enough to see on a screen.
- **Count the coincidence in the bench.** A one-line checker — ack high, the
  other requester's line rising — found the race inside 200 frames of the
  quietest screen in the game. Add one for every shared port; zero is not the
  expected answer, surviving it is.
- **"It stops when X is paused" is a bisection.** Give the user a way to freeze
  half the machine (the menu pause does it for free) and ask what changes.

### 5.18 Prefer structures that can only be synthesised one way *(Master of Weapon)*

The two line buffers were `logic [11:0] linebuf [0:1][0:319]` — a
two-dimensional, non-power-of-two array, which became 7,000 flops, a 640-way
write decode and a read multiplexer that needed a multicycle to close. Every
bench drew it correctly. Timing analysis passed it. On the panel one of the two
buffers lost its writes in three 32-pixel blocks of the line, and stale pixels
from lines drawn earlier showed through on alternate raster lines.

I never proved why. The replacement was one 1024-entry RAM addressed
`{buffer, x}`, which Quartus infers as a block RAM and which fixed it outright.

- **A simulator indexes an array exactly as written; a synthesiser has to
  flatten it.** Give it nothing to decide: one dimension, a power of two deep,
  addresses built by concatenation. It is usually smaller and faster as well —
  this removed the slowest path in the video output.
- **When hardware and simulation disagree and the analyser is clean, replace
  the structure whose synthesis is an interpretation**, before instrumenting
  it. And write down that the root cause is unproven. A commit message that
  claims more than was shown is a trap for the next fault that looks similar.
- **A regular test pattern turns "garbled" into coordinates.** Two photographs
  of gameplay supported three different theories. The game's own service-mode
  crosshatch showed in one frame that the damage was in blocks 3, 6 and 9 of
  the line, in one buffer, and was *stale data* rather than shifted data —
  the white bar's pixels standing as comb teeth in cells the bar never touches.
  Ask for the test pattern first.

### 5.19 An instrument must survive the event it measures *(Master of Weapon)*

The line renderer reported how many clocks its slowest line took. It restarted
at every line start whether or not it had finished — and the restart reset the
counter. So a line that overran, the one case the number existed for, threw its
count away: the panel read a comfortable 321 over a striped picture, and 6,143
on another day. I built a theory on those two numbers and a fix on the theory.

- **A budget counter must saturate or latch on the miss**, not be cleared by
  it. Make "missed the deadline" its own sticky, unmistakable reading (all
  ones), and keep the worst case since reset, not since the last frame.
- **A deadline-driven stage should say when it misses**, not show what it has.
  An unfinished line went on screen looking like a rendering bug.
- Same family as §5.1: check the instrument. But the specific habit is new —
  *ask what the instrument does at the moment of the failure it is there to
  catch.*

### 5.20 Interface timing is a balance, and the report you did not read is the one that matters *(Master of Weapon)*

CI failed eleven times on setup slack. I spent most of them pipelining
arithmetic in the sprite engine, because that is where the failing paths had
been at the start. By the end every violated path was the same one: the SDRAM
data pins into the controller's capture register. The logic had been closing
for days.

- **Re-read the worst paths after every fix.** The list changes character, and
  the summary line does not tell you.
- **A source-synchronous capture is a dial, not a path.** Setup on the SDRAM
  read gets `2T - shift` and hold gets `T - shift`: a nanosecond off the clock
  phase is a nanosecond onto one and off the other. Measure both slacks at two
  phase values, at the corner where each is worst (slow for setup, *fast* for
  hold), solve for where they meet, and round to a step the PLL can make. I
  moved it on a setup measurement alone, reasoned that hold was safe, and
  bought a hold violation and a wasted build. A phase value inherited from
  another core is a starting point; the board is the same but the fit is not.
- **Make the report script emit every corner it will ever be asked about.**
  Mine matched the cold corner with `*0C*`, which also matches the *fast* 0C
  model; that ran second and overwrote the file with paths that were never the
  problem. It reported hold on the slow model only, where hold is never worst.
  And CI uploaded one of the six files the script wrote.
- **Fail the build on an ignored constraint.** A multicycle aimed at a register
  that Quartus had merged into a block RAM's output matched nothing, was
  dropped with a warning nobody reads (332174 / 332049), and sat in the SDC for
  weeks claiming a relaxation the analyser never granted. Grep the fit and
  timing reports for those two warnings against your own SDC file and refuse
  the build. It is the converse of §5.11: there, the constraint covered more
  than you meant; here, it covered nothing.

### 5.21 A bring-up panel, designed to be read by a person *(Master of Weapon)*

§8 item 7 says to add the overlay early. This is what it needed once someone
was reading it to me square by square, off a picture the scaler had rotated.

- **Open with a fixed marker.** Row 0 begins `1010 1010`. The first reading
  from hardware could not be decoded, because the reader had reasonably skipped
  the frame counter and I had assumed he had not; a contradiction in one bit
  (an input tied high reading low) was the only reason I noticed. Eight squares
  buy a reading that checks its own alignment.
- **Check the widths add up to the bus.** A concatenation narrower than the
  status word zero-extends on the left and shifts every field, silently.
- **Report the first fault, not the current state.** A snapshot taken when the
  watchdog expired said where the CPU happened to be. A capture that freezes on
  the first exception vector a healthy run never fetches, with the two code
  addresses before it, says where it went wrong — and whether that address is
  the same on every power-up separates a logic fault from a marginal memory.
  **Prove the detector quiet on a healthy boot and firing on a sick one in
  simulation before it costs a flash cycle.**
- **Self-test every external memory before the core leaves reset**: two
  patterns that are each other's byte swap and nibble inverse, so that a stuck
  bit, a swapped lane and a dead bus read differently from a pass and from each
  other. Give it a timeout, or a port that never acknowledges holds the core in
  reset and "dead" looks exactly like "wrong".
- **Reading back the first word of each ROM region proves the path, not the
  image.** All three were right while the image behind them was peppered with
  bad words. If the load can corrupt, show a checksum of the whole image.
- **Count things that should happen often.** Watchdog kicks since reset turned
  "the CPU is not halted" into "the CPU dies within three kicks of boot".
- Leave all of it in the gateware for release, and take it off the menu.

### 5.22 When the fix changes nothing, the theory is dead — say so *(Master of Weapon)*

I fixed the striped picture twice before I fixed it. The first fix (fetch
graphics in bursts, so lines finish in time) was well reasoned, verified in
simulation, improved a real number — and the user's report was "still the
same". That sentence is worth more than the reasoning: a change that large to
the fetch path, with *no* change to the symptom, means the symptom does not
come from the fetch path. I had also presented a simulation-versus-hardware
difference as evidence without checking what the bench modelled; it modelled
graphics latency as a flat number with no contention, so the difference proved
nothing.

- **Before citing a sim-versus-hardware gap as evidence, read what the bench
  models for that quantity.** If it is an idealisation, the gap is expected.
- **State the prediction before the build**: "if I am right, the stripes go and
  the panel reads under 6,328; if the panel reads a number and the stripes
  stay, this theory is wrong." Then the report decides it in one line.
- **Correct yourself in the open, at once, with the reason.** Four times here
  I told the user something a later measurement overturned — a graphics
  read-back I had computed from the wrong offset, an SRAM theory, a timing
  exception, the overrun. Each correction cost a paragraph. Building on any of
  them would have cost a day.
- **Derive expected values from the constants the RTL uses**, not from memory.
  The "wrong" read-back was correct; my expectation used a region base that was
  never in the design.

---

## 6. Time Pilot: what changes

From `mame -listxml timeplt`:

| | Xenophobe | Time Pilot |
|---|---|---|
| Main CPU | 68000 @ 7.72 MHz | **Z80 @ 3.072 MHz** |
| Sound CPU | 68000 @ 8 MHz | **Z80 @ 1.789772 MHz** |
| Sound | software DAC (10-bit) | **2× AY-3-8910A @ 1.789772 MHz** + RC filters |
| Display | 512×480 | **256×224, rotated 90°**, 60 Hz |
| ROM total | 832 KB | **53 KB** |

**The big simplification: 53 KB fits entirely in block RAM.** The Cyclone V
5CEBA4 has ~393 KB. That removes SDRAM completely — and with it the arbiter, the
fetch latency, the sprite bandwidth budget, and the sound-CPU starvation that
between them accounted for most of the Xenophobe effort. Load everything into
BRAM at startup and every access is single-cycle and deterministic. **Do this.**

What to expect instead:

- **Z80 core**: T80 is the standard choice, widely used and well proven.
- **AY-3-8910**: use a proven implementation (jt49 or similar) rather than
  writing one. Real chips, so tempo comes from the chip's own clock, not CPU
  speed — §5.3 does not apply, but §5.4 very much does: the AY outputs still
  cross into the Pocket's audio domain.
- **PROMs**: `timeplt.b4`/`b5` (32 bytes) are colour PROMs, `e9`/`e12` (256
  bytes) lookup PROMs. Palette and tile/sprite colour resolution go through
  these — model them in the reference renderer first.
- **Rotation**: the Pocket handles rotated displays, but confirm the orientation
  and scaling early. It affects how you compare against MAME snapshots.
- **RC filters**: MAME models them explicitly. Read the coefficients from the
  driver rather than approximating — Xenophobe's three one-pole sections stood in
  for a five-pole design and left the output measurably darker in the passband
  and leakier above it.

Suggested order: ROM builder → reference renderer (with PROM colour resolution)
→ tilemap → sprites → frozen-state gate → Z80 + memory map → AY sound → platform
integration → hardware.

---

## 7. Worth copying from the Xenophobe repo

| Path | What it does |
|---|---|
| `tools/render_model.py` | Reference renderer + diff against MAME snapshot |
| `tools/diff_frames.py` | Pixel diff with per-cell hotspots and a visual diff image |
| `tools/regress_video.sh` | Runs every frozen state through the RTL and checks for zero differences |
| `tools/mra_build.py` | MRA interpreter; builds the ROM from a MAME zip, CRC-checked |
| `tools/cut-release.sh` | Publishes a release from a named CI run's bitstream |
| `tools/fetch_build.sh` | Stages and verifies a CI build before replacing an SD package |
| `sim/run_video.sh` | Frozen-state video bench (~30 s) |
| `sim/tb_audio.sv` | Measures the Pocket audio filter chain's gain |
| `.github/workflows/compile.yml` | Quartus in Docker, artifact upload, tag-triggered release |
| `target/pocket/core_top.sv` | APF integration, diagnostic overlay, audio CDC |

And from the Pleiads / Phoenix repo:

| Path | What it does |
|---|---|
| `tools/bus_trace.lua`, `tools/diff_bus.py`, `tools/check_cycles.py` | CPU held to MAME per bus transaction and per instruction cycle count |
| `sim/tb_system.cpp` | One bench, three modes: bus trace, end-to-end frames, and whole-core audio with a command log; loads the ROM with the Pocket's real strobe timing |
| `tools/compare_audio.py` | Peak, RMS, correlation, and band energy per second over the whole capture |
| `tools/plot_audio.py` | Waveform over spectrogram as a PNG, no numpy |
| `tools/gen_recip.py --check` | Reciprocal-multiply constants, verified exhaustively over the real operand range |
| `tools/reverb_model.py`, `sim/run_reverb.sh` | Bit-exact model of the shared cabinet reverb, and the bench that holds the RTL to it and counts samples at the rails |
| `tools/make_report.py` | The page the user watches: every state's picture and diff, audio players, the metric used for each |
| `rtl/i8085.sv` | An 8085 written against MAME's cycle table, with the bus-trace bench as its test |

The platform directory (`platform/pocket/`) and the APF framework transfer
wholesale; only `core_top.sv` and the `rtl/` contents are game-specific.

---

## 8. If I were starting again

1. Read MAME's driver properly and write `docs/hardware.md` first.
2. Build the ROM path and CRC-check it.
3. Get the reference renderer pixel-perfect before writing video RTL.
4. Put everything in BRAM if it fits. It removes entire categories of bugs.
5. Audit clock-domain crossings before integration, not after.
6. Find out what paces the audio, and verify its rate against MAME early.
7. Add the diagnostic overlay before you think you need it.
8. Verify anything verifiable before spending a 20-minute build.
9. When a user reports something you cannot reproduce, believe the report and
   distrust the theory.

Added after Pleiads / Phoenix:

10. Make the bench deliver the ROM, reset and strobes exactly as the platform
    does, and ask of everything crossing that boundary whether it is
    idempotent. (§5.8)
11. If the core can be in more than one configuration, put which one on the
    overlay, and never let "unrecognised" fall through to something that works.
12. Capture audio in play, judge it across the whole capture, and pick the
    metric to the signal: correlation if phase-locked, band energy if not.
13. State the window with every number, and audit a new instrument on old data
    before believing it.
14. Derive levels and time constants from the emulator's arithmetic; a fitted
    constant hides the next bug.
15. Register every input at the edge of a relaxed timing region, and keep
    everything that is not paced like the rest of it outside.
16. List what each captured stimulus actually exercises, and write down the
    rest as unverified.
17. Publish the simulator's output where the user can hear it next to the
    hardware. It bisects.

Added after Master of Weapon:

18. Build the second whole-machine bench — real memory glue, behavioural
    chips, the image pushed at the loader's real rate — before the first
    flash, and call everything beyond the core's ports unverified until it
    exists. (§5.16)
19. If a sibling core works on hardware, diff the platform layer against it
    before forming a theory; and when you fix a copied file, grep the siblings.
20. Latch the owner of every shared port at grant and route the ack by it;
    count request/ack coincidences in the bench. (§5.17)
21. One-dimensional, power-of-two RAMs. Nothing a synthesiser has to interpret.
    (§5.18)
22. Every budget counter saturates on a miss and survives the restart that the
    miss causes. (§5.19)
23. Never push to learn whether timing closed; re-read the worst paths after
    every fix; report setup at the slow corners and hold at the fast ones; fail
    the build on an ignored constraint. (§5.20)
24. The panel opens with a marker, captures the first fault rather than the
    current state, and self-tests the memories — and its detectors are proven
    in simulation on a healthy run and a sick one. (§5.21)
25. Ask for the game's own test pattern before asking for a photograph of
    gameplay.
26. Say what each build is predicted to change, and when it changes nothing,
    drop the theory rather than extend it. (§5.22)
