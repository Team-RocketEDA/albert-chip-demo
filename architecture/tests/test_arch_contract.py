#!/usr/bin/env python3
"""Architecture contract tests (TDD RED/GREEN gate for docs+diagrams only).

Runner: python3 stdlib unittest (no package.json in this repo; nothing to
install). Run:  python3 -m unittest discover -s architecture/tests -v
Covers: router nav/a11y contract, candidate completeness (ports, widths,
sublabels), hub/doc closure (no hanging blocks), drill-link integrity.
Pure Python only: the router script is verified by parsing its ROUTES data
and asserting the render code paths exist (no JS execution needed).
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
    "05-rms": ("pages/05-rmsnorm.html", "RMSNORM"),
    "06-ffn": ("pages/06-ffn-tile.html", "FFN_TILE"),
    "07-lm": ("pages/07-lm-head.html", "LM_HEAD"),
    "08-loop": ("pages/08-loop-mem-seq.html", "LOOP_MEM_SEQ"),
}
BLOCK_DOCS = [f"{i:02d}-{n}.md" for i, n in [
    (0, "primitive-library"), (1, "embed"), (2, "inproj-tile"),
    (3, "attention-core"), (4, "outproj-tile"), (5, "rmsnorm"),
    (6, "ffn-tile"), (7, "lm-head"), (8, "loop-mem-seq"),
    (9, "interface")]]
ROUTE_KEYS = ["", "tree", "01-embed", "02-inproj", "03-attn", "04-outproj",
              "05-rms", "06-ffn", "07-lm", "08-loop"]


def load_router():
    return (ROOT / "mobilellm-router.html").read_text()


def routes_from_router():
    """Parse the ROUTES literal (route -> file) out of the router script."""
    h = load_router()
    m = re.search(r"const ROUTES = (\{.*?\n\};)\n", h, re.S)
    out = {}
    for rm in re.finditer(r'"([^"]*)":\s*\{f:"([^"]+)"', m.group(1)):
        out[rm.group(1)] = rm.group(2)
    return out


def route_src(key):
    """Raw source slice of one ROUTES entry (for structural assertions)."""
    h = load_router()
    start = h.index(f'"{key}":')
    ends = [h.index(f'"{k}":', start + 1) for k in ROUTE_KEYS
            if k != key and f'"{k}":' in h[start + 1:]]
    end = min([e for e in ends if e > start] or [h.index("\n};", start)])
    return h[start:end]


def count_items(src, arity):
    """Count ["a","b"(,"c")] array literals of given arity in a slice."""
    if arity == 3:
        return len(re.findall(r'\["[^"]+","[^\]]+?","[^"]+"\]', src))
    return len(re.findall(r'\["[^"]+","[^\]]+?"\]', src)) - \
        len(re.findall(r'\["[^"]+","[^\]]+?","[^"]+"\]', src))


def route_up(key):
    m = re.search(r"up:(null|\"[^\"]*\")", route_src(key))
    raw = m.group(1)
    return None if raw == "null" else raw.strip('"')


class TestRouter(unittest.TestCase):
    def test_router_file_exists(self):
        self.assertTrue((ROOT / "mobilellm-router.html").exists())

    def test_skip_link_and_live_region(self):
        h = load_router()
        self.assertIn('class="skip"', h)
        self.assertIn('aria-live="polite"', h)
        self.assertIn("<h1", h)
        self.assertIn('aria-label="Hierarchy and visible blocks"', h)

    def test_up_link_render_path(self):
        h = load_router()
        self.assertIn("Alt+U", h)                      # shortcut documented
        self.assertIn('id: "up"', h)                  # Up link created
        self.assertIn('"#/" + r.up', h)               # points at parent
        for key in ("03-attn", "tree", "08-loop"):
            self.assertEqual(route_up(key), "", f"{key} must go up to L0")
        self.assertIsNone(route_up(""), "L0 must have no Up link")

    def test_l0_shows_all_entity_buttons(self):
        self.assertEqual(count_items(route_src(""), 3), 14)
        # announcer template + L0 label compose "Showing L0 Top" at runtime
        h = load_router()
        self.assertIn('announcer.textContent = "Showing " + r.l', h)
        self.assertIn('l:"L0 Top"', route_src(""))

    def test_subpage_shows_chips(self):
        self.assertEqual(count_items(route_src("03-attn"), 2), 7)
        self.assertIn("leaf block", load_router())

    def test_tree_shows_l1_entities(self):
        self.assertEqual(count_items(route_src("tree"), 3), 8)

    def test_bad_hash_falls_back_to_l0(self):
        self.assertIn("if (!(k in ROUTES)) k =", load_router())

    def test_entity_targets_resolve(self):
        routes = routes_from_router()
        self.assertEqual(set(routes), set(ROUTE_KEYS))
        for key, rel in routes.items():
            self.assertTrue((ROOT / rel).exists(),
                            f"entity target file missing: {rel}")

    def test_aria_current_and_index(self):
        h = load_router()
        self.assertIn("aria-current", h)               # rendered per route
        self.assertIn('document.createElement("details")', h)
        self.assertIn('el("summary", "Index")', h)


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
            if rel not in ("mobilellm-top.html", "blocks-tree.html") \
                    and "/pages/" not in rel:
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
        c = cands["mobilellm-top.html"]
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
        no_script = re.sub(r"<script[\s\S]*?</script>", "", html)
        return re.findall(r"<g\b[^>]*data-node-id=\"([^\"]+)\"", no_script)

    def test_no_unwrapped_nodes(self):
        for rel in ("mobilellm-top.html", "blocks-tree.html"):
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


class TestParams(unittest.TestCase):
    PARAM_SECTIONS = ["Model config", "Datatypes", "Digital timing",
                      "Tile population", "Memory and FIFO", "Clocks",
                      "LM-head placement", "Requant rotation", "Reverification"]

    def test_params_doc_exists(self):
        self.assertTrue((ROOT / "PARAMS.md").exists(), "PARAMS.md missing")

    def test_params_covers_sections(self):
        p = (ROOT / "PARAMS.md").read_text()
        for s in self.PARAM_SECTIONS:
            self.assertIn(s, p, f"PARAMS.md missing section: {s}")

    def test_no_bare_unresolved(self):
        bad = []
        for doc in BLOCK_DOCS:
            for i, line in enumerate(
                    (ROOT / "blocks" / doc).read_text().splitlines(), 1):
                if "nresolved" in line and "PARAMS" not in line:
                    bad.append(f"{doc}:{i}: {line.strip()}")
        self.assertEqual(bad, [], "bare Unresolved lines remain:\n"
                         + "\n".join(bad))

class TestPaperGrounding(unittest.TestCase):
    PAPER = REPO / "s41467-025-63794-4.md"
    GROUNDS = [
        "34 analog tiles",
        "79.4%",
        "six half-tiles (final 256 columns)",
        "summation over only two tiles",
        "Four PCM devices are used to program each weight",
        "two layer-blocks sharing a tile",
        "512 × 512 weights when using 4 PCM per weight",
        "six input and six output landing pads",
        "reside on the same chip, right next to the ILPs/OLPs",
        "Each sequence of tokens is processed through one layer-block",
        "sequence lengths ranging from",
        "up to 128",
    ]

    def test_cal_addr_carries_layer(self):
        for doc in ["08-loop-mem-seq.md", "09-interface.md"]:
            text = (ROOT / "blocks" / doc).read_text()
            self.assertRegex(text, r"cal_addr[^\n]*layer",
                             f"{doc}: cal_addr has no layer field "
                             f"(paper L230: per-layer-use coeff sets)")

    def test_wcal_covers_thirty_uses(self):
        text = (ROOT / "blocks" / "08-loop-mem-seq.md").read_text()
        self.assertIn("30 uses", text)
        self.assertIn("720KB", text)

    def test_paper_text_contains_grounds(self):
        paper = self.PAPER.read_text()
        for g in self.GROUNDS:
            self.assertIn(g, paper, f"paper text missing: {g}")

    def test_no_contradicted_claims(self):
        bad = []
        for doc in BLOCK_DOCS:
            text = (ROOT / "blocks" / doc).read_text()
            if "paper S=512" in text:
                bad.append(f"{doc}: claims paper S=512 (paper GLUE ≤128)")
        for doc in ["04-outproj-tile.md", "06-ffn-tile.md", "../PARAMS.md"]:
            text = (ROOT / "blocks" / doc).read_text() \
                if not doc.startswith("..") else (ROOT / doc[3:]).read_text()
            if "MSB/LSB" in text:
                bad.append(f"{doc}: MSB/LSB split (paper: +/- pair only)")
        self.assertEqual(bad, [], "contradicted claims:\n" + "\n".join(bad))

    def test_every_l1_doc_names_its_interface(self):
        for doc in BLOCK_DOCS[1:9]:
            text = (ROOT / "blocks" / doc).read_text()
            self.assertTrue("Interface integration" in text
                            or "Interface tag" in text,
                            f"{doc} names no 09-interface hookup")

    def test_no_bare_hypothesis_markers(self):
        bad = []
        for doc in BLOCK_DOCS:
            for i, line in enumerate(
                    (ROOT / "blocks" / doc).read_text().splitlines(), 1):
                if "[H:" in line and "PARAMS" not in line:
                    bad.append(f"{doc}:{i}: {line.strip()}")
        self.assertEqual(bad, [], "bare [H: ...] markers remain:\n"
                         + "\n".join(bad))


class TestBoundaryDtypes(unittest.TestCase):
    def test_dequant_rule_pinned(self):
        self.assertIn("s8<<8", (ROOT / "PARAMS.md").read_text())
        self.assertIn("<<8", (ROOT / "blocks" / "05-rmsnorm.md")
                      .read_text())

    def test_rms_exit_requant_pinned(self):
        text = (ROOT / "blocks" / "05-rmsnorm.md").read_text()
        self.assertRegex(text, r"[Rr]equant.*int8|int8.*[Rr]equant")

    def test_attn_output_requant_pinned(self):
        text = (ROOT / "blocks" / "03-attention-core.md").read_text()
        self.assertRegex(text, r"[Rr]equant.*int8|int8.*[Rr]equant")

    def test_lmhead_entry_width_pinned(self):
        text = (ROOT / "blocks" / "07-lm-head.md").read_text()
        self.assertIn("<<8", text)


class TestFabricMapping(unittest.TestCase):
    CAND = (REPO / ".archify" / "architecture-albert-20261102-223832" /
            "candidate.json")

    def _cand(self):
        import json as _json
        return _json.loads(self.CAND.read_text())

    def test_phase_pipeline_nodes(self):
        ids = {n["id"] for n in self._cand()["components"]}
        self.assertEqual(ids, {"tok_in", "embed", "loop", "p0", "attn", "p1",
                              "ln1", "p2", "p3", "ln2", "pool", "wmem",
                              "glue", "mcu"})

    def test_no_floating_islands(self):
        ids = {n["id"] for n in self._cand()["components"]}
        self.assertFalse({"tilemem", "codec", "inproj", "outproj", "ffn",
                          "ln"} & ids)
        bad = [(e.get("from"), e.get("to"), e.get("label"))
               for e in self._cand()["connections"]
               if "executes on" in (e.get("label") or "")]
        self.assertEqual(bad, [], f"non-hardware edges remain: {bad}")

    def test_phase_chain_links(self):
        have = {(e.get("from"), e.get("to"))
                for e in self._cand()["connections"]}
        for link in [("loop", "p0"), ("p0", "attn"), ("attn", "p1"),
                     ("p1", "ln1"), ("ln1", "p2"), ("p2", "p3"),
                     ("p3", "ln2"), ("ln2", "pool"), ("ln2", "loop"),
                     ("pool", "glue")]:
            self.assertIn(link, have, f"missing phase link: {link}")

    def test_phase_macros_name_digital_chain(self):
        # Source-of-truth assertions (.md docs; generated candidate/HTML
        # refresh via archify finalize is pending — no archify CLI here).
        docs = {"p0": "02-inproj-tile.md", "p1": "04-outproj-tile.md",
                "p2": "06-ffn-tile.md", "p3": "06-ffn-tile.md"}
        for pid, doc in docs.items():
            text = (ROOT / "blocks" / doc).read_text()
            self.assertIn("mac_array", text,
                          f"{pid} ({doc}) names no digital MAC chain")
            self.assertNotIn("DAC-XBAR-ADC", text,
                             f"{pid} ({doc}) still carries analog chain")


class TestDiagramCurrency(unittest.TestCase):
    def test_no_stale_cal_addr_in_artifacts(self):
        import json as _json
        bad = []
        for cand in sorted((REPO / ".archify").glob("*/candidate.json")):
            text = cand.read_text()
            for m in _json.loads(text).get("cards", []):
                for item in m.get("items", []):
                    if "cal_addr" in item and "layer" not in item:
                        bad.append(f"{cand.parent.name}: {item}")
        for html in list((ROOT / "pages").glob("*.html")) + \
                [ROOT / "mobilellm-top.html", ROOT / "blocks-tree.html"]:
            for i, line in enumerate(html.read_text().splitlines(), 1):
                if "cal_addr" in line and "layer" not in line:
                    bad.append(f"{html.name}:{i}")
        self.assertEqual(bad, [], "stale cal_addr (no layer4b):\n" +
                         "\n".join(bad))


class TestDocCurrency(unittest.TestCase):
    def test_no_open_tbd_in_blocks(self):
        bad = [d for d in BLOCK_DOCS
               if "TBD" in (ROOT / "blocks" / d).read_text()]
        self.assertEqual(bad, [], f"open TBD markers remain: {bad}")

    def test_demo_params_points_to_answers(self):
        text = (ROOT / "blocks" / "09-interface.md").read_text()
        section = text.split("## Demo parameters")[1]
        self.assertIn("PARAMS", section)

    def test_no_proposal_disclaimer_in_library(self):
        self.assertNotIn("are proposals",
                         (ROOT / "blocks" / "00-primitive-library.md")
                         .read_text())


class TestStageContracts(unittest.TestCase):
    TB = REPO / "testbench"

    def test_stimulus_seg_plan_documented(self):
        self.assertIn("seg", (ROOT / "TESTBENCH.md").read_text())
        self.assertIn("segment", (ROOT / "blocks" / "01-embed.md")
                      .read_text().lower())

    def test_digitizer_time_units_pinned(self):
        self.assertIn("day", (self.TB / "olp_digitizer.py").read_text())

    def test_adc_macro_vendored_and_cited(self):
        vend = REPO / "vendor" / "SKY130_SAR-ADC1"
        for f in ["LICENSE", "doc/Interface.md",
                  "spice/adc_top.gds.C.noD.merge.postlayout.spice",
                  "lef", "verilog/rtl/adc_core_digital.v"]:
            self.assertTrue((vend / f).exists(), f"missing vendor file: {f}")
        self.assertIn("SKY130_SAR-ADC1", (self.TB / "README.md").read_text())


class TestDigitalPivot(unittest.TestCase):
    """100% digital RTL pivot: no analog vehicles, parametric RTL leaves."""

    ANALOG_MARKERS = ["analog tile", "SAR ADC", "DAC driver",
                      "duration-encode", "PCM crossbar", "PCM conductance",
                      "analog cycles", "analog chain"]

    def test_build_map_all_digital(self):
        text = (ROOT / "BUILD_MAP.md").read_text()
        self.assertIn("mac_array", text)
        self.assertNotIn("ANA subckt", text)

    def test_library_has_rtl_section(self):
        text = (ROOT / "blocks" / "00-primitive-library.md").read_text()
        for mod in ["mac_unit", "mac_array", "fifo_sync", "seq_fsm",
                    "sram_1r1w", "requant"]:
            self.assertIn(mod, text, f"§E missing parametric {mod}")

    def test_rtl_mac_unit_exists(self):
        # Pre-contract implementation spikes: moved out of sunset rtl/ into
        # src/spikes (evidence, out of the components contract tree).
        for f in ["mac_unit.v", "tb_mac_unit.v"]:
            self.assertTrue(
                (REPO / "src" / "spikes" / "common" / f).exists(), f)
        for f in ["embed.v", "tb_embed.v"]:
            self.assertTrue(
                (REPO / "src" / "spikes" / "embed" / f).exists(), f)

    def test_no_analog_vehicles_in_tiles(self):
        bad = []
        for doc in ["02-inproj-tile.md", "04-outproj-tile.md",
                    "06-ffn-tile.md", "08-loop-mem-seq.md"]:
            text = (ROOT / "blocks" / doc).read_text()
            for m in self.ANALOG_MARKERS:
                if m in text:
                    bad.append(f"{doc}: {m}")
        self.assertEqual(bad, [], "analog leftovers:\n" + "\n".join(bad))

    def test_top_level_is_digital(self):
        text = (ROOT / "top-level.md").read_text()
        self.assertIn("100% digital RTL", text)
        self.assertIn("mac_array", text)


class TestSkeleton(unittest.TestCase):
    """src/components wiring-only contract: ports + hierarchy, no logic."""
    SRC = REPO / "src" / "components"
    LEAVES = {"fifo_sync", "regfile_dp", "sram_1r1w", "dram_ctrl",
              "mac_unit", "mac_array", "dotK",
              "dff", "requant", "exp_lut",
              "silu_lut", "embed_lut", "irq_sync", "seq_fsm",
              "div_unit"}
    WIRING = {"mobilellm_top", "embed_top", "loop_mem_seq", "inproj_tile",
              "attention_core", "outproj_tile", "rmsnorm_stage",
              "ffn_tile", "lm_head", "softmax_d", "rmsnorm_d",
              "layer_etched", "decoder_etched_stack"}
    NO_LOGIC = ["always", "assign", "initial"]
    SYSTEM_FNS = {"clog2"}
    KEYWORDS = {"generate", "end", "for", "begin", "genvar", "if", "else",
                "case", "while",
                # SystemVerilog assertion statements, not instantiations:
                "assert", "assume", "cover", "initial", "property", "final"}

    def _code(self, name):
        src = (self.SRC / f"{name}.v").read_text()
        src = re.sub(r"//[^\n]*", "", src)  # line comments can't instantiate
        src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)  # nor block comments
        return src

    def test_project_yaml_lists_all_blocks(self):
        yaml_text = (REPO / "src" / "project.yaml").read_text()
        mods = set(re.findall(r"rtl: src/components/(\w+)\.v", yaml_text))
        self.assertEqual(mods, self.LEAVES | self.WIRING)

    def test_module_name_matches_file(self):
        for name in self.LEAVES | self.WIRING:
            self.assertTrue((self.SRC / f"{name}.v").exists(), name)
            m = re.search(r"module\s+(\w+)", self._code(name))
            self.assertIsNotNone(m, name)
            self.assertEqual(m.group(1), name, name)

    # Logic phase (block-logic-plan): LEAVES and mid-levels legitimately
    # contain always/assign now. Only the pure-stitch L1/top files must
    # stay structural — they wire children, nothing else.
    STITCH = {"mobilellm_top", "embed_top", "loop_mem_seq", "inproj_tile",
              "attention_core", "outproj_tile", "rmsnorm_stage",
              "ffn_tile", "lm_head"}

    def test_no_implementation_constructs(self):
        bad = []
        for name in self.STITCH:
            for kw in self.NO_LOGIC:
                if re.search(rf"(?<![\w$]){kw}(?![\w$])", self._code(name)):
                    bad.append(f"{name}.v: {kw}")
        self.assertEqual(bad, [], "implementation constructs:\n" +
                         "\n".join(bad))

    def _instances(self, name):
        # Anchored: real instantiations start their line (skeleton style);
        # unanchored matching also catches `begin : label` + `if (` pairs.
        return {m for m in
                re.findall(r"(?m)^\s*(\w+)\s*(?:#\s*\([^;]*?\))?\s+\w+\s*\(",
                           self._code(name))
              if m not in self.SYSTEM_FNS and m not in self.KEYWORDS}

    def test_hierarchy_closure(self):
        have = {p.stem for p in self.SRC.glob("*.v")}
        bad = []
        for name in self.WIRING:
            for inst in self._instances(name):
                if inst not in have:
                    bad.append(f"{name}.v instantiates missing {inst}")
        self.assertEqual(bad, [], "dangling instances:\n" + "\n".join(bad))

    def test_every_wiring_block_instantiates_child(self):
        # STITCH files wire children and nothing else: childless means
        # empty. Mid-levels (softmax_d, rmsnorm_d) may legitimately
        # flatten to inline datapaths (rmsnorm_d did: seed ROM inline).
        bad = [n for n in self.STITCH if not self._instances(n)]
        self.assertEqual(bad, [], f"wiring with no children: {bad}")

    def test_elab_gate_passes(self):
        import shutil
        import subprocess
        iv = shutil.which("iverilog") or \
            "/home/alrida-ismail/tools/oss-cad-suite/bin/iverilog"
        if not (shutil.which("iverilog") or
                __import__("os").path.exists(iv)):
            self.skipTest("iverilog not installed")
        r = subprocess.run([iv, "-tnull", "-o", "/dev/null"] +
                           sorted(str(p) for p in self.SRC.glob("*.v")),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


class TestPinNames(unittest.TestCase):
    """Exact RTL port-name lists per macro (audited from src/components)."""
    SRC = REPO / "src" / "components"
    EXPECTED = {
        "mac_array": ["clk", "rst_n", "ce", "clr", "avec", "bvec",
                      "acc_in", "acc_out"],
        "inproj_tile": ["clk", "rst_n", "tok_in", "tok_valid", "cfg_scale",
                        "cfg_zero", "tok_ready", "y_out", "y_valid"],
        "attention_core": ["clk", "rst_n", "q_in", "k_in", "v_in",
                           "qkv_valid", "s_cfg", "qkv_ready", "y_out",
                           "y_valid"],
        "outproj_tile": ["clk", "rst_n", "z_in", "z_valid", "z_ready",
                         "slice_out", "slice_valid"],
        "rmsnorm_stage": ["clk", "rst_n", "x_in", "resid_in", "in_valid",
                          "in_ready", "y_out", "y_valid"],
        "ffn_tile": ["clk", "rst_n", "x_in", "x_valid", "start", "x_ready",
                     "y_out", "y_valid", "done"],
        "lm_head": ["clk", "rst_n", "x_last_in", "x_valid", "pred_out",
                    "done"],
        "embed_top": ["clk", "rst_n", "ids_in", "ids_valid", "ids_ready",
                      "x0_out", "x0_valid"],
        "layer_etched": ["clk", "rst_n", "x_in", "x_valid", "x_ready",
                         "x_out", "y_valid"],
    }

    def _ports(self, name):
        src = (self.SRC / f"{name}.v").read_text()
        m = re.search(r"module\s+" + name + r"\b(.*?)\);", src, re.S)
        self.assertIsNotNone(m, f"{name}: module header not found")
        hdr = re.sub(r"//[^\n]*", "", m.group(1))
        return re.findall(r"(?:input|output|inout)\s+(?:wire|reg)?\s*"
                          r"(?:\[.*?\]\s*)?(\w+)", hdr)

    def test_exact_port_names(self):
        for name, want in self.EXPECTED.items():
            self.assertEqual(self._ports(name), want,
                             f"port list drift in module {name}")


class TestSequencer(unittest.TestCase):
    def test_hardwired_fsm_not_cpu(self):
        text = (ROOT / "blocks" / "08-loop-mem-seq.md").read_text()
        self.assertIn("HARDWIRED", text)
        self.assertNotIn("RV32", text.replace("no RV32", ""))
        self.assertIn("GOLDEN MODEL", (ROOT / "firmware" / "README.md")
                      .read_text())


class TestFirmware(unittest.TestCase):
    FW = ROOT / "firmware" / "mcu_fw.c"
    README = ROOT / "firmware" / "README.md"

    def _code(self):
        src = self.FW.read_text()
        src = re.sub(r"/\*[\s\S]*?\*/", "", src)   # block comments
        src = re.sub(r"//[^\n]*", "", src)          # line comments
        return src

    def test_fw_rv32im_only(self):
        code = self._code()
        self.assertNotIn("float", code)
        self.assertNotIn("double", code)
        self.assertNotIn("/", code)   # no DIV: recip via MUL+qrecip
        self.assertNotIn("%", code)   # no REM
        for op in ["MUL", "MRET", "wfi"]:
            self.assertIn(op, self.FW.read_text())

    def test_fw_four_irqs(self):
        src = self.FW.read_text()
        for n in ["recal_isr", "layer_done_isr", "error_isr", "phase_isr"]:
            self.assertIn(n, src)
        for irq in ["IRQ 0", "IRQ 1", "IRQ 2", "IRQ 3"]:
            self.assertIn(irq, src)

    def test_fw_cal_addr_has_layer(self):
        self.assertRegex(self._code(),
                         r"CAL_SLOT\(layer,\s*block,\s*phase,\s*tile,\s*col\)")
        self.assertIn("<< 20", self._code())

    def test_fw_mmio_matches_readme(self):
        code_offs = sorted(set(
            int(m, 16) for m in
            re.findall(r"MMIO32\(BASE \+ (0x[0-9A-Fa-f]+)\)", self._code())))
        self.assertEqual(len(code_offs), len(set(code_offs)))
        readme = self.README.read_text()
        mmio = readme[readme.index("## MMIO map"):readme.index("## Handlers")]
        readme_offs = sorted(set(
            int(m, 16) for m in re.findall(r"^(0x[0-9A-Fa-f]+) ", mmio,
                                           flags=re.M)))
        self.assertEqual(code_offs, readme_offs,
                         "code MMIO map != README MMIO map")

    def test_fw_early_exit_policy(self):
        code = self._code()
        self.assertIn("MARGIN > MARGIN_TH", code)


if __name__ == "__main__":
    unittest.main()
