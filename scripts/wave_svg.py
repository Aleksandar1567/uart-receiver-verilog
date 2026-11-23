#!/usr/bin/env python3
"""Render waveform SVGs for docs/img from build/tb_wave.vcd.

Event-based (time on the x axis), because a UART frame is thousands of clock
cycles long. Style matches the waveforms in Aleksandar1567/rvgrid.

    python3 scripts/wave_svg.py [build/tb_wave.vcd] [docs/img]
"""
import sys
from html import escape
from pathlib import Path

CSS = """
text { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; fill: #1f2328; }
.label { font-weight: 600; }
.wave { stroke: #0969da; stroke-width: 1.5; fill: none; }
.spike { stroke: #cf222e; stroke-width: 1.5; }
.bus  { stroke: #8250df; stroke-width: 1.2; fill: #8250df14; }
.grid { stroke: #d0d7de; stroke-width: 0.5; }
.idle { stroke: #8c959f; stroke-width: 1; stroke-dasharray: 3 3; }
.title { font-size: 13px; font-weight: 700; }
.bit { font-size: 11px; fill: #57606a; }
@media (prefers-color-scheme: dark) {
  text { fill: #e6edf3; }
  .wave { stroke: #4493f8; }
  .spike { stroke: #ff7b72; }
  .bus  { stroke: #ab7df8; fill: #ab7df81f; }
  .grid { stroke: #30363d; }
  .bit { fill: #8d96a0; }
}
"""

STATES = {0: "IDLE", 1: "START", 2: "DATA", 3: "PARITY", 4: "STOP", 5: "WAIT_IDLE"}
BIT_NS = 1e9 / 115_200


def parse_vcd(path, wanted):
    """Return {full_name: [(time, value_or_None), ...]} for the wanted signals."""
    ids, scope, changes, t = {}, [], {w: [] for w in wanted}, 0
    with open(path) as f:
        header = True
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if header:
                if tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    name = ".".join(scope + [tok[4]])
                    if name in wanted:
                        ids.setdefault(tok[3], []).append(name)
                elif tok[0] == "$enddefinitions":
                    header = False
                continue
            c = tok[0]
            if c[0] == "#":
                t = int(c[1:])
            elif c[0] in "bB":
                for n in ids.get(tok[1], []):
                    bits = c[1:]
                    changes[n].append((t, None if any(b in "xXzZ" for b in bits) else int(bits, 2)))
            elif c[0] in "01xXzZ":
                for n in ids.get(c[1:], []):
                    changes[n].append((t, None if c[0] in "xXzZ" else int(c[0])))
    return changes


def value_at(ch, t):
    v = None
    for tt, vv in ch:
        if tt > t:
            break
        v = vv
    return v


def segments(ch, t0, t1):
    """Constant-value segments [(start, end, value)] clipped to [t0, t1]."""
    out, cur = [], (t0, value_at(ch, t0))
    for tt, vv in ch:
        if t0 < tt < t1 and vv != cur[1]:
            out.append((cur[0], tt, cur[1]))
            cur = (tt, vv)
    out.append((cur[0], t1, cur[1]))
    return out


def render(changes, rows, t0, t1, title, grid_t0, bit_labels=(), width=1100,
           row_h=26, label_w=150, ps_per_ns=1000):
    t0, t1, gt0 = t0 * ps_per_ns, t1 * ps_per_ns, grid_t0 * ps_per_ns
    bit_ps = BIT_NS * ps_per_ns
    plot_w = width - label_w - 10
    x = lambda t: label_w + (t - t0) / (t1 - t0) * plot_w   # noqa: E731
    top = 44 if bit_labels else 30
    height = top + len(rows) * row_h + 10
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}"><style>{CSS}</style>',
           f'<text class="title" x="8" y="18">{escape(title)}</text>']

    # one grid line per bit period
    k = int((t0 - gt0) // bit_ps)
    while gt0 + k * bit_ps <= t1:
        g = gt0 + k * bit_ps
        if g >= t0:
            out.append(f'<line class="grid" x1="{x(g):.1f}" y1="{top - 4}" x2="{x(g):.1f}" y2="{height - 8}"/>')
        k += 1
    for i, lab in enumerate(bit_labels):
        c = gt0 + (i + 0.5) * bit_ps
        if t0 <= c <= t1:
            out.append(f'<text class="bit" x="{x(c):.1f}" y="{top - 8}" text-anchor="middle">{escape(lab)}</text>')

    for ri, (label, sig, kind) in enumerate(rows):
        y0 = top + ri * row_h
        hi, lo, mid = y0 + 4, y0 + row_h - 6, y0 + row_h / 2 - 1
        out.append(f'<text class="label" x="8" y="{y0 + row_h / 2 + 3}">{escape(label)}</text>')
        segs = segments(changes[sig], t0, t1)
        if kind == "bit":
            pts = []
            for a, b, v in segs:
                y = hi if v else lo
                pts += [f"{x(a):.1f},{y}", f"{x(b):.1f},{y}"]
            out.append(f'<polyline class="wave" points="{" ".join(pts)}"/>')
        elif kind == "spike":
            out.append(f'<line class="idle" x1="{label_w}" y1="{lo}" x2="{width - 10}" y2="{lo}"/>')
            for a, b, v in segs:
                if v:
                    out.append(f'<line class="spike" x1="{x(a):.1f}" y1="{hi}" x2="{x(a):.1f}" y2="{lo}"/>')
        else:
            fmt = kind
            for a, b, v in segs:
                x0, x1 = x(a) + 1, x(b) - 1
                if v is None:
                    out.append(f'<line class="idle" x1="{x0:.1f}" y1="{mid}" x2="{x1:.1f}" y2="{mid}"/>')
                    continue
                c = min(3, (x1 - x0) / 2)
                out.append(f'<polygon class="bus" points="{x0:.1f},{mid} {x0 + c:.1f},{hi} {x1 - c:.1f},{hi} '
                           f'{x1:.1f},{mid} {x1 - c:.1f},{lo} {x0 + c:.1f},{lo}"/>')
                text = fmt(v)
                if (x1 - x0) >= 7.3 * len(text) + 4:
                    out.append(f'<text x="{(x0 + x1) / 2:.1f}" y="{mid + 4}" text-anchor="middle">'
                               f'{escape(text)}</text>')
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    vcd = Path(sys.argv[1] if len(sys.argv) > 1 else "build/tb_wave.vcd")
    img = Path(sys.argv[2] if len(sys.argv) > 2 else "docs/img")
    img.mkdir(parents=True, exist_ok=True)

    d = "tb_wave.dut."
    hx = lambda v: f"{v:02x}"                   # noqa: E731
    st = lambda v: STATES.get(v, str(v))        # noqa: E731
    names = [d + n for n in ("rx", "rx_sync", "state", "bit_cnt", "sample_pt", "shift_reg",
                             "rx_valid", "rx_data", "rx_rd", "parity_err", "frame_err",
                             "break_det", "rx_busy")]
    ch = parse_vcd(vcd, set(names))
    missing = [n for n in names if not ch[n]]
    if missing:
        sys.exit(f"signals missing from {vcd}: {missing}")

    # frame starts = IDLE -> START transitions (ns): frame, glitch, bad parity, break
    falls, prev = [], 0
    for t, v in ch[d + "state"]:
        if prev == 0 and v == 1:
            falls.append(t / 1000)
        prev = v
    if len(falls) != 4:
        sys.exit(f"expected 4 IDLE->START transitions, found {len(falls)}")

    frame_bits = ["start"] + [f"D{i}" for i in range(8)] + ["P", "stop"]
    rows = [("rx", d + "rx", "bit"),
            ("rx_sync", d + "rx_sync", "bit"),
            ("state", d + "state", st),
            ("bit_cnt", d + "bit_cnt", str),
            ("sample_pt", d + "sample_pt", "spike"),
            ("shift_reg", d + "shift_reg", hx),
            ("rx_valid", d + "rx_valid", "bit"),
            ("rx_data", d + "rx_data", hx),
            ("rx_rd", d + "rx_rd", "bit")]
    t = falls[0]
    (img / "wave_frame.svg").write_text(render(
        ch, rows, t - BIT_NS, t + 12.5 * BIT_NS,
        "8E1 frame 0x4B: majority vote at each bit centre (red), LSB first into shift_reg, "
        "rx_valid at the centre of the stop bit",
        grid_t0=t, bit_labels=frame_bits))

    rows = [("rx", d + "rx", "bit"),
            ("state", d + "state", st),
            ("sample_pt", d + "sample_pt", "spike"),
            ("rx_valid", d + "rx_valid", "bit"),
            ("rx_data", d + "rx_data", hx),
            ("parity_err", d + "parity_err", "bit"),
            ("frame_err", d + "frame_err", "bit"),
            ("break_det", d + "break_det", "bit"),
            ("rx_busy", d + "rx_busy", "bit")]
    (img / "wave_errors.svg").write_text(render(
        ch, rows, falls[1] - BIT_NS, falls[3] + 17 * BIT_NS,
        "Errors: start glitch rejected, 0xC3 with bad parity, break -> WAIT_IDLE until the line is high",
        grid_t0=falls[1]))
    print(f"wrote {img / 'wave_frame.svg'} and {img / 'wave_errors.svg'}")


if __name__ == "__main__":
    main()
