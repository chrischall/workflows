# Adaptive launcher icon

An iOS `AppIcon.png` is a full-bleed square that the OS rounds. Android masks a
108dp canvas into a shape the *launcher* chooses, and composites separate
background / foreground / monochrome layers. Scaling the iOS bitmap gives a
crop-happy, themed-icon-less result. Redraw it as vectors.

## Geometry — the only number that matters

The canvas is **108×108dp**. The outer 18dp on each edge is bleed/parallax.
Every mask is guaranteed to show only the **centre 66dp circle** — i.e. the
circle centred on (54,54) with r=33. Content between 66dp and 72dp may or may
not survive depending on the launcher's mask.

Fit the artwork inside that circle and *check the arithmetic*, including the
rounded ends of shapes:

```python
import math
def extent(x, y, pad=0.0):      # pad = corner radius of a stadium/rounded shape
    return math.hypot(x - 54, y - 54) + pad
# every extreme point must be <= 33.0
```

Encore's checklist mark: rows at y=34..74, tick column at x=34 (r=3.3), bars
x=42..76 (height 5, so r=2.5 corners) → worst extent 32.3. Fits.

## The monochrome layer is not the foreground

Themed icons tint the whole drawing **one colour**. A navy check knocked out of
a gold disc becomes invisible the moment both are the same tint. Redraw those
shapes so they read in a single colour — encore's ticked rows become *open
rings with the check inside* rather than filled discs.

Declare all three layers:

```xml
<adaptive-icon>
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
```

…in `mipmap-anydpi-v26/ic_launcher.xml` **and** `ic_launcher_round.xml`, then
point the manifest at them. **A missing `android:icon` is silent** — the app
ships the stock robot and nothing warns you.

`minSdk >= 26` means adaptive icons cover every device; no legacy PNG mipmaps
needed. Resource shrinking keeps them (manifest-referenced) — verified.

## Verifying

**ImageMagick's internal SVG renderer silently drops strokes** — open rings and
checkmarks vanish and you "fix" a bug that doesn't exist. Use `rsvg-convert`:

```bash
rsvg-convert -w 432 -h 432 icon.svg -o out.png
```

Render the artwork under both masks before believing it fits:

```
<clipPath id="circle"><circle cx="54" cy="54" r="36"/></clipPath>
<clipPath id="squircle"><path d="M54,18 C78,18 90,30 90,54 C90,78 78,90 54,90
                                 C30,90 18,78 18,54 C18,30 30,18 54,18 Z"/></clipPath>
```

Then install and look at it. A launcher may draw a coloured ring around a
**newly installed** app — that's a launcher treatment, not your background
layer. Check the app drawer before chasing it.

## Play listing assets (Console upload, not bundled)

- **512×512** icon, 32-bit PNG, no alpha.
- **1024×500** feature graphic.

Generate both from the same vector as the app icon so they can never drift:

```bash
rsvg-convert -w 512 -h 512 store_icon.svg -o icon.png
magick icon.png -background '#120D2A' -alpha remove -alpha off play-icon-512.png
```

Keep them in `android/store/` — committed, since they're listing source, not
secrets.
