#!/usr/bin/env python3
"""Convert benchmark JSON files into a Markdown report on stdout.

tests/obsidian-embeds-benchmark.lua writes measurements and duration summaries
to JSON. report-benchmark.py reads the JSON and prints Markdown tables. The CI
workflow saves the Markdown as summary.md and displays it in the job summary.
"""

import argparse
import json
from pathlib import Path


def duration(stats):
    """Display a recorded median and its minimum–maximum range in milliseconds."""
    return f"{stats['median']:.1f} [{stats['min']:.1f}–{stats['max']:.1f}]"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+")
    parser.add_argument("--versions", type=Path, help="prepare-tests.py dependency manifest")
    args = parser.parse_args()
    print("# Embed benchmark\n")
    print("Milliseconds: median [minimum–maximum]. Timings are reported without performance thresholds.\n")
    # Each JSON file contains one completed run in headless or terminal mode.
    # Accept either file alone so CI can report headless results if terminal
    # measurement fails before writing its JSON file.
    for path in args.reports:
        report = json.loads(path.read_text())
        if report["schema_version"] != 1:
            raise ValueError("unsupported benchmark schema")
        env = report["environment"]
        # ui_attached records whether Neovim had a terminal UI during measurement.
        mode = "Terminal" if env["ui_attached"] else "Headless"
        version = env["neovim"]
        # The CPU list contains one entry per logical CPU. Deduplicate model
        # names for display and use the list length for the CPU count.
        cpu_models = sorted({cpu["model"] for cpu in env["cpus"]})
        print(f"## {mode}\n")
        print(f"Commit: `{env['plugin_revision']}`. Neovim "
              f"{version['major']}.{version['minor']}.{version['patch']}; {env['luajit']}.\n")
        print(f"{env['os']['sysname']} {env['os']['release']} {env['os']['machine']}; "
              f"{', '.join(cpu_models)}, {len(env['cpus'])} cores, "
              f"{env['memory_bytes'] / 2**30:.1f} GiB RAM. "
              f"Window: {env['columns']} × {env['lines']}.\n")
        print("| Case | Phase | Samples | Host analysis | Note analysis | Longest projection | "
              "First installed | First frame | Settled | Presentation settled | Worst heartbeat gap |")
        print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for case_summary in report["summary"]:
            # summary contains duration statistics but no sample count. Count
            # the entries in runs whose case name matches this summary row.
            samples = sum(run["case"]["name"] == case_summary["case"] for run in report["runs"])
            # Report attachment, a visible-target edit, and an unrelated source
            # edit separately: each phase exercises a different amount of work.
            for stage in ("initial", "edit", "unrelated"):
                phase_summary = case_summary[stage]
                # Show total analysis time and the longest individual projection
                # call. A long projection call can block input during a redraw.
                values = [duration(phase_summary["host_analysis"]["total_ms"]),
                          duration(phase_summary["note_analysis"]["total_ms"]),
                          duration(phase_summary["projection"]["max_ms"])]
                # Append values in the same order as the column headings.
                # Headless runs omit first_display_ms; display a dash for that
                # missing measurement so it cannot be mistaken for zero latency.
                for metric in ("first_installed_ms", "first_display_ms", "settled_ms",
                               "presentation_settled_ms", "worst_heartbeat_gap_ms"):
                    values.append(duration(phase_summary[metric]) if metric in phase_summary else "—")
                print(f"| {case_summary['case']} | {stage} | {samples} | " + " | ".join(values) + " |")
        print("\nFirst frame observes Neovim's composed terminal screen; headless output records "
              "installed extmarks. Semantic settlement can precede presentation. "
              "Heartbeat gaps include analysis, rendering, presentation and observation.\n")
    if args.versions:
        # prepare-tests.py records downloaded versions and checksums here.
        # Extracted dependency archives have no .git directory, so the benchmark
        # cannot obtain those revisions by running git in the dependency paths.
        versions = json.loads(args.versions.read_text())
        print("## Resolved dependencies\n")
        print("```json\n" + json.dumps(versions, indent=2) + "\n```")


if __name__ == "__main__":
    main()
