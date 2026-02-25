#!/usr/bin/env julia
# Benchmark: Jelly RDF serialization — Julia RDFLib.jl vs Python pyjelly
#
# Compares serialization and parsing performance across different graph sizes
# and also tests cross-language interoperability.

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "..", "src", "RDFLib.jl"))
using .RDFLib
using Printf

const PYTHON = joinpath(@__DIR__, "..", ".venv", "bin", "python3")
const RESULTS_DIR = joinpath(@__DIR__, "results", "jelly")

function generate_graph(n::Int)::RDFGraph
    g = RDFGraph()
    for i in 1:n
        s = URIRef("http://example.org/node$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                        URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"),
                        Literal("Person $i")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"),
                        Literal(string(20 + i % 60), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        if i > 1
            add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/knows"),
                            URIRef("http://example.org/node$(i-1)")))
        end
    end
    return g
end

function bench_julia_serialize(g::RDFGraph, reps::Int)
    # Warmup
    serialize_jelly(g)
    times = Float64[]
    sizes = Int[]
    for _ in 1:reps
        t = @elapsed data = serialize_jelly(g)
        push!(times, t)
        push!(sizes, length(data))
    end
    return minimum(times), sizes[1]
end

function bench_julia_parse(data::Vector{UInt8}, reps::Int)
    # Warmup
    parse_jelly(data)
    times = Float64[]
    counts = Int[]
    for _ in 1:reps
        t = @elapsed g = parse_jelly(data)
        push!(times, t)
        push!(counts, length(g))
    end
    return minimum(times), counts[1]
end

function bench_julia_ntriples_serialize(g::RDFGraph, reps::Int)
    serialize(g, NTriplesFormat())
    times = Float64[]
    sizes = Int[]
    for _ in 1:reps
        t = @elapsed data = serialize(g, NTriplesFormat())
        push!(times, t)
        push!(sizes, length(data))
    end
    return minimum(times), sizes[1]
end

function bench_julia_ntriples_parse(nt_str::String, reps::Int)
    parse_rdf(nt_str, NTriplesFormat())
    times = Float64[]
    for _ in 1:reps
        t = @elapsed g = parse_rdf(nt_str, NTriplesFormat())
        push!(times, t)
    end
    return minimum(times)
end

function bench_python(n::Int, reps::Int, results_dir::String)
    script = """
import sys, time, io, os
sys.path.insert(0, '.')

from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
from rdflib import Graph, URIRef, Literal, BNode, Namespace
from rdflib.namespace import RDF, FOAF, XSD

n = $n
reps = $reps

g = Graph()
for i in range(1, n+1):
    s = URIRef(f'http://example.org/node{i}')
    g.add((s, RDF.type, FOAF.Person))
    g.add((s, FOAF.name, Literal(f'Person {i}')))
    g.add((s, FOAF.age, Literal(str(20 + i % 60), datatype=XSD.integer)))
    if i > 1:
        g.add((s, FOAF.knows, URIRef(f'http://example.org/node{i-1}')))

# Jelly serialize benchmark
times_ser = []
for _ in range(reps):
    buf = io.BytesIO()
    t0 = time.perf_counter()
    g.serialize(destination=buf, format='jelly')
    t1 = time.perf_counter()
    times_ser.append(t1 - t0)
jelly_data = buf.getvalue()
jelly_size = len(jelly_data)

# Jelly parse benchmark
times_parse = []
for _ in range(reps):
    g2 = Graph()
    t0 = time.perf_counter()
    g2.parse(data=jelly_data, format='jelly')
    t1 = time.perf_counter()
    times_parse.append(t1 - t0)

# NTriples serialize benchmark
times_nt_ser = []
for _ in range(reps):
    t0 = time.perf_counter()
    nt = g.serialize(format='ntriples')
    t1 = time.perf_counter()
    times_nt_ser.append(t1 - t0)
nt_size = len(nt.encode('utf-8'))

# NTriples parse benchmark
nt_data = g.serialize(format='ntriples')
times_nt_parse = []
for _ in range(reps):
    g3 = Graph()
    t0 = time.perf_counter()
    g3.parse(data=nt_data, format='ntriples')
    t1 = time.perf_counter()
    times_nt_parse.append(t1 - t0)

# Also write jelly for interop test
with open(os.path.join('$results_dir', f'python_n{n}.jelly'), 'wb') as f:
    f.write(jelly_data)

print(f'JELLY_SER={min(times_ser):.6f}')
print(f'JELLY_PARSE={min(times_parse):.6f}')
print(f'JELLY_SIZE={jelly_size}')
print(f'NT_SER={min(times_nt_ser):.6f}')
print(f'NT_PARSE={min(times_nt_parse):.6f}')
print(f'NT_SIZE={nt_size}')
print(f'TRIPLES={len(g)}')
"""
    output = read(`$PYTHON -c $script`, String)
    results = Dict{String, Any}()
    for line in split(strip(output), "\n")
        k, v = split(line, "=")
        results[k] = occursin(".", v) ? parse(Float64, v) : parse(Int, v)
    end
    return results
end

function run_benchmarks()
    mkpath(RESULTS_DIR)

    sizes = [100, 500, 1000, 5000, 10000]
    reps = 5

    println("=" ^ 90)
    println("Jelly RDF Serialization Benchmark: Julia RDFLib.jl vs Python pyjelly")
    println("=" ^ 90)
    println()

    # Header
    println("┌─────────┬────────┬──────────────────────────────────┬──────────────────────────────────┐")
    println("│  Nodes  │Triples │  Jelly Serialize (s) [size]      │  Jelly Parse (s)                 │")
    println("│         │        │  Julia     Python     Speedup    │  Julia     Python     Speedup    │")
    println("├─────────┼────────┼──────────────────────────────────┼──────────────────────────────────┤")

    results_table = []

    for n in sizes
        print("  Benchmarking n=$n... ")

        # Generate Julia graph
        g = generate_graph(n)
        n_triples = length(g)

        # Julia benchmarks
        jl_ser_time, jl_ser_size = bench_julia_serialize(g, reps)
        jl_data = serialize_jelly(g)
        jl_parse_time, _ = bench_julia_parse(jl_data, reps)

        # NTriples comparison
        jl_nt_ser_time, jl_nt_size = bench_julia_ntriples_serialize(g, reps)
        nt_str = serialize(g, NTriplesFormat())
        jl_nt_parse_time = bench_julia_ntriples_parse(nt_str, reps)

        # Save Julia Jelly for interop test
        serialize_jelly_to_file(g, joinpath(RESULTS_DIR, "julia_n$(n).jelly"))

        # Python benchmarks
        py = bench_python(n, reps, RESULTS_DIR)

        # Interop verification
        py_jelly = read(joinpath(RESULTS_DIR, "python_n$(n).jelly"))
        g_from_py = parse_jelly(py_jelly)
        interop_ok = length(g_from_py) == n_triples

        ser_speedup = py["JELLY_SER"] / jl_ser_time
        parse_speedup = py["JELLY_PARSE"] / jl_parse_time

        row = (
            n=n, triples=n_triples,
            jl_ser=jl_ser_time, py_ser=py["JELLY_SER"], ser_speedup=ser_speedup,
            jl_parse=jl_parse_time, py_parse=py["JELLY_PARSE"], parse_speedup=parse_speedup,
            jl_size=jl_ser_size, py_size=py["JELLY_SIZE"],
            jl_nt_ser=jl_nt_ser_time, jl_nt_parse=jl_nt_parse_time,
            py_nt_ser=py["NT_SER"], py_nt_parse=py["NT_PARSE"],
            jl_nt_size=jl_nt_size, py_nt_size=py["NT_SIZE"],
            interop=interop_ok,
        )
        push!(results_table, row)

        println("done")
        @Printf.printf("│ %7d │ %6d │  %8.4f  %8.4f  %8.1fx   │  %8.4f  %8.4f  %8.1fx   │\n",
            n, n_triples, jl_ser_time, py["JELLY_SER"], ser_speedup,
            jl_parse_time, py["JELLY_PARSE"], parse_speedup)
    end

    println("└─────────┴────────┴──────────────────────────────────┴──────────────────────────────────┘")
    println()

    # Size comparison
    println("Size Comparison (bytes):")
    println("┌─────────┬────────────────────────────┬────────────────────────────┬────────────────┐")
    println("│  Nodes  │    Jelly (Julia / Python)   │  NTriples (Julia / Python) │ Jelly/NT ratio │")
    println("├─────────┼────────────────────────────┼────────────────────────────┼────────────────┤")
    for r in results_table
        jelly_avg = (r.jl_size + r.py_size) / 2
        nt_avg = (r.jl_nt_size + r.py_nt_size) / 2
        ratio = jelly_avg / nt_avg
        @Printf.printf("│ %7d │  %10d / %10d  │  %10d / %10d  │   %5.1f%%       │\n",
            r.n, r.jl_size, r.py_size, r.jl_nt_size, r.py_nt_size, ratio * 100)
    end
    println("└─────────┴────────────────────────────┴────────────────────────────┴────────────────┘")
    println()

    # NTriples vs Jelly speed comparison
    println("Jelly vs NTriples Speed (Julia only):")
    println("┌─────────┬──────────────────────────────┬──────────────────────────────┐")
    println("│  Nodes  │  Serialize: Jelly / NT (×)    │  Parse: Jelly / NT (×)       │")
    println("├─────────┼──────────────────────────────┼──────────────────────────────┤")
    for r in results_table
        @Printf.printf("│ %7d │  %8.4f / %8.4f (%4.1fx)│  %8.4f / %8.4f (%4.1fx)│\n",
            r.n, r.jl_ser, r.jl_nt_ser, r.jl_nt_ser / r.jl_ser,
            r.jl_parse, r.jl_nt_parse, r.jl_nt_parse / r.jl_parse)
    end
    println("└─────────┴──────────────────────────────┴──────────────────────────────┘")
    println()

    # Interop results
    println("Cross-language interop:")
    for r in results_table
        status = r.interop ? "✅" : "❌"
        println("  n=$(r.n): Python→Julia $(status) ($(r.triples) triples)")
    end
    println()

    # Write summary
    open(joinpath(RESULTS_DIR, "summary.txt"), "w") do f
        println(f, "Jelly Benchmark Results")
        println(f, "=" ^ 50)
        for r in results_table
            println(f, "n=$(r.n): triples=$(r.triples)")
            println(f, "  Jelly serialize: Julia=$(r.jl_ser)s Python=$(r.py_ser)s speedup=$(r.ser_speedup)x")
            println(f, "  Jelly parse:     Julia=$(r.jl_parse)s Python=$(r.py_parse)s speedup=$(r.parse_speedup)x")
            println(f, "  Jelly size:      Julia=$(r.jl_size) Python=$(r.py_size)")
            println(f, "  NT size:         Julia=$(r.jl_nt_size) Python=$(r.py_nt_size)")
            println(f, "  Interop:         $(r.interop)")
        end
    end
    println("Results written to $RESULTS_DIR")
end

run_benchmarks()
