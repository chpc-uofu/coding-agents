#!/usr/bin/env python3
"""Summarize CPU and GPU efficiency for a Slurm job."""

from __future__ import annotations

import argparse
import csv
import math
import os
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional


SACCT_FIELDS = [
    "JobIDRaw",
    "JobName",
    "State",
    "ElapsedRaw",
    "AllocCPUS",
    "AllocTRES",
    "ReqMem",
    "MaxRSS",
    "TotalCPU",
    "CPUTimeRAW",
    "TRESUsageInAve",
    "TRESUsageInTot",
]

SSTAT_FIELDS = [
    "JobID",
    "AveCPU",
    "AveRSS",
    "MaxRSS",
    "TRESUsageInAve",
    "TRESUsageInMax",
]


@dataclass
class StepMetrics:
    job_id: str
    job_name: str
    state: str
    elapsed_raw: Optional[float]
    alloc_cpus: Optional[float]
    req_mem: str
    max_rss: str
    cpu_time_raw: Optional[float]
    alloc_tres: Dict[str, str]
    tres_in_ave: Dict[str, str]
    tres_in_tot: Dict[str, str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Report CPU/GPU utilization from sacct and sstat."
    )
    parser.add_argument("job_id", help="Slurm job ID")
    parser.add_argument(
        "--sacct-path",
        help="Use an existing sacct --parsable2 output file instead of running sacct",
    )
    parser.add_argument(
        "--sstat-path",
        help="Use an existing sstat --parsable2 output file instead of running sstat",
    )
    return parser.parse_args()


def run_command(cmd: List[str]) -> str:
    try:
        result = subprocess.run(
            cmd,
            check=True,
            text=True,
            capture_output=True,
        )
    except FileNotFoundError as exc:
        raise SystemExit(f"Command not found: {cmd[0]}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        raise SystemExit(stderr or f"Command failed: {' '.join(cmd)}") from exc
    return result.stdout


def load_text(path: Optional[str], cmd: List[str]) -> str:
    if path:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    return run_command(cmd)


def parse_table(text: str) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    reader = csv.DictReader(text.splitlines(), delimiter="|")
    for row in reader:
        cleaned = {key.strip(): (value or "").strip() for key, value in row.items() if key}
        if any(cleaned.values()):
            rows.append(cleaned)
    return rows


def to_float(value: str) -> Optional[float]:
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_tres(value: str) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for item in value.split(","):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, raw = item.split("=", 1)
        result[key.strip()] = raw.strip()
    return result


def normalize_rows(rows: Iterable[Dict[str, str]]) -> List[StepMetrics]:
    metrics: List[StepMetrics] = []
    for row in rows:
        metrics.append(
            StepMetrics(
                job_id=row.get("JobIDRaw", row.get("JobID", "")),
                job_name=row.get("JobName", ""),
                state=row.get("State", ""),
                elapsed_raw=to_float(row.get("ElapsedRaw", "")),
                alloc_cpus=to_float(row.get("AllocCPUS", "")),
                req_mem=row.get("ReqMem", ""),
                max_rss=row.get("MaxRSS", ""),
                cpu_time_raw=to_float(row.get("CPUTimeRAW", "")),
                alloc_tres=parse_tres(row.get("AllocTRES", "")),
                tres_in_ave=parse_tres(row.get("TRESUsageInAve", "")),
                tres_in_tot=parse_tres(row.get("TRESUsageInTot", "")),
            )
        )
    return metrics


def choose_primary_step(rows: List[StepMetrics], job_id: str) -> Optional[StepMetrics]:
    if not rows:
        return None
    preferred = [f"{job_id}.batch", job_id]
    for candidate in preferred:
        for row in rows:
            if row.job_id == candidate:
                return row
    filtered = [row for row in rows if not row.job_id.endswith(".extern")]
    if filtered:
        return max(
            filtered,
            key=lambda row: (
                1 if row.job_id.endswith(".batch") else 0,
                row.elapsed_raw or 0.0,
            ),
        )
    return rows[0]


def find_sstat_row(rows: List[Dict[str, str]], job_id: str) -> Optional[Dict[str, str]]:
    preferred = [f"{job_id}.batch", job_id]
    for candidate in preferred:
        for row in rows:
            if row.get("JobID", "") == candidate:
                return row
    return rows[0] if rows else None


def safe_ratio(numerator: Optional[float], denominator: Optional[float]) -> Optional[float]:
    if numerator is None or denominator in (None, 0):
        return None
    return numerator / denominator


def parse_numeric_string(value: str) -> Optional[float]:
    if not value:
        return None
    cleaned = value.strip()
    if cleaned.endswith(("cn", "Cn", "c", "C", "n", "N")):
        cleaned = cleaned[:-1]
    cleaned = cleaned.rstrip("KMGTP%")
    try:
        return float(cleaned)
    except ValueError:
        return None


def format_percent(value: Optional[float]) -> str:
    if value is None or math.isnan(value):
        return "n/a"
    return f"{value * 100:.1f}%"


def format_value(value: Optional[str]) -> str:
    return value if value else "n/a"


def summarize(primary: StepMetrics, sstat_row: Optional[Dict[str, str]]) -> str:
    alloc_gpus = parse_numeric_string(primary.alloc_tres.get("gres/gpu", ""))
    cpu_eff = safe_ratio(
        primary.cpu_time_raw,
        (primary.alloc_cpus or 0.0) * (primary.elapsed_raw or 0.0),
    )

    sstat_ave = parse_tres(sstat_row.get("TRESUsageInAve", "")) if sstat_row else {}
    sstat_max = parse_tres(sstat_row.get("TRESUsageInMax", "")) if sstat_row else {}
    gpu_util = (
        parse_numeric_string(sstat_ave.get("gres/gpuutil", ""))
        or parse_numeric_string(primary.tres_in_ave.get("gres/gpuutil", ""))
        or parse_numeric_string(primary.tres_in_tot.get("gres/gpuutil", ""))
    )
    gpu_mem = (
        sstat_max.get("gres/gpumem")
        or sstat_ave.get("gres/gpumem")
        or primary.tres_in_ave.get("gres/gpumem")
        or primary.tres_in_tot.get("gres/gpumem")
    )

    lines = [
        f"Job {primary.job_id}: {primary.job_name or 'n/a'}",
        f"State: {primary.state or 'n/a'}",
        f"Elapsed seconds: {primary.elapsed_raw if primary.elapsed_raw is not None else 'n/a'}",
        f"Allocated CPUs: {primary.alloc_cpus if primary.alloc_cpus is not None else 'n/a'}",
        f"Allocated GPUs: {alloc_gpus if alloc_gpus is not None else 'n/a'}",
        f"CPU efficiency: {format_percent(cpu_eff)}",
        f"Requested memory: {format_value(primary.req_mem)}",
        f"MaxRSS: {format_value(primary.max_rss)}",
    ]
    if alloc_gpus is not None and alloc_gpus > 0:
        lines.append(
            f"Average GPU utilization: {f'{gpu_util:.1f}%' if gpu_util is not None else 'n/a'}"
        )
        lines.append(f"GPU memory signal: {format_value(gpu_mem)}")

    findings: List[str] = []
    recommendations: List[str] = []

    if cpu_eff is not None:
        if cpu_eff < 0.4:
            findings.append("CPU allocation was substantially underused.")
            recommendations.append(
                "Reduce --cpus-per-task or --ntasks unless logs show a real bottleneck that can keep those CPUs busy."
            )
            recommendations.append(
                "Set application thread controls explicitly, such as OMP_NUM_THREADS or a tool-specific --threads value, so they match the reserved CPUs."
            )
        elif cpu_eff < 0.8:
            findings.append("CPU efficiency was mixed; some reserved CPUs were likely idle.")
            recommendations.append(
                "Inspect serial phases, I/O waits, and launcher settings before increasing CPU allocation."
            )
        else:
            findings.append("CPU efficiency looked healthy.")

    max_rss = parse_numeric_string(primary.max_rss)
    req_mem = parse_numeric_string(primary.req_mem)
    if max_rss is not None and req_mem is not None and req_mem > 0 and max_rss / req_mem < 0.5:
        findings.append("Memory request appears larger than observed memory use.")
        recommendations.append(
            "Reduce --mem with a safety margin so the job is easier to schedule and does not reserve excess memory."
        )

    if alloc_gpus is not None and alloc_gpus > 0:
        if gpu_util is None:
            findings.append("GPU accounting was allocated but utilization samples were not available in this report.")
        elif gpu_util < 25:
            findings.append("GPU utilization was low.")
            recommendations.append(
                "Check whether the code can actually use all requested GPUs; if not, reduce --gres=gpu:N."
            )
            recommendations.append(
                "Inspect input throughput, dataloader workers, preprocessing, and per-GPU batch size before requesting more GPUs."
            )
        elif gpu_util < 70:
            findings.append("GPU utilization was moderate; scaling or input stalls may be limiting throughput.")
            recommendations.append(
                "Verify rank-to-GPU mapping, batch size, and worker counts to improve device occupancy."
            )
        else:
            findings.append("GPU utilization looked healthy.")
            if cpu_eff is not None and cpu_eff < 0.6:
                recommendations.append(
                    "The job may be GPU-bound; consider reducing CPU allocation before increasing thread counts."
                )

    if alloc_gpus is not None and alloc_gpus > 0 and gpu_util is not None and gpu_util < 25 and cpu_eff is not None and cpu_eff < 0.4:
        recommendations.append(
            "Low CPU and GPU efficiency together usually indicate an upstream bottleneck such as I/O, launch overhead, or too-small batches."
        )

    if not recommendations:
        recommendations.append("No obvious right-sizing change was detected from the accounting summary alone.")

    lines.append("")
    lines.append("Findings:")
    for finding in findings or ["No strong findings from available accounting fields."]:
        lines.append(f"- {finding}")
    lines.append("")
    lines.append("Recommendations:")
    for rec in recommendations:
        lines.append(f"- {rec}")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    sacct_cmd = [
        "sacct",
        "-j",
        args.job_id,
        "--parsable2",
        "--units=M",
        f"--format={','.join(SACCT_FIELDS)}",
    ]
    sstat_cmd = [
        "sstat",
        "-j",
        f"{args.job_id}.batch",
        "--parsable2",
        "--units=M",
        f"--format={','.join(SSTAT_FIELDS)}",
    ]

    sacct_rows = normalize_rows(parse_table(load_text(args.sacct_path, sacct_cmd)))
    if not sacct_rows:
        raise SystemExit(f"No sacct rows found for job {args.job_id}")
    primary = choose_primary_step(sacct_rows, args.job_id)
    if primary is None:
        raise SystemExit(f"Could not select a primary step for job {args.job_id}")

    sstat_rows: List[Dict[str, str]] = []
    try:
        sstat_rows = parse_table(load_text(args.sstat_path, sstat_cmd))
    except SystemExit:
        if args.sstat_path:
            raise
    sstat_row = find_sstat_row(sstat_rows, args.job_id)

    print(summarize(primary, sstat_row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
