#!/usr/bin/env julia
# Benchmark: Julia ProbLog vs Python ProbLog
#
# Compares accuracy and performance of our noisy-or forward inference
# against Python ProbLog's exact BDD-based inference.

using RDFLib
using Printf
using Statistics
import JSON

const PROBLOG_VENV = joinpath(@__DIR__, "..", "..", "problog", ".venv", "bin", "python3")

# ─── Test Programs ─────────────────────────────────────────────────────────

const PROGRAMS = Dict{String, String}(
    "some_heads" => """
        0.5::heads1. 0.6::heads2.
        someHeads :- heads1. someHeads :- heads2.
        query(someHeads).
    """,

    "chain_3" => """
        0.9::a. 0.8::b. 0.7::c.
        d :- a, b, c.
        query(d).
    """,

    "stressed" => """
        0.5::stressed(X) :- student(X).
        0.2::stressed(X) :- athlet(X).
        athlet(1). athlet(2). student(2). student(3).
        query(stressed(1)). query(stressed(2)). query(stressed(3)).
    """,

    "path_simple" => """
        0.9::edge(a,b). 0.8::edge(b,c).
        path(X,Y) :- edge(X,Y).
        path(X,Z) :- edge(X,Y), path(Y,Z).
        query(path(a,b)). query(path(a,c)).
    """,

    "path_diamond" => """
        0.9::edge(a,b). 0.8::edge(b,c). 0.7::edge(c,d). 0.6::edge(a,c).
        path(X,Y) :- edge(X,Y).
        path(X,Z) :- edge(X,Y), path(Y,Z).
        query(path(a,b)). query(path(a,c)). query(path(a,d)). query(path(b,c)).
    """,

    "smokers_small" => """
        0.3::stress(ann). 0.2::stress(bob).
        0.3::influences(ann,bob). 0.3::influences(bob,ann).
        smokes(X) :- stress(X).
        smokes(X) :- influences(Y,X), smokes(Y).
        query(smokes(ann)). query(smokes(bob)).
    """,

    "alarm" => """
        0.1::burglary. 0.2::earthquake.
        0.95::alarm_if_both :- burglary, earthquake.
        0.94::alarm_if_burglary :- burglary.
        0.29::alarm_if_earthquake :- earthquake.
        alarm :- alarm_if_both.
        alarm :- alarm_if_burglary.
        alarm :- alarm_if_earthquake.
        query(alarm).
    """,

    "multi_or" => """
        0.1::a1. 0.2::a2. 0.3::a3. 0.4::a4. 0.5::a5.
        b :- a1. b :- a2. b :- a3. b :- a4. b :- a5.
        query(b).
    """,
)

# ─── Python ProbLog Runner ────────────────────────────────────────────────

function run_python_problog(prog_text::String)::Tuple{Dict{String,Float64}, Float64}
    # Write program to temp file
    tmpfile = tempname() * ".pl"
    write(tmpfile, prog_text)

    py_code = """
import sys, time, json
from problog.program import PrologFile
from problog import get_evaluatable
prog = PrologFile('$tmpfile')
t0 = time.time()
result = get_evaluatable().create_from(prog).evaluate()
t1 = time.time()
out = {}
for k, v in result.items():
    out[str(k)] = float(v)
print(json.dumps({"results": out, "time_ms": (t1-t0)*1000}))
"""
    output = read(`$PROBLOG_VENV -c $py_code`, String)
    rm(tmpfile, force=true)

    data = JSON.parse(output)
    results = Dict{String,Float64}(k => v for (k,v) in data["results"])
    return results, data["time_ms"]
end

function time_python_problog(prog_text::String; iters::Int=5)::Tuple{Dict{String,Float64}, Float64}
    # Warm up
    results, _ = run_python_problog(prog_text)
    times = Float64[]
    for _ in 1:iters
        _, t = run_python_problog(prog_text)
        push!(times, t)
    end
    return results, median(times)
end

function time_julia_problog(prog_text::String; iters::Int=5)::Tuple{Dict{String,Float64}, Float64}
    # Warm up
    results = problog_query(prog_text)
    times = Float64[]
    for _ in 1:iters
        t = @elapsed problog_query(prog_text)
        push!(times, t * 1000)  # ms
    end
    return results, median(times)
end

# ─── Scaled Benchmarks ────────────────────────────────────────────────────

function gen_wide_or(n::Int)::String
    lines = String[]
    for i in 1:n
        push!(lines, "$(round(i/(n+1), digits=4))::a$i.")
        push!(lines, "b :- a$i.")
    end
    push!(lines, "query(b).")
    return join(lines, " ")
end

function gen_chain(n::Int)::String
    lines = String[]
    for i in 1:n
        push!(lines, "$(round(0.5 + 0.4*i/n, digits=4))::step$i(x,y$i).")
    end
    for i in 1:n-1
        push!(lines, "chain$i(X,Z) :- step$i(X,Y), step$(i+1)(Y,Z).")
    end
    push!(lines, "query(chain1(x,y2)).")
    return join(lines, " ")
end

function gen_grid(n::Int)::String
    lines = String[]
    # Create n×n grid of probabilistic edges
    for i in 1:n
        for j in 1:n
            p = round(0.3 + 0.5 * ((i+j) % 3) / 2, digits=2)
            push!(lines, "$(p)::edge(n$(i)_$(j),n$(i)_$(j+1)).")
            push!(lines, "$(p)::edge(n$(i)_$(j),n$(i+1)_$(j)).")
        end
    end
    push!(lines, "path(X,Y) :- edge(X,Y).")
    push!(lines, "path(X,Z) :- edge(X,Y), path(Y,Z).")
    push!(lines, "query(path(n1_1,n$(n)_$(n))).")
    return join(lines, " ")
end

function gen_smokers(n::Int)::String
    lines = String[]
    for i in 1:n
        p = round(0.1 + 0.3 * (i % 3) / 2, digits=2)
        push!(lines, "$(p)::stress(p$i).")
    end
    for i in 1:n
        for j in 1:n
            i == j && continue
            if abs(i - j) <= 2
                push!(lines, "0.3::influences(p$i,p$j).")
            end
        end
    end
    push!(lines, "smokes(X) :- stress(X).")
    push!(lines, "smokes(X) :- influences(Y,X), smokes(Y).")
    for i in 1:n
        push!(lines, "query(smokes(p$i)).")
    end
    return join(lines, " ")
end

# ─── Main ──────────────────────────────────────────────────────────────────

function main()
    if !isfile(PROBLOG_VENV)
        println("ERROR: Python ProbLog not found at $PROBLOG_VENV")
        println("Install with: cd problog && python3 -m venv .venv && source .venv/bin/activate && pip install -e .")
        return
    end

    println("=" ^ 100)
    println("Julia ProbLog vs Python ProbLog — Accuracy & Performance")
    println("=" ^ 100)

    # ── Part 1: Accuracy Comparison ──
    println("\n── Accuracy Comparison (Julia noisy-or vs Python BDD-exact) ──")
    println("-" ^ 100)
    @printf("%-20s %-25s %12s %12s %10s\n", "Program", "Query", "Julia", "Python", "Δ")
    println("-" ^ 100)

    for (name, prog) in sort(collect(PROGRAMS))
        jl_results = problog_query(prog)
        py_results, _ = run_python_problog(prog)

        for key in sort(collect(keys(jl_results)))
            jl_val = jl_results[key]
            py_val = get(py_results, key, NaN)
            delta = abs(jl_val - py_val)
            marker = delta < 1e-6 ? "✓" : (delta < 0.05 ? "~" : "✗")
            @printf("%-20s %-25s %12.6f %12.6f %9.6f %s\n",
                    name, key, jl_val, py_val, delta, marker)
        end
    end
    println("-" ^ 100)
    println("✓ = exact match, ~ = close (<0.05), ✗ = differs (expected for shared-dependency programs)")

    # ── Part 2: Performance Comparison ──
    println("\n── Performance Comparison ──")
    println("-" ^ 100)
    @printf("%-30s %12s %12s %10s\n", "Benchmark", "Julia(ms)", "Python(ms)", "Speedup")
    println("-" ^ 100)

    perf_benchmarks = [
        ("some_heads",        PROGRAMS["some_heads"]),
        ("chain_3",           PROGRAMS["chain_3"]),
        ("stressed",          PROGRAMS["stressed"]),
        ("smokers_small",     PROGRAMS["smokers_small"]),
        ("alarm",             PROGRAMS["alarm"]),
        ("multi_or",          PROGRAMS["multi_or"]),
        ("wide_or n=20",      gen_wide_or(20)),
        ("wide_or n=50",      gen_wide_or(50)),
        ("wide_or n=100",     gen_wide_or(100)),
        ("smokers n=5",       gen_smokers(5)),
        ("smokers n=10",      gen_smokers(10)),
        ("smokers n=20",      gen_smokers(20)),
    ]

    speedups = Float64[]

    for (name, prog) in perf_benchmarks
        _, jl_ms = time_julia_problog(prog)
        _, py_ms = time_python_problog(prog)
        speedup = py_ms / jl_ms
        push!(speedups, speedup)
        @printf("%-30s %12.3f %12.3f %9.1f×\n", name, jl_ms, py_ms, speedup)
    end

    geo_mean = exp(mean(log.(speedups)))
    println("-" ^ 100)
    @printf("Geometric mean speedup: %.1f×\n", geo_mean)
    println("=" ^ 100)
end

main()
