// Sound-board bench driver: replay MAME's own CIU traffic into the core's
// sound board and record what it plays.
//
//   tb_sound <rom.rom> <ciu.txt> -secs 8 -o out.wav [-mix name]
//
// Writes four WAVs so the mix can be picked apart: the FM alone, the three
// SSG channels summed, jt03's own combined output, and the core's mix as
// masterw_core builds it.  tools/compare_audio.py holds each against MAME's
// recording of the same seconds.

#include "Vtb_sound_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const int SND_DIV = 2000;            // 96 MHz / 48 kHz
static const int CPU_MUL = 8;               // 96 MHz / 12 MHz: one 68000 cycle

struct Event {
    long long cyc;
    bool write;
    bool comm;
    int  data;
};

static void write_wav(const std::string &path, const std::vector<int16_t> &s) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    uint32_t data = (uint32_t)(s.size() * 2), riff = 36 + data;
    uint16_t one = 1, chans = 1, bits = 16, align = 2;
    uint32_t byterate = 48000 * 2, fmtlen = 16, srate = 48000;
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
    std::string rom, log, out = "core";
    double secs = 8.0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-secs") secs = atof(argv[++i]);
        else if (a == "-o") out = argv[++i];
        else if (a[0] != '+') { if (rom.empty()) rom = a; else log = a; }
    }
    if (rom.empty() || log.empty()) {
        fprintf(stderr, "usage: tb_sound <rom.rom> <ciu.txt> [-secs n] [-o prefix]\n");
        return 2;
    }

    std::vector<uint8_t> srom(65536);
    {
        FILE *f = fopen(rom.c_str(), "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", rom.c_str()); return 2; }
        fseek(f, 0x080000, SEEK_SET);
        if (fread(srom.data(), 1, 65536, f) != 65536) {
            fprintf(stderr, "%s is too short\n", rom.c_str()); return 2;
        }
        fclose(f);
    }

    std::vector<Event> ev;
    {
        FILE *f = fopen(log.c_str(), "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", log.c_str()); return 2; }
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (line[0] == '#') continue;
            long long c; char rw[8], port[8]; unsigned d;
            if (sscanf(line, "%lld %7s %7s %x", &c, rw, port, &d) == 4)
                ev.push_back({c, rw[0] == 'W', strcmp(port, "comm") == 0, (int)d});
        }
        fclose(f);
    }
    printf("replaying %zu CIU accesses over %.1f s\n", ev.size(), secs);

    auto *dut = new Vtb_sound_top;
    long long t = 0;
    auto tick = [&]() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); t++; };

    dut->reset = 1;
    dut->dl_we = 0; dut->lat_rom = 8;
    dut->m_port_wr = dut->m_comm_wr = dut->m_comm_rd = 0;
    for (int i = 0; i < 16; i++) tick();
    for (int i = 0; i < 65536; i++) {
        dut->dl_we = 1; dut->dl_addr = i; dut->dl_data = srom[i];
        tick();
    }
    dut->dl_we = 0;
    for (int i = 0; i < 16; i++) tick();
    long long t0 = t;
    dut->reset = 0;

    std::vector<int16_t> fm, psg, comb, mix;
    size_t next = 0;
    long long total = (long long)(secs * 96000000.0);
    int div = 0;

    while (t - t0 < total) {
        // the CIU strobes are one clock long, at the 68000 cycle MAME saw
        dut->m_port_wr = dut->m_comm_wr = dut->m_comm_rd = 0;
        if (next < ev.size() && (t - t0) >= ev[next].cyc * CPU_MUL) {
            const Event &e = ev[next++];
            dut->m_din = e.data;
            if (e.write) { if (e.comm) dut->m_comm_wr = 1; else dut->m_port_wr = 1; }
            else if (e.comm) dut->m_comm_rd = 1;
        }
        tick();
        if (++div >= SND_DIV) {
            div = 0;
            int16_t f = (int16_t)dut->fm_snd;
            int p = (int)dut->psg_a + (int)dut->psg_b + (int)dut->psg_c;   // 0..765
            fm.push_back(f);
            // the three channels summed at the scale masterw_core uses --
            // unipolar, as jt49 delivers them, with no centring
            psg.push_back((int16_t)(p * 32));
            comb.push_back((int16_t)dut->ym_snd);
            long long m = ((long long)f * 205 + (long long)p * 32 * 64) >> 8;
            if (m > 32767) m = 32767;
            if (m < -32768) m = -32768;
            mix.push_back((int16_t)m);
        }
    }

    write_wav(out + "_fm.wav", fm);
    write_wav(out + "_psg.wav", psg);
    write_wav(out + "_jt03.wav", comb);
    write_wav(out + "_mix.wav", mix);
    printf("wrote %s_{fm,psg,jt03,mix}.wav, %zu samples each\n", out.c_str(), fm.size());
    delete dut;
    return 0;
}
