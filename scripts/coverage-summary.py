#!/usr/bin/env python3
"""xcresult のカバレッジを領域ごとの Markdown の表にする (CI の Job Summary 用)。

使い方: scripts/coverage-summary.py <path.xcresult>
"""
import collections
import json
import subprocess
import sys


def area(path: str) -> str:
    # Milu/Features/<機能>/... は機能ごと、それ以外は Milu/<領域>/ ごとにまとめる
    parts = path.split("/Milu/", 1)[1].split("/")
    if len(parts) == 1:
        return "(直下)"
    return "/".join(parts[:2]) if parts[0] == "Features" else parts[0]


def summarize(report: dict) -> str:
    app = next(t for t in report["targets"] if t["name"] == "Milu.app")
    totals = collections.defaultdict(lambda: [0, 0])
    for f in app["files"]:
        t = totals[area(f["path"])]
        t[0] += f["coveredLines"]
        t[1] += f["executableLines"]

    lines = ["| 領域 | カバレッジ | 未通過の行 |", "|---|---:|---:|"]
    for name, (covered, executable) in sorted(totals.items()):
        if executable:
            lines.append(f"| {name} | {covered / executable:.1%} | {executable - covered} |")
    lines.append(f"| **全体** | **{app['lineCoverage']:.1%}** | {app['executableLines'] - app['coveredLines']} |")
    return "\n".join(lines)


if __name__ == "__main__":
    out = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", sys.argv[1]],
        check=True, capture_output=True, text=True,
    ).stdout
    print("## iOS の単体テストのカバレッジ (Milu.app)\n")
    print(summarize(json.loads(out)))
