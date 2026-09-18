// Frozen-state video bench driver.
//
//   tb_video <rom.rom> <state.bin> [more states...] [-o out.idx]
//
// Loads a dumped MAME frame into the RTL and renders it, writing the 320x224
// palette indices the chip produced.  tools/diff_index.py compares them with
// tools/vcu_model.py, which is pixel-identical to MAME.
//
// The frame MAME shows in dump N is built from the tilemaps in dump N-1 and a
// framebuffer painted at the vblank of dump N-2 (see tools/render_model.py).
// So the states are given oldest first: all but the last paint the
// framebuffer in turn, and the last supplies the tilemaps, scroll and control
// registers.  That is the order the board works in too -- the 68000 rewrites
// VRAM in its vblank interrupt, after the chip has painted the sprites.
//
// Replay frames run with the raster ticking every clock, held while the
// sprite engine is working so that vblank lasts exactly as long as the
// sprites need.  The frame under test runs at the real rate of one dot in
// fourteen, so the line renderer's budget is the real one and the bench can
// say whether it was met.

#include "Vtb_video_top.h"
#include "verilated.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const int W = 320, H = 224;
static const int GFX_BASE = 0x090000, GFX_LEN = 0x100000;
static const int DOT_DIV = 14;          // core clocks per dot

struct State {
    int frame = 0;
    bool full = false;
    std::vector<uint16_t> ctrl, vram, spr, scr, pal;
};

static bool read_state(const char *path, State &s) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
    char magic[4];
    uint32_t ver, frame;
    if (fread(magic, 1, 4, f) != 4 || fread(&ver, 4, 1, f) != 1 ||
        fread(&frame, 4, 1, f) != 1) { fclose(f); return false; }
    s.full = memcmp(magic, "MWST", 4) == 0;
    if (!s.full && memcmp(magic, "MWSL", 4) != 0) {
        fprintf(stderr, "%s: not a state dump\n", path); fclose(f); return false;
    }
    s.frame = (int)frame;
    auto rd = [&](std::vector<uint16_t> &v, size_t n) {
        v.resize(n);
        return fread(v.data(), 2, n, f) == n;
    };
    bool ok = rd(s.ctrl, 16);
    if (s.full) {
        ok &= rd(s.vram, 32768);
        ok &= rd(s.spr, 3264);
        ok &= rd(s.scr, 1024);
        ok &= rd(s.pal, 4096);
    } else {
        ok &= rd(s.spr, 3264);
    }
    fclose(f);
    if (!ok) fprintf(stderr, "%s: short read\n", path);
    return ok;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> args;
    std::string out = "frame.idx";
    int lat_vram = 6, lat_gfx = 5;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-o" && i + 1 < argc) out = argv[++i];
        else if (a == "-latvram" && i + 1 < argc) lat_vram = atoi(argv[++i]);
        else if (a == "-latgfx" && i + 1 < argc) lat_gfx = atoi(argv[++i]);
        else if (a[0] != '+') args.push_back(a);
    }
    if (args.size() < 2) {
        fprintf(stderr, "usage: tb_video <rom.rom> <state.bin> [...]\n");
        return 2;
    }

    // graphics from the ROM image, as 32-bit big-endian words
    std::vector<uint32_t> gfx(GFX_LEN / 4);
    {
        FILE *f = fopen(args[0].c_str(), "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", args[0].c_str()); return 2; }
        fseek(f, GFX_BASE, SEEK_SET);
        std::vector<uint8_t> raw(GFX_LEN);
        if (fread(raw.data(), 1, GFX_LEN, f) != (size_t)GFX_LEN) {
            fprintf(stderr, "%s is too short\n", args[0].c_str()); return 2;
        }
        fclose(f);
        for (size_t i = 0; i < gfx.size(); i++)
            gfx[i] = ((uint32_t)raw[4*i] << 24) | ((uint32_t)raw[4*i+1] << 16) |
                     ((uint32_t)raw[4*i+2] << 8) | raw[4*i+3];
    }

    std::vector<State> states;
    for (size_t i = 1; i < args.size(); i++) {
        State s;
        if (!read_state(args[i].c_str(), s)) return 2;
        states.push_back(std::move(s));
    }
    const State &tiles = states.back();
    if (!tiles.full) {
        fprintf(stderr, "the last state must be a full dump: it supplies the tilemaps\n");
        return 2;
    }

    auto *dut = new Vtb_video_top;
    uint64_t t = 0;
    auto tick = [&](int pix) {
        dut->pix_ce = pix;
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        t++;
    };
    // the raster ticks every clock, but never while the sprite engine is
    // working, so a replay frame is as short as it can be without cutting the
    // sprite pass short
    auto tick_fast = [&]() { tick(dut->spr_busy ? 0 : 1); };
    auto tick_real = [&]() { tick((t % DOT_DIV) == 0); };

    dut->reset = 1; dut->pix_ce = 0;
    dut->ld_we = 0; dut->vram_we = 0; dut->gfx_we = 0;
    dut->vram_lat = lat_vram; dut->gfx_lat = lat_gfx;
    for (int i = 0; i < 8; i++) tick(0);
    dut->reset = 0;

    for (size_t i = 0; i < gfx.size(); i++) {
        dut->gfx_we = 1; dut->gfx_waddr = i; dut->gfx_wdata = gfx[i];
        tick(0);
    }
    dut->gfx_we = 0;

    auto load_block = [&](int sel, const std::vector<uint16_t> &v) {
        for (size_t i = 0; i < v.size(); i++) {
            dut->ld_we = 1; dut->ld_sel = sel; dut->ld_addr = i; dut->ld_data = v[i];
            tick(0);
        }
        dut->ld_we = 0;
        tick(0);
    };
    auto load_vram = [&](const std::vector<uint16_t> &v) {
        for (size_t i = 0; i < v.size(); i++) {
            dut->vram_we = 1; dut->vram_waddr = i; dut->vram_wdata = v[i];
            tick(0);
        }
        dut->vram_we = 0;
        tick(0);
    };

    // run until the raster enters `want`
    auto run_to = [&](int want) {
        int prev = dut->vpos;
        for (uint64_t guard = 0; guard < 40000000ull; guard++) {
            tick_fast();
            if (dut->vpos != prev) {
                prev = dut->vpos;
                if (prev == want) return true;
            }
        }
        fprintf(stderr, "raster never reached line %d\n", want);
        return false;
    };

    // Replay.  Sprite RAM and the control registers are loaded during the
    // visible part of the frame, before the vblank that paints them, which is
    // where the 68000 writes them.
    // every state but the last two: the last but one is painted below, as
    // part of the frame under test
    for (size_t i = 0; i + 2 < states.size(); i++) {
        if (!run_to(200)) return 1;
        load_block(0, states[i].spr);
        load_block(2, states[i].ctrl);
        if (!run_to(1)) return 1;                   // through the vblank
        while (dut->spr_busy) tick(0);
    }

    // the frame under test
    if (!run_to(200)) return 1;
    const State &sprites = states[states.size() >= 2 ? states.size() - 2 : 0];
    load_block(0, sprites.spr);
    load_block(2, sprites.ctrl);
    if (!run_to(1)) return 1;
    while (dut->spr_busy) tick(0);

    // the tilemaps the beam will actually read, written where the 68000's
    // vblank interrupt would have written them
    load_vram(tiles.vram);
    load_block(1, tiles.scr);
    load_block(2, tiles.ctrl);

    // one whole frame at the real dot rate
    std::vector<uint16_t> idx(W * H, 0);
    int captured = 0;
    for (uint64_t guard = 0; guard < 40000000ull && captured < W * H; guard++) {
        bool ce = (t % DOT_DIV) == 0;
        tick_real();
        if (ce && dut->pix_de && captured < W * H) idx[captured++] = dut->pix_index;
    }

    if (captured != W * H) {
        fprintf(stderr, "only captured %d of %d pixels\n", captured, W * H);
        return 1;
    }

    FILE *f = fopen(out.c_str(), "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", out.c_str()); return 2; }
    fwrite(idx.data(), 2, idx.size(), f);
    fclose(f);

    unsigned spr = dut->spr_cycles, ren = dut->ren_cycles;
    printf("sprites %6u/183500 clocks, worst line %5u/6328", spr, ren);
    if (spr > 183500 || ren > 6328) printf("  OVER BUDGET");
    printf("\n");
    delete dut;
    return 0;
}
