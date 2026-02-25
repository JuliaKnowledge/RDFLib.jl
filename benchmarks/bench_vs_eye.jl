#!/usr/bin/env julia
# Benchmark: RDFLib.jl N3 Reasoner vs EYE (SWI-Prolog)
#
# Compares forward-chaining reasoning performance across multiple
# scenarios at various scales.

using RDFLib
using Statistics
using Printf

const EYE = joinpath(@__DIR__, "..", "..", "eye", "local", "bin", "eye")
const N_WARMUP = 2
const N_ITER   = 5
const TMPDIR   = mktempdir()

# ─── Helpers ──────────────────────────────────────────────────────

function bench(f, n_warmup, n_iter)
    for _ in 1:n_warmup; f(); end
    [(@elapsed f()) for _ in 1:n_iter]
end

function eye_reason(n3_file; pass_only_new=true)
    args = ["--nope"]
    pass_only_new && push!(args, "--pass-only-new")
    cmd = `$EYE $args $n3_file`
    out = IOBuffer()
    err = IOBuffer()
    run(pipeline(cmd, stdout=out, stderr=err))
    String(take!(out))
end

function julia_reason(n3_str; pass_only_new=false)
    g = parse_rdf(n3_str, N3Format())
    result = reason(g; max_iterations=1000, pass_only_new=pass_only_new)
    result
end

function write_n3(name, content)
    path = joinpath(TMPDIR, name)
    write(path, content)
    path
end

function count_output_triples(eye_output::String)
    # Count non-comment, non-blank lines that look like triples
    lines = split(eye_output, '\n')
    count(l -> !isempty(strip(l)) && !startswith(strip(l), '#') && !startswith(strip(l), '@'), lines)
end

# ─── Generate N3 test files ──────────────────────────────────────

function gen_transitive(depth)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .")
    push!(lines, "")
    for i in 0:(depth-1)
        push!(lines, "ex:C$i rdfs:subClassOf ex:C$(i+1) .")
    end
    push!(lines, "ex:x a ex:C0 .")
    push!(lines, "")
    push!(lines, "{ ?a rdfs:subClassOf ?b . ?x a ?a } => { ?x a ?b } .")
    join(lines, "\n") * "\n"
end

function gen_fanout(n)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "")
    for i in 1:n
        push!(lines, "ex:person$i a ex:Person .")
    end
    push!(lines, "")
    push!(lines, "{ ?x a ex:Person } => { ?x a ex:Agent } .")
    join(lines, "\n") * "\n"
end

function gen_chain(steps)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "")
    push!(lines, "ex:x ex:prop0 \"start\" .")
    push!(lines, "")
    for i in 0:(steps-1)
        push!(lines, "{ ?x ex:prop$i ?v } => { ?x ex:prop$(i+1) ?v } .")
    end
    join(lines, "\n") * "\n"
end

function gen_diamond(width)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "")
    for i in 1:width
        push!(lines, "ex:e$i a ex:A .")
    end
    push!(lines, "")
    push!(lines, "{ ?x a ex:A } => { ?x a ex:B } .")
    push!(lines, "{ ?x a ex:A } => { ?x a ex:C } .")
    push!(lines, "{ ?x a ex:B . ?x a ex:C } => { ?x a ex:D } .")
    join(lines, "\n") * "\n"
end

function gen_rdfs(n_classes, n_instances)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .")
    push!(lines, "")
    for i in 0:(n_classes-2)
        push!(lines, "ex:C$i rdfs:subClassOf ex:C$(i+1) .")
    end
    push!(lines, "")
    for i in 1:n_instances
        push!(lines, "ex:inst$i a ex:C0 .")
    end
    push!(lines, "")
    push!(lines, "{ ?a rdfs:subClassOf ?b . ?x a ?a } => { ?x a ?b } .")
    push!(lines, "{ ?a rdfs:subClassOf ?b . ?b rdfs:subClassOf ?c } => { ?a rdfs:subClassOf ?c } .")
    join(lines, "\n") * "\n"
end

function gen_multi_rule(n_entities, n_rules)
    lines = String[]
    push!(lines, "@prefix ex: <http://example.org/> .")
    push!(lines, "")
    for i in 1:n_entities
        push!(lines, "ex:e$i a ex:Type0 .")
    end
    push!(lines, "")
    for r in 0:(n_rules-1)
        push!(lines, "{ ?x a ex:Type$r } => { ?x a ex:Type$(r+1) } .")
    end
    join(lines, "\n") * "\n"
end

# ─── Run benchmarks ──────────────────────────────────────────────

function main()
    # Check EYE
    if !isfile(EYE)
        println("❌ EYE not found at $EYE")
        return
    end
    eye_ver = strip(read(`$EYE --version`, String))
    
    println("=" ^ 76)
    println("  RDFLib.jl N3 Reasoner  vs  $eye_ver")
    println("  $(N_WARMUP) warmup, $(N_ITER) iterations, median times")
    println("=" ^ 76)
    println()

    results = NamedTuple[]

    benchmarks = [
        # (label, generator, params...)
        ("Transitive d=5",    gen_transitive, 5),
        ("Transitive d=10",   gen_transitive, 10),
        ("Transitive d=20",   gen_transitive, 20),
        ("Transitive d=50",   gen_transitive, 50),
        ("Fan-out n=100",     gen_fanout, 100),
        ("Fan-out n=500",     gen_fanout, 500),
        ("Fan-out n=1000",    gen_fanout, 1000),
        ("Fan-out n=5000",    gen_fanout, 5000),
        ("Chain s=5",         gen_chain, 5),
        ("Chain s=10",        gen_chain, 10),
        ("Chain s=20",        gen_chain, 20),
        ("Chain s=50",        gen_chain, 50),
        ("Diamond w=10",      gen_diamond, 10),
        ("Diamond w=50",      gen_diamond, 50),
        ("Diamond w=100",     gen_diamond, 100),
        ("Diamond w=500",     gen_diamond, 500),
        ("Diamond w=1000",    gen_diamond, 1000),
        ("RDFS c=5 i=100",    gen_rdfs, 5, 100),
        ("RDFS c=10 i=100",   gen_rdfs, 10, 100),
        ("RDFS c=5 i=1000",   gen_rdfs, 5, 1000),
        ("Multi 100e×5r",     gen_multi_rule, 100, 5),
        ("Multi 500e×5r",     gen_multi_rule, 500, 5),
        ("Multi 100e×20r",    gen_multi_rule, 100, 20),
    ]

    @printf("  %-22s %9s %9s %8s\n", "Benchmark", "Julia", "EYE", "Ratio")
    println("  " * "-" ^ 52)

    for entry in benchmarks
        label = entry[1]
        gen = entry[2]
        args = entry[3:end]
        
        n3 = gen(args...)
        n3_file = write_n3("$(replace(label, ' '=>'_')).n3", n3)

        # Julia benchmark
        t_julia = bench(N_WARMUP, N_ITER) do
            julia_reason(n3; pass_only_new=true)
        end
        ms_j = median(t_julia) * 1000

        # EYE benchmark
        t_eye = try
            bench(N_WARMUP, N_ITER) do
                eye_reason(n3_file; pass_only_new=true)
            end
        catch e
            println("  ⚠ EYE failed on $label: $e")
            nothing
        end
        
        if t_eye !== nothing
            ms_e = median(t_eye) * 1000
            ratio = ms_e / ms_j
            push!(results, (label=label, julia_ms=ms_j, eye_ms=ms_e, ratio=ratio))
            marker = ratio > 1.0 ? "↑" : "↓"
            @printf("  %-22s %7.1f ms %7.1f ms  %5.1f× %s\n", 
                    label, ms_j, ms_e, ratio, marker)
        else
            push!(results, (label=label, julia_ms=ms_j, eye_ms=NaN, ratio=NaN))
            @printf("  %-22s %7.1f ms %9s  %s\n", label, ms_j, "FAIL", "")
        end
    end

    # ─── Summary ──────────────────────────────────────────────────
    valid = filter(r -> !isnan(r.ratio), results)
    if !isempty(valid)
        geo_mean = exp(mean(log.(getfield.(valid, :ratio))))
        wins = count(r -> r.ratio > 1.0, valid)
        println()
        println("  " * "-" ^ 52)
        @printf("  Geometric mean:  Julia is %.1f× vs EYE\n", geo_mean)
        @printf("  Julia wins:      %d / %d benchmarks\n", wins, length(valid))
        
        # Ratio > 1 means EYE is slower → Julia is faster
        println()
        if wins > 0
            println("  ↑ = Julia faster than EYE")
        end
        loses = count(r -> r.ratio < 1.0, valid)
        if loses > 0
            println("  ↓ = EYE faster than Julia")
        end
    end

    println()
    println("✅ Benchmark complete.")
    
    # Cleanup
    rm(TMPDIR, recursive=true, force=true)
end

main()
