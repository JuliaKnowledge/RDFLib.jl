#!/usr/bin/env julia
# Benchmark comparing Datalog engine vs N3 reasoner vs RoXi
#
# Tests pure Datalog workloads (no builtins, no backward chaining)
# using the same benchmark suite as bench_vs_roxi.jl

using RDFLib
using Printf
using Statistics

# ─── Benchmark Generation ─────────────────────────────────────────────────

function gen_transitive(depth::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    for i in 0:depth-1
        push!(lines, ":n$i :p :n$(i+1) .")
    end
    push!(lines, "{ ?x :p ?y . ?y :p ?z } => { ?x :p ?z } .")
    return join(lines, "\n")
end

function gen_fanout(n::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    for i in 1:n
        push!(lines, ":root :child :c$i .")
    end
    push!(lines, "{ ?x :child ?y } => { ?y :parent :root } .")
    return join(lines, "\n")
end

function gen_chain(steps::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    # Data: :a :step0 :b0 . :b0 :step1 :b1 . ... :b{s-2} :step{s-1} :c .
    push!(lines, ":a :step0 :b0 .")
    for i in 1:steps-2
        push!(lines, ":b$(i-1) :step$i :b$i .")
    end
    push!(lines, ":b$(steps-2) :step$(steps-1) :c .")
    # Rules: sequential chain
    for i in 0:steps-2
        push!(lines, "{ ?x :step$i ?y . ?y :step$(i+1) ?z } => { ?x :step$(i+1) ?z } .")
    end
    return join(lines, "\n")
end

function gen_diamond(depth::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    for i in 0:depth-1
        push!(lines, ":a$i :left :b$i .")
        push!(lines, ":a$i :right :c$i .")
        push!(lines, ":b$i :merge :d$i .")
        push!(lines, ":c$i :merge :d$i .")
    end
    push!(lines, "{ ?x :left ?y . ?y :merge ?z } => { ?x :diamond :z } .")
    push!(lines, "{ ?x :right ?y . ?y :merge ?z } => { ?x :diamond :z } .")
    return join(lines, "\n")
end

function gen_hierarchy(depth::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    for i in 0:depth-1
        push!(lines, ":c$i :subClassOf :c$(i+1) .")
    end
    push!(lines, ":instance :type :c0 .")
    push!(lines, "{ ?c1 :subClassOf ?c2 . ?c2 :subClassOf ?c3 } => { ?c1 :subClassOf ?c3 } .")
    push!(lines, "{ ?x :type ?c . ?c :subClassOf ?d } => { ?x :type ?d } .")
    return join(lines, "\n")
end

function gen_join(n::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    for i in 1:n
        push!(lines, ":a$i :r :b$i .")
        push!(lines, ":b$i :s :c$i .")
        push!(lines, ":c$i :t :d$i .")
    end
    push!(lines, "{ ?x :r ?y . ?y :s ?z . ?z :t ?w } => { ?x :result ?w } .")
    return join(lines, "\n")
end

function gen_multi_rule(n::Int)::String
    lines = ["@prefix : <http://example.org/> ."]
    for i in 1:n
        push!(lines, ":x :p$i :y$i .")
        push!(lines, "{ ?a :p$i ?b } => { ?b :q$i ?a } .")
    end
    return join(lines, "\n")
end

# ─── Timing ────────────────────────────────────────────────────────────────

function time_engine(n3::String, engine::Symbol; iters::Int=5)
    g = parse_rdf(n3, N3Format())
    # Warm-up
    if engine == :datalog
        datalog_reason(g)
    else
        reason(g)
    end
    times = Float64[]
    for _ in 1:iters
        g2 = parse_rdf(n3, N3Format())
        t = @elapsed begin
            if engine == :datalog
                datalog_reason(g2)
            else
                reason(g2)
            end
        end
        push!(times, t)
    end
    return median(times)
end

# ─── Main ──────────────────────────────────────────────────────────────────

function main()
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
        ("Join n=10",         gen_join(10)),
        ("Join n=50",         gen_join(50)),
        ("Join n=100",        gen_join(100)),
        ("Multi-rule n=10",   gen_multi_rule(10)),
        ("Multi-rule n=50",   gen_multi_rule(50)),
        ("Multi-rule n=100",  gen_multi_rule(100)),
    ]

    println("=" ^ 80)
    println("Datalog vs N3 Reasoner Benchmark")
    println("=" ^ 80)
    @printf("%-25s %12s %12s %10s %8s\n", "Benchmark", "Datalog(ms)", "N3(ms)", "Ratio", "Winner")
    println("-" ^ 80)

    ratios = Float64[]
    dl_wins = 0
    n3_wins = 0

    for (name, n3) in benchmarks
        dl_time = time_engine(n3, :datalog) * 1000
        n3_time = time_engine(n3, :n3) * 1000
        ratio = n3_time / dl_time  # >1 means Datalog wins
        push!(ratios, ratio)

        winner = ratio > 1.0 ? "DL" : "N3"
        if ratio > 1.0
            dl_wins += 1
        else
            n3_wins += 1
        end

        @printf("%-25s %12.3f %12.3f %9.1f× %8s\n", name, dl_time, n3_time, ratio, winner)
    end

    geo_mean = exp(mean(log.(ratios)))
    println("-" ^ 80)
    @printf("Geometric mean: %.1f× (Datalog faster)\n", geo_mean)
    @printf("Wins: Datalog %d / N3 %d (of %d)\n", dl_wins, n3_wins, length(benchmarks))
    println("=" ^ 80)
end

main()
