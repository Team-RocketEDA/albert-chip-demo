"""Talking-bot proof: text -> tokenizer -> Verilator full model -> text.

Encodes a short prompt with weights/tokenize.py, pushes those ids
through the qualified Vtb_top binary (PROMPT_IDS env, cycled to 64
rows exactly like the baked path), decodes the predicted id back to
text, and writes the input-vs-output pair under results/ for the
README. The sim binary itself is untouched by this file; the bench's
own oracle + protocol checks remain the verdict.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "results"
PROMPT_TEXT = "Hi"
MAX_IDS = 8


def run(cmd, **kw):
    proc = subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, timeout=1200, **kw
    )
    return proc


def tokenize(text):
    proc = run([sys.executable, "weights/tokenize.py", text])
    assert proc.returncode == 0, proc.stderr
    return [int(x, 16) for x in proc.stdout.split()][:MAX_IDS]


def decode(ids):
    proc = run([sys.executable, "weights/tokenize.py", "--decode",
                *(str(i) for i in ids)])
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def test_talking_bot(tmp_path):
    ids = tokenize(PROMPT_TEXT)
    assert len(ids) >= 1

    env = dict(os.environ, PROMPT_IDS=" ".join(str(i) for i in ids),
                 NOTRACE="1")
    build = run(["make", "-C", "src/sim_verilator", "top"], env=env)
    assert build.returncode == 0, build.stdout[-3000:] + build.stderr[-1000:]
    out = build.stdout

    assert "TOP_VLT PASS" in out, out[-2000:]
    m = re.search(r"phaseB oracle argmax pred=(\d+) logit=([0-9a-f]+)", out)
    assert m, out[-2000:]
    pred, logit = int(m.group(1)), m.group(2)
    assert 0 <= pred < 16

    text_out = decode([pred])

    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "talk_in.txt").write_text(
        f"prompt text : {PROMPT_TEXT}\n"
        f"prompt ids  : {' '.join(str(i) for i in ids)}\n"
    )
    (RESULTS / "talk_out.txt").write_text(
        f"pred id     : {pred}\n"
        f"pred logit  : 0x{logit}\n"
        f"output text : {text_out!r}\n"
        f"sim verdict : TOP_VLT PASS (ids->pred full model + protocol)\n"
    )
