# RDFLib.jl Benchmarks

Benchmarks comparing RDFLib.jl's N3 reasoner against other implementations.

## Quick Start

```bash
cd RDFLib.jl
julia --project=. benchmarks/run_benchmarks.jl
```

## Benchmark Categories

| Benchmark | Description |
|-----------|-------------|
| `transitive_closure` | RDFS subclass chains of increasing depth |
| `join_heavy` | Rules with multi-pattern bodies requiring joins |
| `math_builtins` | Arithmetic builtin evaluation throughput |
| `string_builtins` | String builtin evaluation throughput |
| `list_processing` | List manipulation via list builtins |
| `large_abox` | Reasoning over large instance data with few rules |
| `deep_chaining` | Long rule-firing chains |
| `w3c_suite` | Full W3C N3 reasoner test suite |

## Compared Engines

- **RDFLib.jl** — Julia N3 reasoner (this package)
- **EYE** — SWI-Prolog-based N3 reasoner (`eye.pl`)

## Output

Results are written to `benchmarks/results/` as JSON and a summary table
is printed to stdout.
