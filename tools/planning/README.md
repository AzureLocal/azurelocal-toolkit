# Planning Tools

Pre-deployment planning workbooks and calculators used during Azure Local design and sizing.

## Files

### S2D_Capacity_Calculator_6.xlsx

Storage Spaces Direct (S2D) capacity planning workbook for Azure Local clusters.

**Use this to:**
- Calculate usable storage capacity from raw NVMe drive specs
- Plan volume layout (Two-Way Mirror, Three-Way Mirror, Dual Parity)
- Size workloads (VMs, AVD sessions) against available pool capacity
- Check thin vs. thick provisioning footprint

**Tabs:**
| Tab | Purpose |
|-----|---------|
| Hardware Inputs | Node count, drive count, drive size, NVMe efficiency |
| Workload Planner | VM disk sizes, AVD profiles, volume counts |
| Capacity Report | Summary — usable pool, allocated footprint, headroom |
| Volume Detail | Per-volume breakdown with resiliency and footprint |
| Thin Provisioning Report | Educational reference on thin vs. thick trade-offs |

**Key formulas:**
- Usable per drive ≈ Raw × 0.92 (NVMe overprovisioning)
- Two-Way Mirror efficiency = 50% (min 2 nodes)
- Three-Way Mirror efficiency = 33.3% (min 3 nodes)
- Dual Parity efficiency = 50% at 4–6 nodes, 66.7% at 7+ nodes

**Microsoft reserve recommendation:** Leave 1 capacity drive per node unallocated (max 4 drives) so failed drives auto-repair without waiting for hardware replacement.
