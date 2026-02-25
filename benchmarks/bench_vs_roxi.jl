#!/usr/bin/env julia
# Benchmark: RDFLib.jl N3 Reasoner vs RoXi (Rust)
#
# RoXi is a Rust-based N3/Datalog reasoner using oxigraph internals.
# It reads NTriples for data (ABox) and N3 for rules (TBox).

using RDFLib
using Printf

const ROXI_BIN = joinpath(@__DIR__, "..", "..", "roxi", "target", "release", "server")

if !isfile(ROXI_BIN)
    error("RoXi binary not found at $ROXI_BIN — run: cd roxi/server && cargo build --release")
end

# ─── Benchmark case generators ──────────────────────────────────────

struct BenchCase
    name::String
    n3_data::String       # full N3 for Julia (data + rules)
    nt_data::String       # NTriples for RoXi ABox
    n3_rules::String      # N3 rules for RoXi TBox
    expected_total::Int   # expected total triples after materialization
end

function bench_transitive(depth::Int)
    # N3 combined (for Julia)
    n3 = "@prefix : <http://example.org/> .\n"
    for i in 0:(depth-1)
        n3 *= ":s$(i+1) :in :s$i .\n"
    end
    n3 *= "{ ?a :in ?b . ?b :in ?c } => { ?a :in ?c } .\n"

    # NTriples (for RoXi ABox)
    nt = ""
    for i in 0:(depth-1)
        nt *= "<http://example.org/s$(i+1)> <http://example.org/in> <http://example.org/s$i> .\n"
    end

    # N3 rules (for RoXi TBox)
    rules = "@prefix : <http://example.org/> .\n"
    rules *= "{ ?a :in ?b . ?b :in ?c } => { ?a :in ?c } .\n"

    expected = depth + div(depth * (depth - 1), 2)
    BenchCase("Transitive d=$depth", n3, nt, rules, expected)
end

function bench_fan_out(n::Int)
    n3 = "@prefix : <http://example.org/> .\n"
    nt = ""
    for i in 1:n
        n3 *= ":e$i :type :A .\n"
        nt *= "<http://example.org/e$i> <http://example.org/type> <http://example.org/A> .\n"
    end
    n3 *= "{ ?x :type :A } => { ?x :type :B } .\n"

    rules = "@prefix : <http://example.org/> .\n"
    rules *= "{ ?x :type :A } => { ?x :type :B } .\n"

    BenchCase("Fan-out n=$n", n3, nt, rules, 2n)
end

function bench_chain(steps::Int)
    n3 = "@prefix : <http://example.org/> .\n"
    n3 *= ":start :step :s0 .\n"
    nt = "<http://example.org/start> <http://example.org/step> <http://example.org/s0> .\n"
    rules = "@prefix : <http://example.org/> .\n"
    for i in 0:(steps-1)
        n3 *= "{ ?x :step :s$i } => { ?x :step :s$(i+1) } .\n"
        rules *= "{ ?x :step :s$i } => { ?x :step :s$(i+1) } .\n"
    end
    BenchCase("Chain s=$steps", n3, nt, rules, steps + 1)
end

function bench_diamond(width::Int)
    n3 = "@prefix : <http://example.org/> .\n"
    nt = ""
    for i in 1:width
        n3 *= ":e$i :type :A .\n"
        nt *= "<http://example.org/e$i> <http://example.org/type> <http://example.org/A> .\n"
    end
    n3 *= "{ ?x :type :A } => { ?x :type :B } .\n"
    n3 *= "{ ?x :type :B } => { ?x :type :C } .\n"
    n3 *= "{ ?x :type :C } => { ?x :type :D } .\n"

    rules = "@prefix : <http://example.org/> .\n"
    rules *= "{ ?x :type :A } => { ?x :type :B } .\n"
    rules *= "{ ?x :type :B } => { ?x :type :C } .\n"
    rules *= "{ ?x :type :C } => { ?x :type :D } .\n"

    BenchCase("Diamond w=$width", n3, nt, rules, 4width)
end

function bench_hierarchy(depth::Int, instances::Int)
    n3 = "@prefix : <http://example.org/> .\n@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n"
    nt = ""
    for i in 1:instances
        n3 *= ":inst$i :type :C0 .\n"
        nt *= "<http://example.org/inst$i> <http://example.org/type> <http://example.org/C0> .\n"
    end
    rules = "@prefix : <http://example.org/> .\n"
    for i in 0:(depth-1)
        n3 *= "{ ?x :type :C$i } => { ?x :type :C$(i+1) } .\n"
        rules *= "{ ?x :type :C$i } => { ?x :type :C$(i+1) } .\n"
    end
    BenchCase("Hierarchy c=$depth i=$instances", n3, nt, rules, instances * (depth + 1))
end

function bench_join(entities::Int)
    n3 = "@prefix : <http://example.org/> .\n"
    nt = ""
    for i in 1:entities
        n3 *= ":e$i :hasA :a$i .\n:e$i :hasB :b$i .\n"
        nt *= "<http://example.org/e$i> <http://example.org/hasA> <http://example.org/a$i> .\n"
        nt *= "<http://example.org/e$i> <http://example.org/hasB> <http://example.org/b$i> .\n"
    end
    n3 *= "{ ?x :hasA ?a . ?x :hasB ?b } => { ?x :hasC :c } .\n"

    rules = "@prefix : <http://example.org/> .\n"
    rules *= "{ ?x :hasA ?a . ?x :hasB ?b } => { ?x :hasC :c } .\n"

    BenchCase("Join n=$entities", n3, nt, rules, 3entities)
end

function bench_multi_rule(entities::Int, nrules::Int)
    n3 = "@prefix : <http://example.org/> .\n"
    nt = ""
    for i in 1:entities
        n3 *= ":e$i :type :T0 .\n"
        nt *= "<http://example.org/e$i> <http://example.org/type> <http://example.org/T0> .\n"
    end
    rules = "@prefix : <http://example.org/> .\n"
    for r in 1:nrules
        n3 *= "{ ?x :type :T$(r-1) } => { ?x :type :T$r } .\n"
        rules *= "{ ?x :type :T$(r-1) } => { ?x :type :T$r } .\n"
    end
    BenchCase("Multi $(entities)e×$(nrules)r", n3, nt, rules, entities * (nrules + 1))
end

# ─── Runners ────────────────────────────────────────────────────────

function run_julia(bc::BenchCase; warmup::Int=2, iters::Int=5)
    # Warmup
    for _ in 1:warmup
        g = RDFGraph()
        parse_rdf!(g, bc.n3_data, N3Format())
        result = reason(g)
    end
    # Timed runs
    times = Float64[]
    for _ in 1:iters
        g = RDFGraph()
        parse_rdf!(g, bc.n3_data, N3Format())
        t = @elapsed result = reason(g)
        push!(times, t)
    end
    sort!(times)
    median_ms = times[div(length(times), 2) + 1] * 1000
    median_ms
end

function run_roxi(bc::BenchCase; warmup::Int=2, iters::Int=5)
    # Write temp files
    abox_path = tempname() * ".nt"
    tbox_path = tempname() * ".n3"
    write(abox_path, bc.nt_data)
    write(tbox_path, bc.n3_rules)

    times = Float64[]
    for i in 1:(warmup + iters)
        t0 = time_ns()
        output = read(`$ROXI_BIN --abox $abox_path --tbox $tbox_path`, String)
        t1 = time_ns()

        # Also parse the materialization time from output
        m = match(r"Materialization Time:\s*(.+)", output)
        if m !== nothing
            mat_str = strip(m.captures[1])
            mat_time = _parse_rust_duration(mat_str)
            if i > warmup
                push!(times, mat_time)
            end
        else
            # Fallback: use wall clock (includes process startup)
            if i > warmup
                push!(times, (t1 - t0) / 1e9)
            end
        end
    end

    rm(abox_path, force=true)
    rm(tbox_path, force=true)

    sort!(times)
    median_ms = times[div(length(times), 2) + 1] * 1000
    median_ms
end

function _parse_rust_duration(s::AbstractString)
    # Parse Rust Duration debug format: "1.23ms", "456.78µs", "1.23s", "12.34ns"
    m = match(r"^([\d.]+)(ns|µs|us|ms|s)$", s)
    m === nothing && return NaN
    val = parse(Float64, m.captures[1])
    unit = m.captures[2]
    if unit == "s"
        val
    elseif unit == "ms"
        val / 1000
    elseif unit in ("µs", "us")
        val / 1_000_000
    elseif unit == "ns"
        val / 1_000_000_000
    else
        NaN
    end
end

# ─── Main ───────────────────────────────────────────────────────────

function main()
    println("RoXi: $(read(`$ROXI_BIN --version`, String) |> strip)")
    println("=" ^ 76)
    println("  RDFLib.jl N3 Reasoner  vs  RoXi (Rust)")
    println("  2 warmup, 5 iterations, median times")
    println("=" ^ 76)
    println()

    cases = BenchCase[
        bench_transitive(5),
        bench_transitive(10),
        bench_transitive(20),
        bench_transitive(50),
        bench_fan_out(100),
        bench_fan_out(500),
        bench_fan_out(1000),
        bench_fan_out(5000),
        bench_chain(5),
        bench_chain(10),
        bench_chain(20),
        bench_chain(50),
        bench_diamond(10),
        bench_diamond(50),
        bench_diamond(100),
        bench_diamond(500),
        bench_diamond(1000),
        bench_hierarchy(5, 100),
        bench_hierarchy(10, 100),
        bench_hierarchy(5, 1000),
        bench_join(100),
        bench_join(500),
        bench_join(1000),
        bench_multi_rule(100, 5),
        bench_multi_rule(500, 5),
        bench_multi_rule(100, 20),
    ]

    println("  Benchmark                  Julia     RoXi    Ratio")
    println("  " * "-" ^52)

    ratios = Float64[]

    for bc in cases
        julia_ms = run_julia(bc)
        roxi_ms = run_roxi(bc)
        ratio = roxi_ms / julia_ms
        push!(ratios, ratio)
        arrow = ratio >= 1.0 ? "↑" : "↓"
        label = rpad(bc.name, 26)
        j_str = lpad(@sprintf("%.1f ms", julia_ms), 9)
        r_str = lpad(@sprintf("%.1f ms", roxi_ms), 9)
        rat_str = @sprintf("%.1f×", ratio)
        println("  $label $j_str $r_str    $rat_str $arrow")
    end

    geo_mean = exp(sum(log.(ratios)) / length(ratios))
    wins = count(r -> r >= 1.0, ratios)
    total = length(ratios)

    println()
    println("  " * "-" ^52)
    println("  Geometric mean:  Julia is $(@sprintf("%.1f×", geo_mean)) vs RoXi")
    println("  Julia wins:      $wins / $total benchmarks")
    println()
    println("  ↑ = Julia faster than RoXi")
    println("  ↓ = RoXi faster than Julia")
    println()
    println("✅ Benchmark complete.")
end

main()
