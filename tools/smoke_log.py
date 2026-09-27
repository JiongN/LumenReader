"""Validate that every requested native diagnostic actually finished and passed."""

import json
import re

FAILED_COUNT = re.compile(r"\bfailed\s*[=:]\s*([1-9]\d*)\b", re.IGNORECASE)
FALSE_RESULT = re.compile(r"(?:\bpass\s*[=:]\s*false\b|\"pass\"\s*:\s*false\b)", re.IGNORECASE)
CHINESE_FAILURES = re.compile(r"失败\s*([1-9]\d*)\s*项")
SUMMARY = re.compile(r"通过\s+([1-9]\d*)\s*项[，,]\s*失败\s+0\s*项")
LAYOUT = re.compile(r"共上报\s+([1-9]\d*)\s*项")


def diagnostic_failures(log: str, required: list[str]) -> list[str]:
    """A prefix or a skipped diagnostic is not evidence of a passed run."""
    failures = failure_lines(log)
    for name in required:
        lines = [line for line in log.splitlines() if f"[Lumen][{name}]" in line]
        if name == "epub-layout":
            passed = False
            for line in lines:
                try:
                    value = json.loads(line[line.index("{"):])
                except (ValueError, json.JSONDecodeError):
                    continue
                passed |= value.get("pass") is True and value.get("insufficient") is False
        elif name == "annotation-group":
            passed = any(re.search(r"completed\s+passed=[1-9]\d*\s+failed=0\b", line) for line in lines)
        elif name == "lifecycle":
            passed = any(re.search(r"\bpass=true\b", line, re.IGNORECASE) for line in lines)
        elif name == "layout":
            passed = any(LAYOUT.search(line) for line in lines)
        else:
            passed = any(SUMMARY.search(line) for line in lines)
        if not passed:
            failures.append(f"missing successful diagnostic receipt: {name}")
    return failures


def failure_lines(log: str) -> list[str]:
    return [line for line in log.splitlines()
            if "❌" in line or "Fatal error" in line
            or FAILED_COUNT.search(line) or FALSE_RESULT.search(line)
            or CHINESE_FAILURES.search(line)
            or re.search(r"\[Lumen\]\[[^]]+\]\s+FAIL\b", line)]
