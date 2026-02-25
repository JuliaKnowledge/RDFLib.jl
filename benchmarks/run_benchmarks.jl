"""
N3 Reasoner Benchmark Suite

Compares RDFLib.jl's N3 reasoner against EYE (SWI-Prolog).

Usage:
    julia --project=. benchmarks/run_benchmarks.jl [--eye-only] [--julia-only] [--filter PATTERN]

Environment:
    EYE_PL      Path to eye.pl  (default: ../eye/eye.pl relative to repo root)
    SWIPL       Path to swipl   (default: /opt/homebrew/bin/swipl)
    BENCH_REPS  Repetitions      (default: 5)
"""

using RDFLib
using Dates
using JSON3
using Printf
using Statistics

# ─── Configuration ────────────────────────────────────────────────────────

const REPO_ROOT = dirname(@__DIR__)
const SWIPL     = get(ENV, "SWIPL", "/opt/homebrew/bin/swipl")
const EYE_PL    = get(ENV, "EYE_PL", joinpath(REPO_ROOT, "..", "eye", "eye.pl"))
const REPS      = parse(Int, get(ENV, "BENCH_REPS", "5"))
const RESULTS_DIR = joinpath(@__DIR__, "results")

const HAS_EYE = isfile(SWIPL) && isfile(EYE_PL)

mkpath(RESULTS_DIR)

# ─── Helpers ──────────────────────────────────────────────────────────────

struct BenchResult
    name::String
    category::String
    julia_times::Vector{Float64}   # seconds
    eye_times::Vector{Float64}     # seconds
    julia_triples::Int             # new triple count
    eye_triples::Int
    equivalent::Union{Bool, Nothing}  # true if outputs match, nothing if EYE unavailable
    only_julia::Vector{String}        # triples in Julia but not EYE
    only_eye::Vector{String}          # triples in EYE but not Julia
end

function _run_eye(data_n3::String; query_n3::Union{String,Nothing}=nothing,
                  pass_only_new::Bool=true)::Tuple{String, Float64}
    HAS_EYE || return ("", NaN)
    data_file = tempname() * ".n3"
    write(data_file, data_n3)
    try
        cmd_parts = [SWIPL, "-g", "main", "-t", "halt", EYE_PL, "--", "--nope"]
        pass_only_new && push!(cmd_parts, "--pass-only-new")
        push!(cmd_parts, data_file)
        if !isnothing(query_n3)
            query_file = tempname() * ".n3"
            write(query_file, query_n3)
            push!(cmd_parts, "--query", query_file)
        end
        t0 = time_ns()
        output = read(pipeline(Cmd(cmd_parts), stderr=devnull), String)
        elapsed = (time_ns() - t0) / 1e9
        return (output, elapsed)
    catch e
        @warn "EYE failed" exception=e
        return ("", NaN)
    finally
        rm(data_file; force=true)
    end
end

function _run_julia(data_n3::String; query_n3::Union{String,Nothing}=nothing)::Tuple{RDFGraph, Float64}
    g = parse_n3(data_n3)
    qg = isnothing(query_n3) ? nothing : parse_n3(query_n3)
    # Warm-up (first call compiles)
    reason(g; query=isnothing(qg) ? nothing : qg)
    # Timed run
    t0 = time_ns()
    result = reason(g; query=isnothing(qg) ? nothing : qg)
    elapsed = (time_ns() - t0) / 1e9
    return (result, elapsed)
end

function _count_triples(output::String)::Int
    # Count N3 statements: non-empty, non-comment, non-prefix lines ending with "."
    count(line -> begin
        s = strip(line)
        !isempty(s) && !startswith(s, "#") && !startswith(s, "@prefix") &&
        !startswith(s, "@base") && endswith(s, ".")
    end, split(output, "\n"))
end

"""
Parse EYE N3 output into a set of canonical triple strings for comparison.
Each triple is normalized to full URIs: `<s> <p> <o>` or `<s> <p> "lit"`.
"""
function _parse_eye_output_to_triples(output::String)::Set{String}
    # Parse the EYE output as N3 into a graph, then extract canonical triples
    g = RDFGraph()
    try
        parse_rdf!(g, output, RDFLib.N3Format())
    catch e
        @warn "Failed to parse EYE output as N3" exception=e
        return Set{String}()
    end
    Set(_canonical_triple(t) for t in triples(g))
end

"""
Canonical string representation of a triple for comparison.
Uses full URIs and normalized literal forms.
"""
function _canonical_triple(t::Triple)::String
    s = _canonical_term(t.subject)
    p = _canonical_term(t.predicate)
    o = _canonical_term(t.object)
    "$s $p $o"
end

function _canonical_term(t::URIRef)::String
    "<$(string(t))>"
end

function _canonical_term(t::BNode)::String
    # BNode IDs differ across engines; normalize to a placeholder
    # This means BNode-heavy outputs won't compare well, but for most
    # benchmarks the output is ground terms.
    "_:bnode"
end

function _canonical_term(t::Literal)::String
    lex = t.lexical
    # Normalize numeric values to avoid "1" vs "1.0" vs "1.0e0" mismatches
    if !isnothing(t.datatype)
        dt = string(t.datatype)
        if dt in ("http://www.w3.org/2001/XMLSchema#integer",
                   "http://www.w3.org/2001/XMLSchema#int",
                   "http://www.w3.org/2001/XMLSchema#long",
                   "http://www.w3.org/2001/XMLSchema#decimal",
                   "http://www.w3.org/2001/XMLSchema#double",
                   "http://www.w3.org/2001/XMLSchema#float")
            try
                v = parse(Float64, lex)
                if isinteger(v) && isfinite(v)
                    lex = string(Int(v))
                else
                    lex = string(v)
                end
            catch; end
        end
        if !isnothing(t.language)
            return "\"$lex\"@$(t.language)"
        end
        return "\"$lex\"^^<$dt>"
    elseif !isnothing(t.language)
        return "\"$lex\"@$(t.language)"
    end
    "\"$lex\""
end

function _canonical_term(t::Formula)::String
    "<<formula>>"
end

function _canonical_term(t)::String
    string(t)
end

function run_bench(name::String, category::String, data_n3::String;
                   query_n3::Union{String,Nothing}=nothing, reps::Int=REPS)
    julia_times = Float64[]
    eye_times = Float64[]
    julia_triples = 0
    eye_triples = 0
    julia_new_set = Set{String}()
    eye_new_set = Set{String}()

    # Julia runs
    for i in 1:reps
        g = parse_n3(data_n3)
        input_data = Set(t for t in triples(g)
                         if !(t.subject isa Formula) && !(t.object isa Formula))
        qg = isnothing(query_n3) ? nothing : parse_n3(query_n3)
        t0 = time_ns()
        result = reason(g; query=isnothing(qg) ? nothing : qg)
        push!(julia_times, (time_ns() - t0) / 1e9)
        output_data = Set(triples(result))
        new_triples = setdiff(output_data, input_data)
        julia_triples = length(new_triples)
        if i == 1
            julia_new_set = Set(_canonical_triple(t) for t in new_triples)
        end
    end

    # EYE runs
    if HAS_EYE
        for i in 1:reps
            (out, t) = _run_eye(data_n3; query_n3=query_n3)
            push!(eye_times, t)
            if i == 1
                eye_triples = _count_triples(out)
                eye_new_set = _parse_eye_output_to_triples(out)
            end
        end
    end

    # Compare outputs
    equivalent = nothing
    only_julia = String[]
    only_eye = String[]
    if HAS_EYE && !isempty(eye_new_set)
        # Filter out RDF list scaffolding triples (rdf:first, rdf:rest, rdf:nil)
        # These are implementation artifacts from list patterns, not semantic output.
        rdf_list_preds = Set([
            "<http://www.w3.org/1999/02/22-rdf-syntax-ns#first>",
            "<http://www.w3.org/1999/02/22-rdf-syntax-ns#rest>",
        ])
        _is_list_scaffolding(t) = any(p -> occursin(p, t), rdf_list_preds)
        jset = filter(!_is_list_scaffolding, julia_new_set)
        eset = filter(!_is_list_scaffolding, eye_new_set)
        only_julia = sort(collect(setdiff(jset, eset)))
        only_eye   = sort(collect(setdiff(eset, jset)))
        equivalent = isempty(only_julia) && isempty(only_eye)
    end

    BenchResult(name, category, julia_times, eye_times, julia_triples, eye_triples,
                equivalent, only_julia, only_eye)
end

# ─── Benchmark Generators ────────────────────────────────────────────────

function gen_transitive_closure(depth::Int)
    lines = String[]
    push!(lines, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.")
    push!(lines, "@prefix : <http://example.org/tc#>.")
    push!(lines, "")
    # Chain: C0 subClassOf C1 subClassOf ... subClassOf C_depth
    for i in 0:depth-1
        push!(lines, ":C$i rdfs:subClassOf :C$(i+1).")
    end
    # Instances at the bottom
    for i in 1:10
        push!(lines, ":inst$i a :C0.")
    end
    push!(lines, "")
    push!(lines, "{?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.")
    push!(lines, "{?A rdfs:subClassOf ?B. ?B rdfs:subClassOf ?C} => {?A rdfs:subClassOf ?C}.")
    join(lines, "\n")
end

function gen_join_heavy(n_rules::Int, n_facts::Int)
    lines = String[]
    push!(lines, "@prefix : <http://example.org/join#>.")
    push!(lines, "")
    # Facts
    for i in 1:n_facts
        push!(lines, ":a$i :p :b$i.")
        push!(lines, ":b$i :q :c$i.")
        push!(lines, ":c$i :r :d$i.")
    end
    push!(lines, "")
    # Rules with multi-pattern bodies
    for i in 1:n_rules
        push!(lines, "{?x :p ?y. ?y :q ?z} => {?x :pq$i ?z}.")
    end
    push!(lines, "{?x :p ?y. ?y :q ?z. ?z :r ?w} => {?x :pqr ?w}.")
    join(lines, "\n")
end

function gen_math_builtins(n::Int)
    lines = String[]
    push!(lines, "@prefix math: <http://www.w3.org/2000/10/swap/math#>.")
    push!(lines, "@prefix : <http://example.org/math#>.")
    push!(lines, "")
    for i in 1:n
        push!(lines, ":val$i :hasValue $i.")
    end
    push!(lines, "")
    push!(lines, "{?x :hasValue ?v. (?v 2) math:sum ?s. (?v 3) math:product ?p} => {?x :sum2 ?s; :prod3 ?p}.")
    push!(lines, "{?x :hasValue ?v. (?v 1) math:difference ?d. ?d math:absoluteValue ?a} => {?x :absDiff ?a}.")
    join(lines, "\n")
end

function gen_string_builtins(n::Int)
    lines = String[]
    push!(lines, "@prefix string: <http://www.w3.org/2000/10/swap/string#>.")
    push!(lines, "@prefix : <http://example.org/str#>.")
    push!(lines, "")
    for i in 1:n
        push!(lines, ":item$i :label \"item_$(i)_data\".")
    end
    push!(lines, "")
    push!(lines, "{?x :label ?s. ?s string:length ?len} => {?x :len ?len}.")
    push!(lines, "{?x :label ?s. (?s \"_\") string:concatenation ?cat} => {?x :cat ?cat}.")
    join(lines, "\n")
end

function gen_list_processing(n::Int)
    lines = String[]
    push!(lines, "@prefix list: <http://www.w3.org/2000/10/swap/list#>.")
    push!(lines, "@prefix : <http://example.org/list#>.")
    push!(lines, "")
    items = join(["$i" for i in 1:n], " ")
    push!(lines, ":myList :hasItems ($items).")
    push!(lines, "")
    push!(lines, "{?x :hasItems ?L. ?L list:length ?len} => {?x :length ?len}.")
    push!(lines, "{?x :hasItems ?L. ?L list:first ?f. ?L list:last ?l} => {?x :first ?f; :last ?l}.")
    join(lines, "\n")
end

function gen_large_abox(n_instances::Int, n_classes::Int)
    lines = String[]
    push!(lines, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.")
    push!(lines, "@prefix : <http://example.org/abox#>.")
    push!(lines, "")
    # Class hierarchy
    for i in 1:n_classes-1
        push!(lines, ":Class$i rdfs:subClassOf :Class$(i+1).")
    end
    # Instances distributed across classes
    for i in 1:n_instances
        cls = ((i - 1) % n_classes) + 1
        push!(lines, ":inst$i a :Class$cls.")
        push!(lines, ":inst$i :value $i.")
    end
    push!(lines, "")
    push!(lines, "{?A rdfs:subClassOf ?B. ?S a ?A} => {?S a ?B}.")
    join(lines, "\n")
end

function gen_deep_chaining(depth::Int)
    lines = String[]
    push!(lines, "@prefix : <http://example.org/chain#>.")
    push!(lines, "")
    push!(lines, ":start :step0 true.")
    for i in 0:depth-1
        push!(lines, "{?x :step$i ?v} => {?x :step$(i+1) ?v}.")
    end
    join(lines, "\n")
end

# ─── Benchmark Definitions ───────────────────────────────────────────────

const BENCHMARKS = [
    # (name, category, generator_fn)
    ("tc_10",    "transitive_closure", () -> gen_transitive_closure(10)),
    ("tc_25",    "transitive_closure", () -> gen_transitive_closure(25)),
    ("tc_50",    "transitive_closure", () -> gen_transitive_closure(50)),
    ("tc_100",   "transitive_closure", () -> gen_transitive_closure(100)),

    ("join_10x10",   "join_heavy", () -> gen_join_heavy(10, 10)),
    ("join_10x50",   "join_heavy", () -> gen_join_heavy(10, 50)),
    ("join_10x100",  "join_heavy", () -> gen_join_heavy(10, 100)),
    ("join_5x200",   "join_heavy", () -> gen_join_heavy(5, 200)),

    ("math_50",   "math_builtins", () -> gen_math_builtins(50)),
    ("math_200",  "math_builtins", () -> gen_math_builtins(200)),
    ("math_500",  "math_builtins", () -> gen_math_builtins(500)),

    ("str_50",   "string_builtins", () -> gen_string_builtins(50)),
    ("str_200",  "string_builtins", () -> gen_string_builtins(200)),
    ("str_500",  "string_builtins", () -> gen_string_builtins(500)),

    ("list_10",   "list_processing", () -> gen_list_processing(10)),
    ("list_50",   "list_processing", () -> gen_list_processing(50)),
    ("list_100",  "list_processing", () -> gen_list_processing(100)),

    ("abox_100x5",   "large_abox", () -> gen_large_abox(100, 5)),
    ("abox_500x5",   "large_abox", () -> gen_large_abox(500, 5)),
    ("abox_1000x5",  "large_abox", () -> gen_large_abox(1000, 5)),
    ("abox_500x10",  "large_abox", () -> gen_large_abox(500, 10)),

    ("chain_10",   "deep_chaining", () -> gen_deep_chaining(10)),
    ("chain_25",   "deep_chaining", () -> gen_deep_chaining(25)),
    ("chain_50",   "deep_chaining", () -> gen_deep_chaining(50)),
    ("chain_100",  "deep_chaining", () -> gen_deep_chaining(100)),
]

# ─── Main ────────────────────────────────────────────────────────────────

function main()
    # Parse CLI args
    filter_pattern = nothing
    julia_only = false
    eye_only = false
    for arg in ARGS
        if arg == "--julia-only"
            julia_only = true
        elseif arg == "--eye-only"
            eye_only = true
        elseif arg == "--filter"
            # next arg is the pattern
        elseif !isnothing(findfirst("--filter", join(ARGS, " ")))
            idx = findfirst(a -> a == "--filter", ARGS)
            if !isnothing(idx) && idx < length(ARGS) && arg == ARGS[idx+1]
                filter_pattern = arg
            end
        end
    end
    # Simpler filter parsing
    for i in 1:length(ARGS)-1
        if ARGS[i] == "--filter"
            filter_pattern = ARGS[i+1]
        end
    end

    println("=" ^ 80)
    println("  N3 Reasoner Benchmark Suite")
    println("  Julia RDFLib.jl vs EYE (SWI-Prolog)")
    println("=" ^ 80)
    println()
    println("  SWI-Prolog: ", isfile(SWIPL) ? SWIPL : "NOT FOUND")
    println("  EYE:        ", isfile(EYE_PL) ? EYE_PL : "NOT FOUND")
    println("  EYE avail:  ", HAS_EYE)
    println("  Reps:       ", REPS)
    println()

    # Warm up Julia
    print("  Warming up Julia reasoner...")
    warmup = gen_transitive_closure(3)
    g = parse_n3(warmup)
    reason(g)
    println(" done")
    println()

    results = BenchResult[]
    for (name, category, gen_fn) in BENCHMARKS
        if !isnothing(filter_pattern) && !occursin(filter_pattern, name) && !occursin(filter_pattern, category)
            continue
        end
        print("  Running: $name ($category) ...")
        data = gen_fn()
        r = run_bench(name, category, data; reps=REPS)
        push!(results, r)

        jmed = isempty(r.julia_times) ? NaN : median(r.julia_times)
        emed = isempty(r.eye_times) ? NaN : median(r.eye_times)
        ratio = isnan(emed) || emed == 0 ? "-" : @sprintf("%.1fx", emed / jmed)
        eq_str = isnothing(r.equivalent) ? "-" : (r.equivalent ? "✅" : "❌")
        println(@sprintf(" Julia: %.4fs  EYE: %.4fs  Ratio: %s  Equiv: %s  (new: %d/%d)",
            jmed, emed, ratio, eq_str, r.julia_triples, r.eye_triples))
        # Report mismatches
        if r.equivalent === false
            n_show = 5
            if !isempty(r.only_julia)
                println("    Only in Julia ($(length(r.only_julia))):")
                for t in r.only_julia[1:min(n_show, length(r.only_julia))]
                    println("      + $t")
                end
                length(r.only_julia) > n_show && println("      ... and $(length(r.only_julia) - n_show) more")
            end
            if !isempty(r.only_eye)
                println("    Only in EYE ($(length(r.only_eye))):")
                for t in r.only_eye[1:min(n_show, length(r.only_eye))]
                    println("      - $t")
                end
                length(r.only_eye) > n_show && println("      ... and $(length(r.only_eye) - n_show) more")
            end
        end
    end

    # Print summary table
    println()
    println("=" ^ 80)
    println("  SUMMARY")
    println("=" ^ 80)
    println()
    @printf("  %-20s %-18s %10s %10s %8s %6s %8s %8s\n",
            "Benchmark", "Category", "Julia (s)", "EYE (s)", "Ratio", "Equiv", "J-new", "E-new")
    println("  ", "-" ^ 82)
    for r in results
        jmed = isempty(r.julia_times) ? NaN : median(r.julia_times)
        emed = isempty(r.eye_times) ? NaN : median(r.eye_times)
        ratio = isnan(emed) || emed == 0 ? "-" : @sprintf("%.1fx", emed / jmed)
        eq_str = isnothing(r.equivalent) ? "-" : (r.equivalent ? "✅" : "❌")
        @printf("  %-20s %-18s %10.4f %10.4f %8s %6s %8d %8d\n",
                r.name, r.category, jmed, emed, ratio, eq_str, r.julia_triples, r.eye_triples)
    end
    println()

    # Save to JSON
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    outfile = joinpath(RESULTS_DIR, "bench_$timestamp.json")
    json_results = [Dict(
        "name" => r.name,
        "category" => r.category,
        "julia_median_s" => isempty(r.julia_times) ? nothing : median(r.julia_times),
        "julia_min_s" => isempty(r.julia_times) ? nothing : minimum(r.julia_times),
        "julia_times_s" => r.julia_times,
        "eye_median_s" => isempty(r.eye_times) ? nothing : median(r.eye_times),
        "eye_min_s" => isempty(r.eye_times) ? nothing : minimum(r.eye_times),
        "eye_times_s" => r.eye_times,
        "julia_new_triples" => r.julia_triples,
        "eye_new_triples" => r.eye_triples,
        "equivalent" => r.equivalent,
        "only_in_julia" => r.only_julia,
        "only_in_eye" => r.only_eye,
    ) for r in results]
    meta = Dict(
        "timestamp" => string(now()),
        "julia_version" => string(VERSION),
        "reps" => REPS,
        "eye_available" => HAS_EYE,
        "benchmarks" => json_results,
    )
    open(outfile, "w") do io
        JSON3.pretty(io, meta)
    end
    println("  Results saved to: $outfile")
    println()
end

main()
