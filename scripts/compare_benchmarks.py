#!/usr/bin/env python3
"""
Statistical A/B comparison of two GStreamer benchmark CSV files.

Usage:
    python3 compare_benchmarks.py baseline.csv optimized.csv

Produces per-scenario Welch's t-test with:
  - sample means and standard deviations
  - mean difference and 95 % confidence interval
  - Cohen's d effect size
  - two-tailed p-value (normal approximation, valid for n >= 20)
"""

import csv
import math
import sys
from collections import defaultdict
from statistics import NormalDist, mean, stdev


def load_csv(path: str) -> dict[str, list[float]]:
    """Return {scenario: [total_cpu_s, ...]} from a benchmark CSV."""
    data: dict[str, list[float]] = defaultdict(list)
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            cpu = float(row["user_cpu_s"]) + float(row["sys_cpu_s"])
            data[row["scenario"]].append(cpu)
    return dict(data)


def welch_t(a: list[float], b: list[float]):
    """Welch's unequal-variances t-test.

    Returns (t_stat, degrees_of_freedom, p_value_two_tailed).
    Uses the normal approximation for the p-value, which is accurate for
    df > ~30 (i.e. n >= ~20 per group).
    """
    n1, n2 = len(a), len(b)
    m1, m2 = mean(a), mean(b)
    v1 = sum((x - m1) ** 2 for x in a) / (n1 - 1)
    v2 = sum((x - m2) ** 2 for x in b) / (n2 - 1)

    se = math.sqrt(v1 / n1 + v2 / n2)
    t = (m1 - m2) / se

    # Welch-Satterthwaite degrees of freedom
    df = (v1 / n1 + v2 / n2) ** 2 / (
        (v1 / n1) ** 2 / (n1 - 1) + (v2 / n2) ** 2 / (n2 - 1)
    )

    p = 2 * (1 - NormalDist().cdf(abs(t)))

    return t, df, p


def cohens_d(a: list[float], b: list[float]) -> float:
    n1, n2 = len(a), len(b)
    v1 = sum((x - mean(a)) ** 2 for x in a) / (n1 - 1)
    v2 = sum((x - mean(b)) ** 2 for x in b) / (n2 - 1)
    pooled = math.sqrt(((n1 - 1) * v1 + (n2 - 1) * v2) / (n1 + n2 - 2))
    return (mean(a) - mean(b)) / pooled if pooled else 0.0


def ci_95(a: list[float], b: list[float]) -> tuple[float, float]:
    """95 % confidence interval for the difference in means (a - b)."""
    n1, n2 = len(a), len(b)
    v1 = sum((x - mean(a)) ** 2 for x in a) / (n1 - 1)
    v2 = sum((x - mean(b)) ** 2 for x in b) / (n2 - 1)
    se = math.sqrt(v1 / n1 + v2 / n2)
    z = 1.96  # normal approx
    diff = mean(a) - mean(b)
    return diff - z * se, diff + z * se


def d_label(d: float) -> str:
    d = abs(d)
    if d < 0.2:
        return "negligible"
    if d < 0.5:
        return "small"
    if d < 0.8:
        return "medium"
    return "large"


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <baseline.csv> <optimized.csv>", file=sys.stderr)
        sys.exit(1)

    baseline = load_csv(sys.argv[1])
    optimized = load_csv(sys.argv[2])

    scenarios = sorted(set(baseline) & set(optimized))
    if not scenarios:
        print("ERROR: no matching scenarios between the two files.", file=sys.stderr)
        sys.exit(1)

    hdr = f"{'Scenario':<22} {'Base mean':>10} {'Opt mean':>10} {'Diff':>8} {'Diff%':>7} {'95% CI':>20} {'Cohen d':>9} {'p-value':>10} {'Sig?':>5}"
    sep = "-" * len(hdr)
    print(sep)
    print("A/B Comparison: Total CPU time (user + system)")
    print(f"  Baseline:  {sys.argv[1]}")
    print(f"  Optimized: {sys.argv[2]}")
    print(sep)
    print(hdr)
    print(sep)

    for sc in scenarios:
        a, b = baseline[sc], optimized[sc]
        m_a, m_b = mean(a), mean(b)
        diff = m_b - m_a
        pct = 100 * diff / m_a if m_a else 0
        t, df, p = welch_t(a, b)
        d = cohens_d(a, b)
        lo, hi = ci_95(a, b)
        sig = "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "ns"

        print(
            f"{sc:<22} {m_a:>9.4f}s {m_b:>9.4f}s {diff:>+7.4f}s {pct:>+6.1f}% "
            f"[{lo:>+.4f}, {hi:>+.4f}] {d:>+8.3f} ({d_label(d):<4}) {p:>9.6f} {sig:>5}"
        )

    print(sep)
    print("Significance: *** p<0.001  ** p<0.01  * p<0.05  ns = not significant")
    print(f"Effect size:  |d|<0.2 negligible, <0.5 small, <0.8 medium, >=0.8 large")
    print(f"Diff%: negative = optimized is faster")


if __name__ == "__main__":
    main()
