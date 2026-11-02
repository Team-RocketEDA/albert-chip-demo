#!/usr/bin/env python3
"""Architecture contract tests (TDD RED/GREEN gate for docs+diagrams only).

Runner: python3 stdlib unittest (no package.json in this repo; nothing to
install). Run:  python3 -m unittest discover -s architecture/tests -v
Covers: router nav/a11y contract, candidate completeness (ports, widths,
sublabels), hub/doc closure (no hanging blocks), drill-link integrity.
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # architecture/
REPO = ROOT.parent
PAGES = {
    "01-embed": ("pages/01-embed.html", "EMBED_TOP"),
    "02-inproj": ("pages/02-inproj-tile.html", "INPROJ_TILE"),
    "03-attn": ("pages/03-attention-core.html", "ATTENTION_CORE"),
    "04-outproj": ("pages/04-outproj-tile.html", "OUTPROJ_TILE"),
    "05-ln": ("pages/05-layernorm.html", "LAYERNORM"),
    "06-ffn": ("pages/06-ffn-tile.html", "FFN_TILE"),
    "07-pool": ("pages/07-pooler-classifier.html", "POOLER_HEAD"),
    "08-loop": ("pages/08-loop-mem-seq.html", "LOOP_MEM_SEQ"),
}
BLOCK_DOCS = [f"{i:02d}-{n}.md" for i, n in [
    (0, "primitive-library"), (1, "embed"), (2, "inproj-tile"),
    (3, "attention-core"), (4, "outproj-tile"), (5, "layernorm"),
    (6, "ffn-tile"), (7, "pooler-classifier"), (8, "loop-mem-seq"),
    (9, "interface")]]


def load_router():
    return (ROOT / "albert-router.html").read_text()


def routes_from_router():
    """Parse the ROUTES literal (route -> file) out of the router script."""
    h = load_router()
    m = re.search(r"const ROUTES = (\{.*?\n\};)\n", h, re.S)
    out = {}
    for rm in re.finditer(r'"([^"]*)":\s*\{f:"([^"]+)"', m.group(1)):
        out[rm.group(1)] = rm.group(2)
    return out


class TestRouter(unittest.TestCase):
    def test_router_file_exists(self):
        self.assertTrue((ROOT / "albert-router.html").exists())

    def test_skip_link_and_live_region(self):
        h = load_router()
        self.assertIn('class="skip"', h)
        self.assertIn('aria-live="polite"', h)
        self.assertIn("<h1", h)

    def test_up_link_and_shortcut(self):
        h = load_router()
        self.assertIn("Alt+U", h)
        self.assertIn('id="up"', h)

    def test_entity_targets_resolve(self):
        h = load_router()
        routes = routes_from_router()
        for target in set(re.findall(r"#/([0-9a-z-]*)", h)):
            key = target.lstrip("/")
            if key in ("", "tree"):
                continue
            self.assertIn(key, routes, f"entity target route missing: {key}")
            self.assertTrue((ROOT / routes[key]).exists(),
                            f"entity target file missing: {routes[key]}")

    def test_aria_current_and_index(self):
        h = load_router()
        self.assertIn("aria-current", h)
        self.assertIn("<details>", h)
        self.assertIn("aria-label", h)


class TestCandidates(unittest.TestCase):
    def _cands(self):
        cands = {}
        for d in (REPO / ".archify").glob("*/candidate.json"):
            c = json.loads(d.read_text())
            out = c.get("meta", {}).get("output", "")
            if out.startswith("architecture/"):
                cands[out.split("/", 1)[1]] = c
        return cands

    def test_all_pages_built(self):
        cands = self._cands()
        for key, (rel, _) in PAGES.items():
            self.assertIn(rel, cands, f"no candidate for {rel}")
            self.assertTrue((ROOT / rel).exists(), f"missing built {rel}")

    def test_every_component_has_sublabel(self):
        for rel, c in self._cands().items():
            if not rel.endswith(".html") or "/pages/" not in rel \
                    and rel not in ("albert-top.html", "blocks-tree.html"):
                continue
            for n in c.get("components", []):
                self.assertTrue(n.get("sublabel"),
                                f"{rel}:{n.get('id')} missing sublabel")

    def test_every_page_has_ports_card(self):
        for rel, c in self._cands().items():
            if "/pages/" not in rel:
                continue
            titles = [k.get("title") for k in c.get("cards", [])]
            self.assertIn("Ports", titles, f"{rel} missing Ports card")

    def test_phase_decode_panels(self):
        cands = self._cands()
        c = cands["albert-top.html"]
        titles = [k.get("title") for k in c.get("cards", [])]
        self.assertIn("Interface (09)", titles)
        for rel in ("pages/02-inproj-tile.html", "pages/04-outproj-tile.html",
                    "pages/06-ffn-tile.html", "pages/08-loop-mem-seq.html"):
            titles = [k.get("title") for k in cands[rel].get("cards", [])]
            self.assertIn("Phase decode", titles, f"{rel} missing Phase decode")


class TestClosure(unittest.TestCase):
    def test_block_docs_exist_and_hub_links_them(self):
        hub = (ROOT / "blocks" / "README.md").read_text()
        for doc in BLOCK_DOCS:
            self.assertTrue((ROOT / "blocks" / doc).exists(), doc)
            stem = doc[:-3]
            self.assertIn(stem, hub, f"hub does not link {doc}")

    def test_top_level_links_interface(self):
        top = (ROOT / "top-level.md").read_text()
        self.assertIn("09-interface", top)

    def test_build_map_testbench_firmware_exist(self):
        for p in ["BUILD_MAP.md", "TESTBENCH.md",
                  "firmware/README.md", "firmware/mcu_fw.c",
                  "../testbench/tile_col.py", "../testbench/README.md"]:
            self.assertTrue((ROOT / p).exists(), p)


class TestDrillLinks(unittest.TestCase):
    def _node_ids(self, html):
        return re.findall(r'data-node-id="([^"]+)"', html)

    def test_no_unwrapped_nodes(self):
        for rel in ("albert-top.html", "blocks-tree.html"):
            h = (ROOT / rel).read_text()
            ids = self._node_ids(h)
            self.assertTrue(ids, f"no nodes found in {rel}")
            wrapped = set(re.findall(r'data-drill="([^"]+)"', h))
            for nid in set(ids):
                self.assertIn(nid, wrapped, f"{rel}: node {nid} not wrapped")

    def test_router_routes_resolve(self):
        routes = routes_from_router()
        for key, rel in routes.items():
            self.assertTrue((ROOT / rel).exists(),
                            f"router route {key} -> missing {rel}")


if __name__ == "__main__":
    unittest.main()
