#!/usr/bin/env python3
"""Handrolled drill-down links (repo-local, archify untouched).

Wraps archify node <g data-node-id="..."> groups in <a href="router-route">
anchors so blocks click through to their nested page inside
mobilellm-router.html (hash routes, react-router style). Idempotent:
skips already-wrapped nodes.

Re-run after every `archify finalize` of mobilellm-top.html /
blocks-tree.html, which overwrites these links. Part of the demo build,
not the tool.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent  # architecture/
ROUTER = "mobilellm-router.html"

TOP_MAP = {
    "tok_in": "01-embed", "embed": "01-embed",
    "loop": "08-loop", "wmem": "08-loop", "mcu": "08-loop",
    "p0": "02-inproj",
    "attn": "03-attn",
    "p1": "04-outproj",
    "ln1": "05-rms", "ln2": "05-rms",
    "p2": "06-ffn", "p3": "06-ffn",
    "pool": "07-lm", "glue": "07-lm",
}
TREE_L1 = {
    "embed": "01-embed", "inproj": "02-inproj", "attn": "03-attn",
    "outproj": "04-outproj", "ln": "05-rms", "ffn": "06-ffn",
    "pool": "07-lm", "loop": "08-loop",
}
TREE_L2_PARENT = {
    "id_fifo": "01-embed", "emb_lut": "01-embed", "xbuf": "01-embed",
    "x0_dbuf": "01-embed", "in_fifo": "02-inproj", "wsram": "02-inproj",
    "qkv_buf": "03-attn",
    "syst": "03-attn", "smax": "03-attn", "score": "03-attn",
    "ofifo": "04-outproj", "oxbar": "04-outproj", "cmux": "04-outproj",
    "tbuf": "05-rms", "divsqrt": "05-rms", "aff": "05-rms",
    "fc1": "06-ffn", "hbuf": "06-ffn", "silu": "06-ffn", "fc2": "06-ffn",
    "pmac": "07-lm", "logits": "07-lm", "amax": "07-lm",
    "lastbuf": "07-lm", "predfifo": "07-lm", "headseq": "07-lm",
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
    mapping["mobilellm_top"] = ""
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
    targets = sys.argv[1:] or ["mobilellm-top.html", "blocks-tree.html"]
    main(targets)
