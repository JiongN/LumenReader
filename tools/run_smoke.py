#!/usr/bin/env python3
"""Run native smoke checks with synthetic documents and isolated application data.
Usage: python3 tools/run_smoke.py [output-directory]
Build first with ./build.sh. Exits nonzero for failed assertions or missing captures.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "docs/verification/smoke"
OUT.mkdir(parents=True, exist_ok=True)
FIXTURES = OUT / "fixtures"
FIXTURES.mkdir(exist_ok=True)
APP = ROOT / "dist/Lumen.app/Contents/MacOS/Lumen"

def user_state():
    base = Path.home() / "Library/Application Support/com.jn.lumen"
    # Never read API credentials. Hash only settings and history files.
    return {str(p.relative_to(base)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in base.rglob("*.json") if "credentials" not in p.parts}

before = user_state()
subprocess.run(["swift", str(ROOT / "tools/make_test_pdfs.swift"), str(FIXTURES)], check=True, capture_output=True)
subprocess.run([sys.executable, str(ROOT / "tools/make_test_epub.py"), str(FIXTURES)], check=True, capture_output=True)
percent_pdf = FIXTURES / "文献100%-%@-%n.pdf"
percent_pdf.write_bytes((FIXTURES / "text.pdf").read_bytes())
cases = {
    "pdf-rules": ["--open", str(percent_pdf), "--window-size", "920x620", "--layout-report", "1", "--resize-report", "1", "--entry-report", "1", "--keys-report", "1", "--ocr-menu-report", "1", "--theme-report", "1"],
    "pdf-minimum": ["--open", str(percent_pdf), "--window-size", "920x620", "--layout-report", "1"],
    "pdf-behavior": ["--open", str(FIXTURES / "text.pdf"), "--annotate-report", "1", "--paragraph-report", "1", "--conversation-report", "1", "--lifecycle-report", "1"],
    "epub": ["--open", str(FIXTURES / "typography.epub"), "--epub-layout-report", "1", "--layout-report", "1", "--window-size", "1320x820"],
    "pdf-dark": ["--open", str(FIXTURES / "text.pdf"), "--reading-theme", "midnight", "--window-size", "1320x820", "--layout-report", "1"],
}
expected = {
    "pdf-rules": ["[Lumen][entry]", "[Lumen][resize]", "[Lumen][keys]", "[Lumen][theme]"],
    "pdf-behavior": ["[Lumen][conversation]", "[Lumen][paragraph]", "[Lumen][annotate]", "[Lumen][annotation-group]"],
    "epub": ["[Lumen][epub-layout]"],
}
results = []
for name, args in cases.items():
    image = OUT / f"{name}.png"
    env = dict(os.environ, LUMEN_TEST_DATA=str(OUT / f"data-{name}"))
    with (OUT / f"{name}.log").open("w") as log:
        try:
            result = subprocess.run([str(APP), *args, "--capture", str(image), "--capture-delay", "9", "--capture-screen", "1"], env=env, stdout=log, stderr=log, timeout=60)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    text = (OUT / f"{name}.log").read_text()
    failures = [line for line in text.splitlines() if "❌" in line or "Fatal error" in line]
    failures.extend("missing diagnostic: " + marker for marker in expected.get(name, []) if marker not in text)
    ok = code == 0 and image.exists() and image.stat().st_size > 0 and not failures
    results.append(dict(case=name, passed=ok, exit_code=code, failures=failures))
    print(f"{name}: {'PASS' if ok else 'FAIL'}", flush=True)
after = user_state()
results.append(dict(case="real-user-json-unchanged", passed=before == after))
(OUT / "smoke-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
sys.exit(0 if all(r["passed"] for r in results) else 1)
