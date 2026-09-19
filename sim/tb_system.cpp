// Whole-machine bench driver: boot the real program on both CPUs and capture
// the frames it draws.
//
//   tb_system <rom.rom> -frames N [-snap f1,f2,...] [-o dir] [-wav out.wav]
//             [-coin f] [-start f]
//
// Writes each requested frame as 320x224 RGB (the same layout
// tools/pngio.py writes), so tools/diff_rgb.py can compare it with the frame
// MAME produced at the same moment.
//
// This is the slow bench: a frame is 1.6 million clocks, so a few hundred
// frames is minutes, not seconds.  Use it for questions about the machine as
// a whole -- does it boot, does the interrupt handler run, does the sound CPU
// answer -- and sim/run_video.sh for anything about the picture itself.

#include "Vtb_system_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

static const int W = 320, H = 224;
static const int IMAGE_LEN = 0x190000;

static void write_wav(const std::string &path, const std::vector<int16_t> &s, int rate) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    uint32_t data = (uint32_t)(s.size() * 2), riff = 36 + data;
    uint16_t one = 1, chans = 1, bits = 16, align = 2;
    uint32_t byterate = (uint32_t)rate * 2, fmtlen = 16, srate = (uint32_t)rate;
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmtlen, 4, 1, f); fwrite(&one, 2, 1, f); fwrite(&chans, 2, 1, f);
    fwrite(&srate, 4, 1, f); fwrite(&byterate, 4, 1, f);
    fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
    fwrite(s.data(), 2, s.size(), f);
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string rom, outdir = "artifacts/system", wav;
    int frames = 60, coin = -1, start = -1;
    int lat_rom = 8, lat_gfx = 5, lat_vram = 6;
    // clocks per downloaded byte: 1 for the ideal-memory bench, a dozen for the
    // real SDRAM path, which is about what the Pocket's loader leaves it
    int dlgap = 1;
    std::set<int> snaps;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return std::string(argv[++i]); };
        if (a == "-frames") frames = atoi(next().c_str());
        else if (a == "-o") outdir = next();
        else if (a == "-wav") wav = next();
        else if (a == "-coin") coin = atoi(next().c_str());
        else if (a == "-start") start = atoi(next().c_str());
        else if (a == "-latrom") lat_rom = atoi(next().c_str());
        else if (a == "-latgfx") lat_gfx = atoi(next().c_str());
        else if (a == "-latvram") lat_vram = atoi(next().c_str());
        else if (a == "-dlgap") dlgap = atoi(next().c_str());
        else if (a == "-snap") {
            std::string s = next();
            size_t p = 0;
            while (p < s.size()) {
                size_t c = s.find(',', p);
                if (c == std::string::npos) c = s.size();
                snaps.insert(atoi(s.substr(p, c - p).c_str()));
                p = c + 1;
            }
        } else if (a[0] != '+' && rom.empty()) rom = a;
    }
    if (rom.empty()) { fprintf(stderr, "usage: tb_system <rom.rom> ...\n"); return 2; }

    std::vector<uint8_t> image(IMAGE_LEN);
    {
        FILE *f = fopen(rom.c_str(), "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", rom.c_str()); return 2; }
        size_t n = fread(image.data(), 1, IMAGE_LEN, f);
        fclose(f);
        if (n != (size_t)IMAGE_LEN) {
            fprintf(stderr, "%s is %zu bytes, expected %d\n", rom.c_str(), n, IMAGE_LEN);
            return 2;
        }
    }

    auto *dut = new Vtb_system_top;
    uint64_t t = 0;
    auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); t++; };

    dut->reset = 1;
    dut->dl_we = 0;
    dut->lat_rom = lat_rom; dut->lat_gfx = lat_gfx; dut->lat_vram = lat_vram;
    // every input released, every DIP at its factory setting (masterw.mra)
    dut->dswa = 0xff; dut->dswb = 0xff;
    dut->in0 = 0xff; dut->in1 = 0xff; dut->in2 = 0xff;
    for (int i = 0; i < 16; i++) tick();
    // the real SDRAM needs its power-up sequence before it takes a write
    if (dlgap > 1) for (int i = 0; i < 20000; i++) tick();

    for (int i = 0; i < IMAGE_LEN; i++) {
        dut->dl_we = 1; dut->dl_addr = i; dut->dl_data = image[i];
        tick();
        if (dlgap > 1) { dut->dl_we = 0; for (int g = 1; g < dlgap; g++) tick(); }
    }
    dut->dl_we = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->reset = 0;

    std::vector<uint8_t> frame(W * H * 3, 0);
    std::vector<int16_t> audio;
    int px = 0, frame_no = 0, last_vpos = dut->vpos;
    bool in_vblank = true;
    int watchdogs = 0, snapped = 0;
    uint64_t audio_div = 0;
    const uint64_t AUDIO_DIV = 96000000ull / 48000ull;   // 48 kHz
    unsigned worst_spr = 0, worst_ren = 0;

    // The colour comes out of the palette one clock after the index, so a
    // pixel is read the clock after its dot enable -- which is where clk_vid
    // samples it on the panel too.
    bool cap = false;
    while (frame_no <= frames) {
        bool want = dut->pix_ce && dut->de;
        tick();
        if (dut->watchdog_reset) watchdogs++;
        if (cap) {
            if (px < W * H) {
                uint32_t c = dut->rgb;
                frame[3 * px + 0] = (c >> 16) & 0xff;
                frame[3 * px + 1] = (c >> 8) & 0xff;
                frame[3 * px + 2] = c & 0xff;
                px++;
            }
        }
        cap = want;
        if ((int)dut->vpos != last_vpos) {
            last_vpos = dut->vpos;
            if (last_vpos == 239) {
                // sampled before the top of vblank clears the line-render
                // counter for the next frame
                if (dut->ren_cycles > worst_ren) worst_ren = dut->ren_cycles;
            }
            if (last_vpos == 240 && !in_vblank) {
                in_vblank = true;
                frame_no++;
                if (dut->spr_cycles > worst_spr) worst_spr = dut->spr_cycles;
                if (snaps.count(frame_no)) {
                    char path[512];
                    snprintf(path, sizeof(path), "%s/%04d.rgb", outdir.c_str(), frame_no);
                    FILE *f = fopen(path, "wb");
                    if (f) { fwrite(frame.data(), 1, frame.size(), f); fclose(f); snapped++; }
                }
                px = 0;
                // inputs, driven where the probes drive MAME's
                if (coin >= 0) dut->in2 = (frame_no >= coin && frame_no < coin + 10)
                                          ? 0xfb : 0xff;   // coin 1 is bit 2
                if (start >= 0 && frame_no >= start && frame_no < start + 10)
                    dut->in2 = 0xbf;                        // start 1 is bit 6
            } else if (last_vpos == 16) {
                in_vblank = false;
            }
        }
        if (!wav.empty() && ++audio_div >= AUDIO_DIV) {
            audio_div = 0;
            audio.push_back((int16_t)dut->snd);
        }
    }

    if (!wav.empty()) write_wav(wav, audio, 48000);
    printf("%d frames, %d snapshots, watchdog resets %d, halted %d, "
           "worst sprite pass %u, worst line %u\n",
           frames, snapped, watchdogs, (int)dut->dbg_halted, worst_spr, worst_ren);
    delete dut;
    return 0;
}
