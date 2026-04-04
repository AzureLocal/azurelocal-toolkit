# Planning Tools

This folder contains design-time planning assets used before deployment starts.

## What this folder is for

Use the files here during solution sizing, capacity estimation, and architecture planning.
These are not deployment scripts and they do not change the environment.

## Files in this folder

| File | Purpose |
|------|---------|
| `S2D_Capacity_Calculator.xlsx` | Storage Spaces Direct capacity planning workbook for Azure Local clusters |

## S2D_Capacity_Calculator.xlsx

This workbook is used to estimate storage capacity and resiliency outcomes for an Azure Local cluster.

### Use this workbook to

- Calculate usable storage capacity from raw drive inputs.
- Compare resiliency options such as Two-Way Mirror, Three-Way Mirror, and Dual Parity.
- Estimate workload fit for VMs, AVD sessions, and other hosted workloads.
- Understand the footprint trade-offs between thin and thick provisioning.

### Workbook tabs

| Tab | Purpose |
|-----|---------|
| Hardware Inputs | Node count, drive count, drive size, and efficiency assumptions |
| Workload Planner | VM disk sizes, AVD profiles, workload counts, and planning inputs |
| Capacity Report | Summary of usable pool, allocated footprint, and remaining headroom |
| Volume Detail | Per-volume breakdown including resiliency and storage footprint |
| Thin Provisioning Report | Reference view for thin versus thick provisioning trade-offs |

### Key planning assumptions documented in the workbook

- Usable per drive is approximately raw capacity multiplied by `0.92` for NVMe efficiency.
- Two-Way Mirror efficiency is `50%` and requires at least 2 nodes.
- Three-Way Mirror efficiency is `33.3%` and requires at least 3 nodes.
- Dual Parity efficiency is `50%` at 4 to 6 nodes and `66.7%` at 7 or more nodes.

### Microsoft reserve recommendation

Leave one capacity drive per node unallocated, up to four drives total, so failed drives can auto-repair without waiting for hardware replacement.

## How to use this folder

1. Open the workbook in Excel.
2. Enter the planned node and drive characteristics.
3. Review the capacity and resiliency outputs.
4. Use the results to refine solution sizing before deployment work begins.
