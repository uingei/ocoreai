#!/usr/bin/env python3
"""coverage_report.py — Read SPM test coverage JSON and report per-file stats.

Usage:
    python3 scripts/coverage_report.py [--min-percent N] [--format json]

Reads: .build/.../codecov/ocoreai.json
Output: Per-file coverage summary for ocoreai project source files only
"""

import json
import sys
import os

COVERAGE_PATH = ".build/arm64-apple-macosx/debug/codecov/ocoreai.json"
PROJECT_SOURCES = "Sources/ocoreai/"


def parse_coverage(json_path: str, source_dir: str) -> list[dict]:
    """Parse coverage JSON and return per-file stats for project files."""
    if not os.path.exists(json_path):
        print(f"❌ Coverage file not found: {json_path}")
        print("   Run: swift test --enable-code-coverage")
        sys.exit(1)

    with open(json_path, "r") as f:
        data = json.load(f)

    files = []
    for entry in data.get("data", []):
        for file_info in entry.get("files", []):
            filename = file_info.get("filename", "")
            # Only include project source files, not dependencies
            if source_dir not in filename:
                continue

            summary = file_info.get("summary", {})
            lines = summary.get("lines", {})
            functions = summary.get("functions", {})

            line_count = lines.get("count", 0)
            line_covered = lines.get("covered", 0)
            func_count = functions.get("count", 0)
            func_covered = functions.get("covered", 0)

            # Convert absolute path to relative
            rel_path = filename.split(source_dir, 1)[-1] if source_dir in filename else filename

            line_pct = (line_covered / line_count * 100) if line_count > 0 else 0
            func_pct = (func_covered / func_count * 100) if func_count > 0 else 0

            files.append({
                "file": rel_path,
                "lines_total": line_count,
                "lines_covered": line_covered,
                "lines_pct": round(line_pct, 1),
                "funcs_total": func_count,
                "funcs_covered": func_covered,
                "funcs_pct": round(func_pct, 1),
            })

    return files


def sort_by_module(files: list[dict]) -> dict[str, list[dict]]:
    """Group files by module/directory."""
    modules = {}
    for f in files:
        parts = f["file"].split("/")
        module = parts[0] if parts else "unknown"
        modules.setdefault(module, []).append(f)
    return modules


def print_report(files: list[dict], min_percent: float = 0, as_json: bool = False):
    if as_json:
        print(json.dumps(files, ensure_ascii=False, indent=2))
        return

    if not files:
        print("ℹ️  No project source files found in coverage data")
        return

    # Totals
    total_lines = sum(f["lines_total"] for f in files)
    covered_lines = sum(f["lines_covered"] for f in files)
    total_funcs = sum(f["funcs_total"] for f in files)
    covered_funcs = sum(f["funcs_covered"] for f in files)

    overall_pct = (covered_lines / total_lines * 100) if total_lines > 0 else 0

    print(f"📊 Coverage Report")
    print(f"{'=' * 60}")
    print(f"  Files:           {len(files)}")
    print(f"  Overall:         {overall_pct:.1f}% lines, {(covered_funcs/total_funcs*100) if total_funcs else 0:.1f}% functions")
    print(f"  Covered:         {covered_lines}/{total_lines} lines, {covered_funcs}/{total_funcs} functions")
    print(f"{'=' * 60}")

    # Per-module
    modules = sort_by_module(files)
    for module_name in sorted(modules.keys()):
        mfiles = modules[module_name]
        m_lines = sum(f["lines_total"] for f in mfiles)
        m_covered = sum(f["lines_covered"] for f in mfiles)
        m_pct = (m_covered / m_lines * 100) if m_lines > 0 else 0

        print(f"\n📦 {module_name} ({m_pct:.1f}%) — {len(mfiles)} files")

        # Sort by coverage (worst first) to highlight gaps
        sorted_files = sorted(mfiles, key=lambda x: x["lines_pct"])
        for f in sorted_files:
            icon = "✅" if f["lines_pct"] >= 80 else "🔶" if f["lines_pct"] >= 50 else "❌"
            print(
                f"  {icon} {f['file']:50s} "
                f"lines: {f['lines_covered']:>4}/{f['lines_total']:<4} ({f['lines_pct']:>5.1f}%)  "
                f"funcs: {f['funcs_covered']:>3}/{f['funcs_total']:<3}"
            )

    # Low coverage files
    low_cov = [f for f in files if f["lines_pct"] < min_percent and f["lines_total"] > 5]
    if low_cov:
        print(f"\n⚠️  Files below {min_percent}% coverage threshold:")
        for f in sorted(low_cov, key=lambda x: x["lines_pct"]):
            print(f"  ❌ {f['file']}: {f['lines_pct']}%")


def main():
    min_percent = 50.0
    as_json = False
    for arg in sys.argv[1:]:
        if arg.startswith("--min-percent="):
            min_percent = float(arg.split("=")[1])
        elif arg == "--format" and len(sys.argv) > 2:
            as_json = True
            sys.argv.remove(arg)
            sys.argv.remove("--format")
            if len(sys.argv) > 1 and sys.argv[-1] == "json":
                sys.argv.pop()
        elif arg == "--json":
            as_json = True

    # Resolve paths relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)

    json_path = os.path.join(
        project_dir,
        ".build/arm64-apple-macosx/debug/codecov/ocoreai.json"
    )

    # Fallback: try to find coverage file if it's in a different build config
    if not os.path.exists(json_path):
        import glob
        candidates = glob.glob(
            os.path.join(project_dir, ".build/**/codecov/ocoreai.json"),
            recursive=True
        )
        if candidates:
            json_path = candidates[-1]
        else:
            print("❌ No coverage data found. Run: swift test --enable-code-coverage")
            sys.exit(1)

    files = parse_coverage(json_path, PROJECT_SOURCES)
    print_report(files, min_percent=min_percent, as_json=as_json)


if __name__ == "__main__":
    main()
