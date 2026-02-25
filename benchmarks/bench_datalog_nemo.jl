#!/usr/bin/env julia
# Benchmark: Datalog engine vs N3 reasoner vs Nemo (Rust Datalog)
#
# Generates equivalent problems in N3 format (for Julia) and nemo .rls format (for nemo),
# then compares timing across all three engines.

using RDFLib
using Printf
using Statistics

const NMO = joinpath(@__DIR__, "..", "..", "nemo", "target", "release", "nmo")
const TMPDIR = mktempdir()

# ─── Benchmark Generators ─────────────────────────────────────────────────
# Each returns (n3_string, nemo_rls_string, expected_fact_count)

function gen_transitive(depth::Int)
    # N3
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 0:depth-1
        push!(n3_lines, ":n$i :p :n$(i+1) .")
    end
    push!(n3_lines, "{ ?x :p ?y . ?y :p ?z } => { ?x :p ?z } .")
    n3 = join(n3_lines, "\n")

    # Nemo
    rls_lines = String[]
    for i in 0:depth-1
        push!(rls_lines, "edge($i, $(i+1)) .")
    end
    push!(rls_lines, "tc(?X, ?Y) :- edge(?X, ?Y) .")
    push!(rls_lines, "tc(?X, ?Z) :- tc(?X, ?Y), edge(?Y, ?Z) .")
    push!(rls_lines, "@export tc :- csv{}.")
    rls = join(rls_lines, "\n")

    return n3, rls
end

function gen_fanout(n::Int)
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 1:n
        push!(n3_lines, ":root :child :c$i .")
    end
    push!(n3_lines, "{ ?x :child ?y } => { ?y :parent :root } .")
    n3 = join(n3_lines, "\n")

    rls_lines = String[]
    for i in 1:n
        push!(rls_lines, "child(root, c$i) .")
    end
    push!(rls_lines, "parent(?Y, root) :- child(root, ?Y) .")
    push!(rls_lines, "@export parent :- csv{}.")
    rls = join(rls_lines, "\n")

    return n3, rls
end

function gen_chain(steps::Int)
    n3_lines = ["@prefix : <http://example.org/> ."]
    push!(n3_lines, ":a :step0 :b0 .")
    for i in 1:steps-2
        push!(n3_lines, ":b$(i-1) :step$i :b$i .")
    end
    push!(n3_lines, ":b$(steps-2) :step$(steps-1) :c .")
    for i in 0:steps-2
        push!(n3_lines, "{ ?x :step$i ?y . ?y :step$(i+1) ?z } => { ?x :step$(i+1) ?z } .")
    end
    n3 = join(n3_lines, "\n")

    rls_lines = String[]
    push!(rls_lines, "step0(a, b0) .")
    for i in 1:steps-2
        push!(rls_lines, "step$i(b$(i-1), b$i) .")
    end
    push!(rls_lines, "step$(steps-1)(b$(steps-2), c) .")
    for i in 0:steps-2
        push!(rls_lines, "step$(i+1)(?X, ?Z) :- step$i(?X, ?Y), step$(i+1)(?Y, ?Z) .")
    end
    push!(rls_lines, "@export step$(steps-1) :- csv{}.")
    rls = join(rls_lines, "\n")

    return n3, rls
end

function gen_diamond(depth::Int)
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 0:depth-1
        push!(n3_lines, ":a$i :left :b$i .")
        push!(n3_lines, ":a$i :right :c$i .")
        push!(n3_lines, ":b$i :merge :d$i .")
        push!(n3_lines, ":c$i :merge :d$i .")
    end
    push!(n3_lines, "{ ?x :left ?y . ?y :merge ?z } => { ?x :diamond :z } .")
    push!(n3_lines, "{ ?x :right ?y . ?y :merge ?z } => { ?x :diamond :z } .")
    n3 = join(n3_lines, "\n")

    rls_lines = String[]
    for i in 0:depth-1
        push!(rls_lines, "left(a$i, b$i) .")
        push!(rls_lines, "right(a$i, c$i) .")
        push!(rls_lines, "merge(b$i, d$i) .")
        push!(rls_lines, "merge(c$i, d$i) .")
    end
    push!(rls_lines, "diamond(?X, ?Z) :- left(?X, ?Y), merge(?Y, ?Z) .")
    push!(rls_lines, "diamond(?X, ?Z) :- right(?X, ?Y), merge(?Y, ?Z) .")
    push!(rls_lines, "@export diamond :- csv{}.")
    rls = join(rls_lines, "\n")

    return n3, rls
end

function gen_hierarchy(depth::Int)
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 0:depth-1
        push!(n3_lines, ":c$i :subClassOf :c$(i+1) .")
    end
    push!(n3_lines, ":instance :type :c0 .")
    push!(n3_lines, "{ ?c1 :subClassOf ?c2 . ?c2 :subClassOf ?c3 } => { ?c1 :subClassOf ?c3 } .")
    push!(n3_lines, "{ ?x :type ?c . ?c :subClassOf ?d } => { ?x :type ?d } .")
    n3 = join(n3_lines, "\n")

    rls_lines = String[]
    for i in 0:depth-1
        push!(rls_lines, "subClassOf(c$i, c$(i+1)) .")
    end
    push!(rls_lines, "typeOf(instance, c0) .")
    push!(rls_lines, "subClassOf(?C1, ?C3) :- subClassOf(?C1, ?C2), subClassOf(?C2, ?C3) .")
    push!(rls_lines, "typeOf(?X, ?D) :- typeOf(?X, ?C), subClassOf(?C, ?D) .")
    push!(rls_lines, "@export subClassOf :- csv{}.")
    push!(rls_lines, "@export typeOf :- csv{}.")
    rls = join(rls_lines, "\n")

    return n3, rls
end

function gen_join(n::Int)
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 1:n
        push!(n3_lines, ":a$i :r :b$i .")
        push!(n3_lines, ":b$i :s :c$i .")
        push!(n3_lines, ":c$i :t :d$i .")
    end
    push!(n3_lines, "{ ?x :r ?y . ?y :s ?z . ?z :t ?w } => { ?x :result ?w } .")
    n3 = join(n3_lines, "\n")

    rls_lines = String[]
    for i in 1:n
        push!(rls_lines, "r(a$i, b$i) .")
        push!(rls_lines, "s(b$i, c$i) .")
        push!(rls_lines, "t(c$i, d$i) .")
    end
    push!(rls_lines, "result(?X, ?W) :- r(?X, ?Y), s(?Y, ?Z), t(?Z, ?W) .")
    push!(rls_lines, "@export result :- csv{}.")
    rls = join(rls_lines, "\n")

    return n3, rls
end

function gen_multi_rule(n::Int)
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 1:n
        push!(n3_lines, ":x :p$i :y$i .")
        push!(n3_lines, "{ ?a :p$i ?b } => { ?b :q$i ?a } .")
    end
    n3 = join(n3_lines, "\n")

    rls_lines = String[]
    for i in 1:n
        push!(rls_lines, "p$i(x, y$i) .")
        push!(rls_lines, "q$i(?B, ?A) :- p$i(?A, ?B) .")
        push!(rls_lines, "@export q$i :- csv{}.")
    end
    rls = join(rls_lines, "\n")

    return n3, rls
end

# ─── Timing ────────────────────────────────────────────────────────────────

function time_julia(n3::String, engine::Symbol; iters::Int=5)
    # Warm up
    g = parse_rdf(n3, N3Format())
    engine == :datalog ? datalog_reason(g) : reason(g)

    times = Float64[]
    for _ in 1:iters
        t = @elapsed begin
            g2 = parse_rdf(n3, N3Format())
            engine == :datalog ? datalog_reason(g2) : reason(g2)
        end
        push!(times, t)
    end
    return median(times)
end

function measure_nemo_startup()
    # Run an empty program to measure startup overhead
    empty_file = joinpath(TMPDIR, "empty.rls")
    out_dir = joinpath(TMPDIR, "empty_out")
    write(empty_file, "dummy(1) .\n@export dummy :- csv{}.\n")
    mkpath(out_dir)
    # Warm up
    read(`$NMO $empty_file -D $out_dir -o -e none`, String)
    times = Float64[]
    for _ in 1:10
        t = @elapsed read(`$NMO $empty_file -D $out_dir -o -e none`, String)
        push!(times, t * 1000)
    end
    return median(times)
end

function time_nemo(rls::String, name::String, startup_ms::Float64; iters::Int=5)
    rls_file = joinpath(TMPDIR, "$(name).rls")
    out_dir = joinpath(TMPDIR, "$(name)_out")
    write(rls_file, rls)
    mkpath(out_dir)

    # Warm up
    read(`$NMO $rls_file -D $out_dir -o -e none`, String)

    times = Float64[]
    for _ in 1:iters
        t = @elapsed begin
            read(`$NMO $rls_file -D $out_dir -o -e none`, String)
        end
        push!(times, max(0.0, t * 1000 - startup_ms))
    end
    return median(times)
end

# ─── Main ──────────────────────────────────────────────────────────────────

function main()
    if !isfile(NMO)
        println("ERROR: nmo not found at $NMO")
        println("Build with: cd nemo && cargo build --release -p nemo-cli")
        return
    end

    println("Measuring nemo startup overhead...")
    nemo_startup = measure_nemo_startup()
    @printf("Nemo startup overhead: %.1fms (subtracted from wall-clock)\n\n", nemo_startup)

    benchmarks = [
        ("Transitive d=10",   gen_transitive(10)),
        ("Transitive d=50",   gen_transitive(50)),
        ("Transitive d=100",  gen_transitive(100)),
        ("Transitive d=200",  gen_transitive(200)),
        ("Fan-out n=10",      gen_fanout(10)),
        ("Fan-out n=100",     gen_fanout(100)),
        ("Fan-out n=1000",    gen_fanout(1000)),
        ("Chain s=5",         gen_chain(5)),
        ("Chain s=10",        gen_chain(10)),
        ("Chain s=20",        gen_chain(20)),
        ("Diamond d=10",      gen_diamond(10)),
        ("Diamond d=50",      gen_diamond(50)),
        ("Diamond d=100",     gen_diamond(100)),
        ("Hierarchy d=10",    gen_hierarchy(10)),
        ("Hierarchy d=50",    gen_hierarchy(50)),
        ("Hierarchy d=100",   gen_hierarchy(100)),
        ("Transitive d=500",  gen_transitive(500)),
        ("Hierarchy d=200",   gen_hierarchy(200)),
        ("Hierarchy d=500",   gen_hierarchy(500)),
        ("Join n=10",         gen_join(10)),
        ("Join n=50",         gen_join(50)),
        ("Join n=100",        gen_join(100)),
        ("Multi-rule n=10",   gen_multi_rule(10)),
        ("Multi-rule n=50",   gen_multi_rule(50)),
        ("Multi-rule n=100",  gen_multi_rule(100)),
    ]

    println("=" ^ 100)
    println("Datalog vs N3 vs Nemo Benchmark")
    println("=" ^ 100)
    @printf("%-22s %10s %10s %10s  %8s %8s %8s\n",
            "Benchmark", "DL(ms)", "N3(ms)", "Nemo(ms)", "DL/N3", "DL/Nemo", "N3/Nemo")
    println("-" ^ 100)

    dl_n3_ratios = Float64[]
    dl_nemo_ratios = Float64[]
    n3_nemo_ratios = Float64[]
    dl_nemo_wins = 0
    n3_nemo_wins = 0

    for (i, (name, (n3, rls))) in enumerate(benchmarks)
        dl_ms = time_julia(n3, :datalog) * 1000
        n3_ms = time_julia(n3, :n3) * 1000
        nemo_ms = time_nemo(rls, "bench_$i", nemo_startup)

        dl_n3 = n3_ms / dl_ms
        dl_nemo = nemo_ms / dl_ms   # >1 means DL wins (Nemo slower)
        n3_nemo = nemo_ms / n3_ms   # >1 means N3 wins (Nemo slower)

        push!(dl_n3_ratios, dl_n3)
        push!(dl_nemo_ratios, dl_nemo)
        push!(n3_nemo_ratios, n3_nemo)
        dl_nemo > 1.0 && (dl_nemo_wins += 1)
        n3_nemo > 1.0 && (n3_nemo_wins += 1)

        @printf("%-22s %10.3f %10.3f %10.3f  %7.1f× %7.1f× %7.1f×\n",
                name, dl_ms, n3_ms, nemo_ms, dl_n3, dl_nemo, n3_nemo)
    end

    println("-" ^ 100)
    dl_n3_geo = exp(mean(log.(dl_n3_ratios)))
    @printf("Geo mean DL/N3: %.2f×\n", dl_n3_geo)
    if !isempty(dl_nemo_ratios)
        dl_nemo_geo = exp(mean(log.(dl_nemo_ratios)))
        @printf("Geo mean DL/Nemo: %.2f× (DL wins %d/%d)\n", dl_nemo_geo, dl_nemo_wins, length(dl_nemo_ratios))
    end
    if !isempty(n3_nemo_ratios)
        n3_nemo_geo = exp(mean(log.(n3_nemo_ratios)))
        @printf("Geo mean N3/Nemo: %.2f× (N3 wins %d/%d)\n", n3_nemo_geo, n3_nemo_wins, length(n3_nemo_ratios))
    end
    println("=" ^ 100)
    println("DL/N3 > 1 = Datalog faster; DL/Nemo > 1 = Julia Datalog faster than Rust nemo")
    println("N3/Nemo > 1 = Julia N3 faster than Rust nemo")
end

main()
rm(TMPDIR, recursive=true, force=true)
