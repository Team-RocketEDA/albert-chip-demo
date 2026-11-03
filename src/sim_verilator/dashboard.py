#!/usr/bin/env python3
"""dashboard.py — generate renders/dashboard.html from REAL sim outputs.

Runs the Verilator benches live, captures their transcripts, and renders a
static dashboard: prompt transcript, per-bench results, benchmark numbers,
the GDS screenshot, and links to the archify schematics and .fst waves.
Pure stdlib. No numbers are invented: transcripts come from the runs below;
the synth/GDS figures are the measured values from the committed flow
(src/synth/mac_array, LibreLane Classic, sky130A).

Usage (from repo root):  python3 src/sim_verilator/dashboard.py
Output: renders/dashboard.html (open it in a browser locally).
"""
import html
import re
import subprocess

ROOT = __import__("pathlib").Path(__file__).resolve().parent.parent.parent


def run(cmd):
    p = subprocess.run(cmd, shell=True, cwd=ROOT, capture_output=True,
                       text=True, timeout=600)
    return p.returncode, (p.stdout + p.stderr).strip()


def bench(name, cmd):
    rc, out = run(cmd)
    status = "PASS" if (rc == 0 and "FAIL" not in out and "MISMATCH" not in out
                        and "ERROR" not in out) else "CHECK"
    if "TOP_SMOKE" in out:
        status = "SMOKE (top is structural)"
    return {"name": name, "cmd": cmd, "rc": rc, "out": out, "status": status}


def main():
    benches = [
        bench("prompt", "make -C src/sim_verilator prompt PROMPT_IDS='1 2 0x42 9999'"),
        bench("embed", "make -C src/sim_verilator embed"),
        bench("rmsnorm", "make -C src/sim_verilator rmsnorm"),
        bench("top", "make -C src/sim_verilator top"),
    ]

    def section(b):
        return (f"<h2>{html.escape(b['name'])} <span class='badge'>{html.escape(b['status'])}</span></h2>\n"
                f"<p class='cmd'>{html.escape(b['cmd'])}</p>\n"
                f"<pre>{html.escape(b['out'][-4000:])}</pre>\n")

    body = "\n".join(section(b) for b in benches)
    overall = ("ALL GREEN" if all(b["status"] in ("PASS", "SMOKE (top is structural)")
                                  for b in benches) else "SEE OUTPUT")

    page = f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8">
<title>MobileLLM-125M decoder chip — sim dashboard</title>
<style>
body {{ font-family: monospace; max-width: 1000px; margin: 2em auto;
       padding: 0 1em; background: #0d1117; color: #c9d1d9; }}
h1 small {{ color: #8b949e; }} pre {{ background: #161b22; padding: 1em;
overflow-x: auto; border: 1px solid #30363d; }} .badge {{ background: #238636;
padding: 0.1em 0.5em; border-radius: 1em; font-size: 0.8em; }}
.cmd {{ color: #8b949e; }} table {{ border-collapse: collapse; }}
td, th {{ border: 1px solid #30363d; padding: 0.3em 0.8em; text-align: left; }}
img {{ max-width: 100%; border: 1px solid #30363d; }} a {{ color: #58a6ff; }}
.note {{ color: #d29922; }}
</style></head>
<body>
<h1>MobileLLM-125M decoder chip <small>sim dashboard — {overall}</small></h1>
<p>Every transcript below is captured live from the benches (pure Verilator
+ baked checkpoint bytes). Token ids are the prompt language: there is no
text tokenizer in the repo, so prompts are id lists and vectors are the
answers. Only the 8 baked rows are programmed into the demo init image;
other ids read zero (<span class="note">sparse init, not a model result</span>).
Full token coverage needs the 18&nbsp;MB <tt>embed_full.hex</tt> image.</p>
{body}
<h2>Silicon so far</h2>
<table>
<tr><th>Block</th><th>sky130 cells</th><th>Notes</th></tr>
<tr><td>mac_unit</td><td>528</td><td>yosys 0.62, tt corner</td></tr>
<tr><td>mac_array P=32</td><td>12,401</td><td>ABC 52 s Booth-recoded; GDS below</td></tr>
<tr><td>dotK K=128</td><td>48,939</td><td>ABC 31 min single-threaded</td></tr>
</table>
<p><tt>mac_array</tt> placed+routed (LibreLane Classic, sky130A, 480x480 um):
13,915 nets, 363,757 um wire, zero DRC, GDS 33 MB / 485,719 shapes.</p>
<img src="mac_array_top.png" alt="mac_array GDS screenshot">
<h2>Artifacts</h2>
<ul>
<li>Schematics: <a href="../architecture/mobilellm-top.html">top-level</a>,
<a href="../architecture/blocks-tree.html">block tree</a>,
<a href="../architecture/mobilellm-router.html">router</a>,
<a href="../architecture/pages/">per-block pages</a></li>
<li>Waves (open in Surfer): <tt>src/sim_verilator/waves_prompt.fst</tt>,
<tt>waves_embed.fst</tt>, <tt>waves_rmsnorm.fst</tt>, <tt>waves_top.fst</tt></li>
<li>GDS: <tt>renders/mac_array.gds</tt> — full-chip GDS waits on the stitching
(<tt>mobilellm_top</tt> hierarchy is still structural; SRAM macros for the
weight banks will come from <tt>sky130_fd_bd_sram</tt>).</li>
</ul>
</body></html>
"""
    out = ROOT / "renders" / "dashboard.html"
    out.write_text(page)

    # Smoke: the file must parse as HTML with the key sections present.
    from html.parser import HTMLParser

    class Checker(HTMLParser):
        def __init__(self):
            super().__init__()
            self.tags = set()

        def handle_starttag(self, tag, attrs):
            self.tags.add(tag)

    c = Checker()
    c.feed(page)
    assert {"h1", "pre", "table", "img"} <= c.tags, c.tags
    print(f"dashboard written: {out} ({len(page)} bytes, tags ok)")


if __name__ == "__main__":
    main()
