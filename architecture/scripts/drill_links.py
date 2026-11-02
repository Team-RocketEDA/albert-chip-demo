#!/usr/bin/env python3
"""Handrolled drill-down links (repo-local, archify untouched).

Wraps archify node <g data-node-id="..."> groups in <a href="router-route">
anchors so blocks click through to their nested page inside albert-router.html
(hash routes, react-router style). Idempotent: skips already-wrapped nodes.

Re-run after every `archify finalize` of albert-top.html / blocks-tree.html,
which overwrites these links. Part of the demo build, not the tool.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent  # architecture/
ROUTER = "albert-router.html"

TOP_MAP = {
    "tok_in": "01-embed", "embed": "01-embed",
    "inproj": "02-inproj", "tilemem": "02-inproj", "codec": "02-inproj",
    "attn": "03-attn",
    "outproj": "04-outproj",
    "ln": "05-ln",
    "ffn": "06-ffn",
    "pool": "07-pool", "glue": "07-pool",
    "loop": "08-loop", "wmem": "08-loop", "mcu": "08-loop",
}
TREE_L1 = {
    "embed": "01-embed", "inproj": "02-inproj", "attn": "03-attn",
    "outproj": "04-outproj", "ln": "05-ln", "ffn": "06-ffn",
    "pool": "07-pool", "loop": "08-loop",
}
TREE_L2_PARENT = {
    "id_fifo": "01-embed", "emb_lut": "01-embed", "dot_mac": "01-embed",
    "x0_dbuf": "01-embed", "in_fifo": "02-inproj", "dac_drv": "02-inproj",
    "pcm_xbar": "02-inproj", "sar_adc": "02-inproj", "qkv_buf": "03-attn",
    "syst": "03-attn", "smax": "03-attn", "score": "03-attn",
    "ofifo": "04-outproj", "oxbar": "04-outproj", "cmux": "04-outproj",
    "tbuf": "05-ln", "divsqrt": "05-ln", "aff": "05-ln",
    "fc1": "06-ffn", "hbuf": "06-ffn", "gelu": "06-ffn", "fc2": "06-ffn",
    "pmac": "07-pool", "tanh": "07-pool", "amax": "07-pool",
    "xbank": "08-loop", "sfifo": "08-loop", "lfsm": "08-loop", "mcu": "08-loop",
}


def wrap_nodes(html: str, mapping: dict[str, str]) -> tuple[str, int]:
    """Wrap top-level node groups in anchors. Returns (html, wrapped_count)."""
    out: list[str] = []
    pos, count, n = 0, 0, len(html)
    node_re = re.compile(r'<g\b[^>]*data-node-id="([^"]+)"[^>]*>')
    while True:
        m = node_re.search(html, pos)
        if not m:
            out.append(html[pos:])
            break
        nid = m.group(1)
        route = mapping.get(nid)
        # find balanced </g> for this group
        depth, i = 0, m.start()
        tag_re = re.compile(r'<g\b|</g>')
        end = None
        while True:
            t = tag_re.search(html, i)
            if not t:
                break
            if t.group(0) == "<g":
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    end = t.end()
                    break
            i = t.end()
        if end is None or route is None:
            out.append(html[pos:m.end()])
            pos = m.end()
            continue
        # idempotency: skip if this exact anchor already precedes the group
        prefix = html[max(0, m.start() - 160):m.start()]
        if re.search(r'<a\b[^>]*data-drill="%s">\s*$' % re.escape(nid), prefix):
            out.append(html[pos:end])
            pos = end
            continue
        out.append(html[pos:m.start()])
        out.append('<a href="%s#/%s" data-drill="%s">' % (ROUTER, route, nid))
        out.append(html[m.start():end])
        out.append("</a>")
        pos = end
        count += 1
    return "".join(out), count


def main(files: list[str]) -> int:
    total = 0
    mapping = dict(TOP_MAP)
    mapping.update(TREE_L1)
    mapping.update(TREE_L2_PARENT)
    mapping["albert_top"] = ""
    for rel in files:
        p = HERE / rel
        html = p.read_text()
        new, count = wrap_nodes(html, mapping)
        if count:
            p.write_text(new)
        print(f"{rel}: wrapped {count} node(s)")
        total += count
    return total


if __name__ == "__main__":
    targets = sys.argv[1:] or ["albert-top.html", "blocks-tree.html"]
    main(targets)
