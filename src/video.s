; ---------------------------------------------------------------------------
; Video: ST high (640x400 mono) or ST medium (640x200, two bitplanes).  The
; Ace screen is 32x24 characters of 8x8 pixels.  Mono: drawn 2x2 scaled
; (512x384), centred: 8 lines down, 8 bytes in.  Medium: 2x wide (512x192),
; 4 lines down, 64 pixels in, plane 0 only (plane 1 stays set from the
; black clear; main.s pal_ace makes colour 2 white and 3 black).  1 = black and
; the Ace shows white ink on black, so glyph bytes are inverted; the Ace
; "inverse" bit (bit 7 of the screen byte) cancels that.  Either way a
; character row is 1280 bytes of screen.
; GPL v2 or later.
; ---------------------------------------------------------------------------

; Redraw changed cells (or all when ST_REDRAW is set).  Called from
; host_service with all registers saved.  Does nothing unless video RAM
; (ST_VDIRTY) or character RAM (ST_REDRAW) was written since the last call;
; all such writes go through store_low.  Compares four cells at a time with
; the shadow copy and draws only the cells of groups that differ.
refresh_screen:
        tst.b   medium
        bne     refresh_med
        REFRESH 0
refresh_med:
        REFRESH 1

