"""A model of the Taito TC0180VCU, written from MAME's implementation.

This is the executable spec the RTL is written against: everything the video
hardware does to turn VRAM, sprite RAM, the control registers and the palette
into a frame lives here, in the order MAME does it, and
tools/render_model.py checks it against MAME frame by frame.

Screen geometry throughout: the visible window is x 0..319, y 16..239, and
every buffer here is 320x224 with row 0 meaning screen line 16 -- the same
window MAME clips the framebuffer to, and the same one screen:pixels()
returns.
"""

VIS_X0, VIS_X1 = 0, 319
VIS_Y0, VIS_Y1 = 16, 239
W, H = VIS_X1 - VIS_X0 + 1, VIS_Y1 - VIS_Y0 + 1

# Colour bases for Master of Weapon (taito_b.cpp, masterw machine config).
TX_BASE, FB_BASE, FG_BASE, BG_BASE = 0x00, 0x10, 0x20, 0x30

SPRITE_SLOTS = 0x1980 // 16          # 408


class Gfx:
    """The graphics ROM, as 4bpp pixels.

    The image holds one 32-bit big-endian word per 8-pixel row (see
    masterw.mra).  MAME's gfx_layout lists bit planes most-significant
    first, so the four bytes of a word carry pen bits 3, 2, 1, 0 in that
    order: the first mask ROM supplies the top two bits, the second the
    bottom two.  Characters are 8 words; a 16x16 tile is four characters,
    top-left, top-right, bottom-left, bottom-right.
    """

    def __init__(self, data):
        # one byte per pixel, characters in order, 64 bytes each
        n_chars = len(data) // 32
        pix = bytearray(n_chars * 64)
        o = 0
        for w in range(len(data) // 4):
            p3, p2, p1, p0 = data[4 * w], data[4 * w + 1], data[4 * w + 2], data[4 * w + 3]
            for j in range(8):
                b = 7 - j
                pix[o + j] = (((p0 >> b) & 1) | (((p1 >> b) & 1) << 1)
                              | (((p2 >> b) & 1) << 2) | (((p3 >> b) & 1) << 3))
            o += 8
        self.chars = pix
        self.n_chars = n_chars
        self.n_tiles = n_chars // 4

    def char_row(self, code, row):
        """8 pens of one row of an 8x8 character."""
        o = (code % self.n_chars) * 64 + row * 8
        return self.chars[o:o + 8]

    def tile_row(self, code, row):
        """16 pens of one row of a 16x16 tile."""
        t = code % self.n_tiles
        c = 4 * t + (2 if row >= 8 else 0)
        r = row & 7
        left = self.char_row(c, r)
        right = self.char_row(c + 1, r)
        return left + right


class State:
    """One dumped frame: see tools/dump_state.lua for the file layout.

    A "lite" dump carries only the control registers and sprite RAM, which is
    all the framebuffer replay needs; `full` says which kind this is.
    """

    def __init__(self, path):
        d = open(path, 'rb').read()
        if d[:4] not in (b'MWST', b'MWSL'):
            raise ValueError(f'{path}: not a state dump')
        self.full = d[:4] == b'MWST'
        self.frame = int.from_bytes(d[8:12], 'little')
        o = 12

        def words(n):
            nonlocal o
            v = memoryview(d)[o:o + 2 * n].cast('H')  # little-endian host
            o += 2 * n
            return v

        if self.full:
            self.ctrl = list(words(16))
            self.vram = words(32768)
            self.spriteram = words(3264)
            self.scrollram = words(1024)
            self.palette = words(4096)
            self.fb = [words(H * 160), words(H * 160)]
            self.pixels = d[o:o + W * H * 4]
        else:
            self.ctrl = list(words(16))
            self.spriteram = words(3264)
            self.vram = self.scrollram = self.palette = None
            self.fb = None
            self.pixels = None

    # --- control register decoding (tc0180vcu.cpp ctrl_w) ---
    @property
    def video_control(self):
        return (self.ctrl[7] >> 8) & 0xFF

    @property
    def fg_bank(self):
        v = (self.ctrl[0] >> 8) & 0xFF
        return ((v & 0x0F) << 12, ((v >> 4) & 0x0F) << 12)

    @property
    def bg_bank(self):
        v = (self.ctrl[1] >> 8) & 0xFF
        return ((v & 0x0F) << 12, ((v >> 4) & 0x0F) << 12)

    @property
    def tx_bank(self):
        return ((self.ctrl[6] >> 8) & 0x0F) << 11

    def mame_fb(self, page):
        """MAME's framebuffer page as 320x224 bytes.

        Only 8 bits per pixel: Lua reads it through the chip's CPU-side
        handler, which is byte wide, so the top two bits of the 10-bit value
        are not visible here.
        """
        src = self.fb[page]
        out = bytearray(W * H)
        for y in range(H):
            row = src[y * 160:(y + 1) * 160]
            o = y * W
            for i, v in enumerate(row):
                out[o + 2 * i] = v >> 8        # framebuffer_word_r packs
                out[o + 2 * i + 1] = v & 0xFF  # the even pixel in the high byte
        return out


class Framebuffer:
    """The chip's two sprite framebuffer pages and the page flip.

    tc0180vcu_device::vblank_update, once per vblank, in this order:
      1. unless video control bit 0 is set, clear the page being displayed;
      2. unless bit 7 is set, flip to the other page (bit 7 instead selects
         the page from bit 6, which video_control() latches on the write);
      3. draw every sprite into the page now current.

    Steps 1 and 3 touch different pages, which is what lets the core clear one
    while it paints the other.  `page` after `step` is the page the next frame
    will display.
    """

    def __init__(self):
        self.pages = [[0] * (W * H), [0] * (W * H)]
        self.page = 0

    def step(self, st, gfx):
        vc = st.video_control
        if not (vc & 0x01):
            p = self.pages[self.page]
            for i in range(W * H):
                p[i] = 0
        if not (vc & 0x80):
            self.page ^= 1
        else:
            self.page = 0 if (vc & 0x40) else 1
        draw_sprites(st, gfx, self.pages[self.page])
        return self.pages[self.page]

    def current(self):
        return self.pages[self.page]


def draw_sprites(st, gfx, fb):
    """Paint every sprite into `fb` (320x224 of 16-bit values), as
    tc0180vcu_device::draw_sprites does.

    The table is walked backwards so entry 0 lands on top.  `fb` is modified
    in place and pen 0 is never written, so a zero means "nothing here".
    """
    spr = st.spriteram
    big = False
    x_no = y_no = x_num = y_num = 0
    xlatch = ylatch = 0
    zoomxlatch = zoomylatch = 0

    for offs in range((0x1980 - 16) // 2, -1, -8):
        code = spr[offs]
        colw = spr[offs + 1]
        flipx = (colw >> 14) & 1
        flipy = (colw >> 15) & 1
        color = (colw & 0x3F) * 16

        x = spr[offs + 2] & 0x3FF
        y = spr[offs + 3] & 0x3FF
        if x >= 0x200:
            x -= 0x400
        if y >= 0x200:
            y -= 0x400

        data = spr[offs + 5]
        if data and not big:
            x_num = (data >> 8) & 0xFF
            y_num = data & 0xFF
            x_no = y_no = 0
            xlatch, ylatch = x, y
            d4 = spr[offs + 4]
            zoomxlatch = (d4 >> 8) & 0xFF
            zoomylatch = d4 & 0xFF
            big = True

        d4 = spr[offs + 4]
        zoomx = (d4 >> 8) & 0xFF
        zoomy = d4 & 0xFF
        zx = (0x100 - zoomx) // 16
        zy = (0x100 - zoomy) // 16

        if big:
            zoomx, zoomy = zoomxlatch, zoomylatch
            # MAME's own note: this chops a big sprite into independently
            # scaled 16x16 pieces rather than scaling it as a whole.  It is
            # not what the hardware does, but it is what we are matching.
            x = xlatch + (x_no * (0xFF - zoomx) + 15) // 16
            y = ylatch + (y_no * (0xFF - zoomy) + 15) // 16
            zx = xlatch + ((x_no + 1) * (0xFF - zoomx) + 15) // 16 - x
            zy = ylatch + ((y_no + 1) * (0xFF - zoomy) + 15) // 16 - y
            y_no += 1
            if y_no > y_num:
                y_no = 0
                x_no += 1
                if x_no > x_num:
                    big = False

        if zoomx or zoomy:
            _blit_zoom(gfx, fb, code, color, flipx, flipy, x, y, zx, zy)
        else:
            _blit(gfx, fb, code, color, flipx, flipy, x, y)


def _blit(gfx, fb, code, color, flipx, flipy, sx, sy):
    """gfx_element::transpen_raw for a 16x16 tile, clipped to the window."""
    for ty in range(16):
        y = sy + ty
        if not (VIS_Y0 <= y <= VIS_Y1):
            continue
        row = gfx.tile_row(code, 15 - ty if flipy else ty)
        base = (y - VIS_Y0) * W
        for tx in range(16):
            x = sx + tx
            if not (VIS_X0 <= x <= VIS_X1):
                continue
            pen = row[15 - tx if flipx else tx]
            if pen:
                fb[base + x - VIS_X0] = color + pen


def _blit_zoom(gfx, fb, code, color, flipx, flipy, sx, sy, zx, zy):
    """gfx_element::zoom_transpen_raw, following drawgfxt.ipp exactly.

    The chip's driver hands MAME 16.16 scale factors of `(zx << 16) / 16`,
    so `zx` is the destination width in pixels.  MAME rounds the destination
    size, derives the source step from it, clips, and then walks the
    destination stepping the source by that amount -- all of which has to be
    reproduced bit for bit, because the rounding decides which source column
    each destination pixel takes.
    """
    scalex = (zx << 16) // 16
    scaley = (zy << 16) // 16
    if scalex == 0x10000 and scaley == 0x10000:
        _blit(gfx, fb, code, color, flipx, flipy, sx, sy)
        return

    dstwidth = (scalex * 16 + 0x8000) >> 16
    dstheight = (scaley * 16 + 0x8000) >> 16
    if dstwidth < 1 or dstheight < 1:
        return
    dx = (16 << 16) // dstwidth
    dy = (16 << 16) // dstheight

    destx, desty = sx, sy
    destendx = destx + dstwidth - 1
    if destx > VIS_X1 or destendx < VIS_X0:
        return
    srcx = 0
    if destx < VIS_X0:
        srcx = (VIS_X0 - destx) * dx
        destx = VIS_X0
    if destendx > VIS_X1:
        destendx = VIS_X1

    destendy = desty + dstheight - 1
    if desty > VIS_Y1 or destendy < VIS_Y0:
        return
    srcy = 0
    if desty < VIS_Y0:
        srcy = (VIS_Y0 - desty) * dy
        desty = VIS_Y0
    if destendy > VIS_Y1:
        destendy = VIS_Y1

    if flipx:
        srcx = (dstwidth - 1) * dx - srcx
        dx = -dx
    if flipy:
        srcy = (dstheight - 1) * dy - srcy
        dy = -dy

    for cury in range(desty, destendy + 1):
        row = gfx.tile_row(code, srcy >> 16)
        cursrcx = srcx
        srcy += dy
        base = (cury - VIS_Y0) * W - VIS_X0
        for curx in range(destx, destendx + 1):
            pen = row[cursrcx >> 16]
            cursrcx += dx
            if pen:
                fb[base + curx] = color + pen


def draw_tilemap16(st, gfx, out, which, opaque):
    """bg (`which` = 'bg') or fg 64x64 tilemap of 16x16 tiles into `out`.

    `out` is 320x224 palette indices.  Scrolling follows
    tc0180vcu_device::tilemap_draw: the screen is cut into blocks of
    `256 - ctrl[2+plane]` lines, each taking its own scroll pair.

    The chip's driver hands MAME `-scrollx`, and MAME's effective_rowscroll
    negates it again (`m_dx - m_rowscroll[i]`), so the net mapping is
    simply tilemap = screen - scroll register, modulo the 1024-pixel map.
    """
    if which == 'bg':
        bank0, bank1 = st.bg_bank
        base, plane = BG_BASE, 1
    else:
        bank0, bank1 = st.fg_bank
        base, plane = FG_BASE, 0

    lpb = 256 - ((st.ctrl[2 + plane] >> 8) & 0xFF)
    nblocks = 256 // lpb
    vram = st.vram

    for b in range(nblocks):
        scrollx = st.scrollram[plane * 0x200 + b * 2 * lpb]
        scrolly = st.scrollram[plane * 0x200 + b * 2 * lpb + 1]
        y0, y1 = b * lpb, (b + 1) * lpb - 1
        y0 = max(y0, VIS_Y0)
        y1 = min(y1, VIS_Y1)
        for y in range(y0, y1 + 1):
            my = (y - scrolly) & 0x3FF
            trow = (my >> 4) * 64
            prow = my & 15
            o = (y - VIS_Y0) * W
            for x in range(VIS_X0, VIS_X1 + 1):
                mx = (x - scrollx) & 0x3FF
                ti = trow + (mx >> 4)
                code = vram[ti + bank0]
                attr = vram[ti + bank1]
                px = mx & 15
                py = prow
                if attr & 0x0040:
                    px = 15 - px
                if attr & 0x0080:
                    py = 15 - py
                pen = gfx.tile_row(code, py)[px]
                if pen or opaque:
                    out[o + x - VIS_X0] = (base + (attr & 0x3F)) * 16 + pen


def draw_text(st, gfx, out):
    """The 64x32 text tilemap of 8x8 characters, pen 0 transparent."""
    vram = st.vram
    bank = st.tx_bank
    b0 = (st.ctrl[4] >> 8) & 0xFF
    b1 = (st.ctrl[5] >> 8) & 0xFF
    for y in range(VIS_Y0, VIS_Y1 + 1):
        trow = (y >> 3) * 64
        prow = y & 7
        o = (y - VIS_Y0) * W
        for tx in range(VIS_X0 >> 3, (VIS_X1 >> 3) + 1):
            word = vram[trow + tx + bank]
            code = (word & 0x07FF) | ((b1 if (word >> 11) & 1 else b0) << 11)
            color = (TX_BASE + ((word >> 12) & 0x0F)) * 16
            row = gfx.char_row(code, prow)
            for px in range(8):
                pen = row[px]
                if pen:
                    out[o + (tx * 8 + px) - VIS_X0] = color + pen


def draw_framebuffer(fb, out, priority):
    """tc0180vcu_device::draw_framebuffer for video control bit 3 clear.

    `priority` is 0 or 1; a pixel is drawn when bit 4 of its value matches,
    which is bit 0 of the sprite's colour code.
    """
    want = priority << 4
    for i in range(W * H):
        c = fb[i]
        if c and (c & 0x10) == want:
            out[i] = 0x100 + c


def draw_framebuffer_all(fb, out):
    """The same for video control bit 3 set: every pixel, one pass."""
    for i in range(W * H):
        c = fb[i]
        if c:
            out[i] = 0x100 + c


def compose(st, gfx, fb):
    """taitob_state::screen_update -> 320x224 palette indices."""
    out = [0] * (W * H)
    vc = st.video_control
    if not (vc & 0x20):
        return out                       # video disabled: palette entry 0
    draw_tilemap16(st, gfx, out, 'bg', opaque=True)
    if vc & 0x08:
        draw_tilemap16(st, gfx, out, 'fg', opaque=False)
        draw_framebuffer_all(fb, out)
    else:
        draw_framebuffer(fb, out, 1)
        draw_tilemap16(st, gfx, out, 'fg', opaque=False)
        draw_framebuffer(fb, out, 0)
    draw_text(st, gfx, out)
    return out


def to_rgb(st, indices):
    """Palette lookup: RGBx_444, each nibble expanded by x0x11."""
    pal = st.palette
    rgb = bytearray(len(indices) * 3)
    cache = {}
    for i, idx in enumerate(indices):
        c = cache.get(idx)
        if c is None:
            w = pal[idx & 0xFFF]
            c = ((((w >> 12) & 0xF) * 0x11), (((w >> 8) & 0xF) * 0x11),
                 (((w >> 4) & 0xF) * 0x11))
            cache[idx] = c
        rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2] = c
    return rgb


def mame_rgb(st):
    """MAME's own frame from the dump, as RGB triples."""
    px = st.pixels
    rgb = bytearray(W * H * 3)
    for i in range(W * H):
        # screen:pixels() gives 32-bit ARGB, little-endian in the file
        b, g, r = px[4 * i], px[4 * i + 1], px[4 * i + 2]
        rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2] = r, g, b
    return rgb
