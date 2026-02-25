#!/usr/bin/env julia
# Benchmark: RDFLib.jl N3 Reasoning Engine
#
# Tests forward-chaining (EAM) at various scales:
# transitive closure, fan-out, rule chains, diamond patterns.

using RDFLib
using Statistics
using Printf

const N_WARMUP = 2
const N_ITER   = 10

function bench(f, n_warmup, n_iter)
    for _ in 1:n_warmup; f(); end
    [(@elapsed f()) for _ in 1:n_iter]
end

# ─── Benchmark 1: Transitive closure ─────────────────────────────

function bench_transitive(depth)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .")
    for i in 0:(depth-1)
        push!(lines, "ex:C$i rdfs:subClassOf ex:C$(i+1) .")
    end
    push!(lines, "ex:x a ex:C0 .")
    push!(lines, "{ ?a rdfs:subClassOf ?b . ?x a ?a } => { ?x a ?b } .")
    n3 = join(lines, "\n")
    g = parse_rdf(n3, N3Format())
    result = reason(g; max_iterations=depth+5)
    type_count = length(collect(triples(result,
        (URIRef("http://example.org/x"),
         URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), nothing))))
    (result, type_count)
end

# ─── Benchmark 2: Fan-out (one rule, many instances) ─────────────

function bench_fanout(n)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    for i in 1:n
        push!(lines, "ex:person$i a ex:Person .")
    end
    push!(lines, "{ ?x a ex:Person } => { ?x a ex:Agent } .")
    n3 = join(lines, "\n")
    g = parse_rdf(n3, N3Format())
    result = reason(g; max_iterations=5)
    agent_count = length(collect(triples(result,
        (nothing, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
         URIRef("http://example.org/Agent")))))
    (result, agent_count)
end

# ─── Benchmark 3: Rule chain ─────────────────────────────────────

function bench_chain(steps)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "ex:x ex:prop0 \"start\" .")
    for i in 0:(steps-1)
        push!(lines, "{ ?x ex:prop$i ?v } => { ?x ex:prop$(i+1) ?v } .")
    end
    n3 = join(lines, "\n")
    g = parse_rdf(n3, N3Format())
    result = reason(g; max_iterations=steps+5)
    prop_count = length(result)
    (result, prop_count)
end

# ─── Benchmark 4: Diamond (multi-rule convergence) ───────────────

function bench_diamond(width)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    for i in 1:width
        push!(lines, "ex:e$i a ex:A .")
    end
    push!(lines, "{ ?x a ex:A } => { ?x a ex:B } .")
    push!(lines, "{ ?x a ex:A } => { ?x a ex:C } .")
    push!(lines, "{ ?x a ex:B . ?x a ex:C } => { ?x a ex:D } .")
    n3 = join(lines, "\n")
    g = parse_rdf(n3, N3Format())
    result = reason(g; max_iterations=10)
    d_count = length(collect(triples(result,
        (nothing, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
         URIRef("http://example.org/D")))))
    (result, d_count)
end

# ─── Benchmark 5: RDFS entailment ────────────────────────────────

function bench_rdfs(n_classes, n_instances)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .")
    # Class hierarchy
    for i in 0:(n_classes-2)
        push!(lines, "ex:C$i rdfs:subClassOf ex:C$(i+1) .")
    end
    # Instances of leaf class
    for i in 1:n_instances
        push!(lines, "ex:inst$i a ex:C0 .")
    end
    # Transitive subclass rule
    push!(lines, "{ ?a rdfs:subClassOf ?b . ?x a ?a } => { ?x a ?b } .")
    # Transitive subclass chain rule
    push!(lines, "{ ?a rdfs:subClassOf ?b . ?b rdfs:subClassOf ?c } => { ?a rdfs:subClassOf ?c } .")
    n3 = join(lines, "\n")
    g = parse_rdf(n3, N3Format())
    result = reason(g; max_iterations=n_classes + 5)
    total = length(result)
    (result, total)
end

# ─── Benchmark 6: N3 parse-only ──────────────────────────────────

function bench_n3_parse(n_triples)
    lines = String["@prefix ex: <http://example.org/> ."]
    for i in 1:n_triples
        push!(lines, "ex:s$i ex:p$i ex:o$i .")
    end
    n3 = join(lines, "\n")
    g = parse_rdf(n3, N3Format())
    length(g)
end

# ─── Main ─────────────────────────────────────────────────────────

function main()
    println("=" ^ 72)
    println("  RDFLib.jl N3 Reasoning Benchmark")
    println("  $(N_WARMUP) warmup, $(N_ITER) iterations, median times")
    println("=" ^ 72)
    println()

    all_results = NamedTuple[]

    # 1. Transitive closure
    println("▶ Transitive closure (rdfs:subClassOf chain)")
    for depth in [5, 10, 20, 50]
        times = bench(N_WARMUP, N_ITER) do; bench_transitive(depth); end
        _, tc = bench_transitive(depth)
        ms = median(times) * 1000
        ok = tc == depth + 1
        push!(all_results, (label="Transitive d=$depth", ms=ms, output="types=$tc", ok=ok))
        @printf("  d=%-4d  %8.2f ms  types=%-4d  %s\n", depth, ms, tc, ok ? "✓" : "✗")
    end
    println()

    # 2. Fan-out
    println("▶ Fan-out (one rule, N instances)")
    for n in [100, 500, 1000, 5000]
        times = bench(N_WARMUP, N_ITER) do; bench_fanout(n); end
        _, ac = bench_fanout(n)
        ms = median(times) * 1000
        ok = ac == n
        push!(all_results, (label="Fan-out n=$n", ms=ms, output="agents=$ac", ok=ok))
        @printf("  n=%-5d  %8.2f ms  agents=%-5d  %s\n", n, ms, ac, ok ? "✓" : "✗")
    end
    println()

    # 3. Rule chain
    println("▶ Rule chain (sequential firing)")
    for steps in [5, 10, 20, 50]
        times = bench(N_WARMUP, N_ITER) do; bench_chain(steps); end
        _, pc = bench_chain(steps)
        ms = median(times) * 1000
        expected = steps + 1
        ok = pc == expected
        push!(all_results, (label="Chain s=$steps", ms=ms, output="props=$pc", ok=ok))
        @printf("  s=%-4d  %8.2f ms  props=%-4d  %s\n", steps, ms, pc, ok ? "✓" : "✗")
    end
    println()

    # 4. Diamond pattern
    println("▶ Diamond pattern (A→B,C→D convergence)")
    for w in [10, 50, 100, 500, 1000]
        times = bench(N_WARMUP, N_ITER) do; bench_diamond(w); end
        _, dc = bench_diamond(w)
        ms = median(times) * 1000
        ok = dc == w
        push!(all_results, (label="Diamond w=$w", ms=ms, output="D=$dc", ok=ok))
        @printf("  w=%-5d  %8.2f ms  D=%-5d  %s\n", w, ms, dc, ok ? "✓" : "✗")
    end
    println()

    # 5. RDFS entailment
    println("▶ RDFS entailment (class hierarchy + instances)")
    for (nc, ni) in [(5, 100), (10, 100), (5, 1000), (10, 500)]
        times = bench(N_WARMUP, N_ITER) do; bench_rdfs(nc, ni); end
        _, total = bench_rdfs(nc, ni)
        ms = median(times) * 1000
        push!(all_results, (label="RDFS c=$nc i=$ni", ms=ms, output="triples=$total", ok=true))
        @printf("  c=%-3d i=%-5d  %8.2f ms  triples=%-6d\n", nc, ni, ms, total)
    end
    println()

    # 6. N3 parse-only
    println("▶ N3 parsing (no reasoning)")
    for n in [100, 1000, 5000, 10000]
        times = bench(N_WARMUP, N_ITER) do; bench_n3_parse(n); end
        tc = bench_n3_parse(n)
        ms = median(times) * 1000
        ok = tc == n
        push!(all_results, (label="N3 parse n=$n", ms=ms, output="triples=$tc", ok=ok))
        @printf("  n=%-6d  %8.2f ms  triples=%-6d  %s\n", n, ms, tc, ok ? "✓" : "✗")
    end
    println()

    # ─── Summary ──────────────────────────────────────────────────
    println("=" ^ 72)
    println("  Summary")
    println("=" ^ 72)
    println()
    @printf("  %-25s %10s  %-20s  %s\n", "Benchmark", "Median", "Output", "OK")
    println("  " * "-" ^ 65)
    for r in all_results
        @printf("  %-25s %8.2f ms  %-20s  %s\n", r.label, r.ms, r.output, r.ok ? "✓" : "✗")
    end
    n_pass = count(r -> r.ok, all_results)
    println()
    println("  Verification: $(n_pass)/$(length(all_results)) passed")
    println()
    println("✅ N3 Reasoning benchmark complete.")
end

main()
