# CHPC GPU Hardware Reference

Source: https://www.chpc.utah.edu/documentation/guides/gpus-accelerators.php

| Architecture | Model | VRAM | gres type | Cluster(s) | Compute Cap. |
|---|---|---|---|---|---|
| Blackwell | RTX PRO 6000 Blackwell Max-Q | 96 GB | `rtxpr6000bl` | granite | — |
| Blackwell | RTX PRO 4000 Blackwell | 24 GB | `rtxpr4000bl` | granite | — |
| Grace-Hopper | GH200 | 96 GB | `gh200` | granite | 9.0 |
| Hopper | H200 | 141 GB | `h200` | granite, redwood | 9.0 |
| Hopper | H200 MIG 1/7 | 18 GB | `h200_1g.18gb` | granite, redwood | 9.0 |
| Hopper | H200 MIG 2/7 | 35 GB | `h200_2g.35gb` | granite, redwood | 9.0 |
| Hopper | H200 MIG 3/7 | 71 GB | `h200_3g.71gb` | granite, redwood | 9.0 |
| Hopper | H100 NVL | 96 GB | `h100nvl`, `h100` | granite, notchpeak, redwood | 9.0 |
| Ada Lovelace | L40 S | 48 GB | `l40s` | granite, notchpeak | 8.9 |
| Ada Lovelace | L40 | 48 GB | `l40` | notchpeak | 8.9 |
| Ada Lovelace | L4 Tensor Core | 24 GB | `l4` | granite | 8.9 |
| Ada Lovelace | RTX 6000 Ada | 48 GB | `rtx6000` | granite, notchpeak, redwood | 8.9 |
| Ada Lovelace | RTX 5000 Ada | 32 GB | `rtx5000` | granite, redwood | 8.9 |
| Ada Lovelace | RTX 4500 Ada | 24 GB | `rtx4500` | granite | 8.9 |
| Ada Lovelace | RTX 4000 Ada | 20 GB | `rtx4000ada` | granite | 8.9 |
| Ada Lovelace | RTX 2000 Ada | 16 GB | `rtx2000` | granite | 8.9 |
| Ampere | A100-SXM4-80GB | 80 GB | `a100` | notchpeak | 8.0 |
| Ampere | A100-PCIE-80GB | 80 GB | `a100` | notchpeak, redwood | 8.0 |
| Ampere | A100-SXM4-40GB | 40 GB | `a100` | redwood | 8.0 |
| Ampere | A100-PCIE-40GB | 40 GB | `a100` | notchpeak | 8.0 |
| Ampere | A800 40GB | 40 GB | `a800` | granite, notchpeak | 8.0 |
| Ampere | A40 | 48 GB | `a40` | notchpeak, redwood | 8.6 |
| Ampere | RTX A6000 | 48 GB | `a6000` | notchpeak | 8.6 |
| Ampere | RTX A5500 | 24 GB | `a5500` | notchpeak | 8.6 |
| Ampere | A30 | 24 GB | `a30` | redwood | 8.0 |
| Ampere | GeForce RTX 3090 | 24 GB | `3090` | notchpeak | 8.6 |
| Turing | GeForce RTX 2080 Ti | 11 GB | `2080ti` | notchpeak | 7.5 |
| Turing | Tesla T4 | 16 GB | `t4` | notchpeak | 7.5 |
| Volta | V100-PCIE-16GB | 16 GB | `v100` | notchpeak | 7.0 |
| Volta | TITAN V | 12 GB | `titanv` | notchpeak | 7.0 |
| Pascal | Tesla P100-PCIE-16GB | 16 GB | `p100` | kingspeak | 6.0 |
| Pascal | Tesla P40 | 24 GB | `p40` | notchpeak | 6.1 |
| Pascal | GeForce GTX 1080 Ti | 11 GB | `1080ti` | lonepeak, redwood | 6.1 |
| Maxwell | GeForce GTX Titan X | 12 GB | `titanx` | kingspeak | 5.2 |

## Notes

- **Maxwell, Pascal, Volta**: Feature-complete; offline compilation and library support will be removed in the next major CUDA Toolkit release. Avoid for new projects.
- **GH200**: Grace-Hopper — the GPU is paired with an Arm (AArch64) CPU. Software must be compiled for Arm. Not recommended unless your code is Arm-compatible.
- **MIG slices** (H200): Multi-Instance GPU — fractional partitions of a single physical GPU. Good for smaller workloads that do not need a full GPU.
- **Granite cluster**: Requires a formal allocation **and** `--qos`. Guest access exists but is preemptible.
- **Redwood cluster**: Protected/HIPAA environment — PHI/PII data only.
