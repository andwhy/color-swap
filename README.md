# ColorSwap

A tiny macOS utility for when the **black cartridge is empty but the color one still works**.

It adds **Print without Black** to the PDF ▾ menu of every print dialog. It recolors the
document so the printer uses **only color ink**: black becomes blue, red or green (each a mix
of two color inks), gray becomes a lighter tint, and white stays white. Text and QR codes stay
readable. Each document gets a different color, chosen to wear the cyan, magenta and yellow
cartridges evenly.

Available in English, German, Russian, French and Spanish.

## Install

```bash
git clone https://github.com/andwhy/color-swap.git
cd color-swap
./install.sh
```

Needs Xcode or the Command Line Tools. To uninstall: `./install.sh uninstall`

## Use

**File → Print → PDF ▾ → Print without Black**, then print from the second dialog.
You can also drop a PDF onto `~/Applications/ColorSwap.app`.

## How it works

A printer driver uses black ink for the gray part of a color, K = 1 − max(R, G, B). ColorSwap
renders each page in grayscale, then maps it to a palette where one RGB channel is always 255,
so K = 0.

## License

[MIT](LICENSE)

---

**По-русски:** утилита для macOS на случай, когда кончился чёрный картридж, а цветной ещё есть.
Добавляет в меню печати PDF ▾ пункт «Печать без чёрного». Он печатает чёрное синим, красным
или зелёным из цветных чернил и чередует цвета, чтобы картриджи расходовались равномерно.
