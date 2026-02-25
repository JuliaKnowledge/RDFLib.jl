#!/usr/bin/env julia
# ─── RDFLib.jl vs Python rdflib comprehensive benchmarks ──────────
# Compares: graph ops, serialization, parsing, SPARQL, reasoning

using Printf

const PYTHON = joinpath(@__DIR__, "..", ".venv", "bin", "python3")
const PROJECT = joinpath(@__DIR__, "..")

# ─── Helpers ──────────────────────────────────────────────────────

function julia_bench(code::String; setup::String="", warmup::Int=1, trials::Int=5)
    full = """
    include("src/RDFLib.jl"); using .RDFLib
    $setup
    # warmup
    for _ in 1:$warmup; $code; end
    # measure
    times = Float64[]
    for _ in 1:$trials
        t = @elapsed begin $code end
        push!(times, t)
    end
    println(minimum(times))
    """
    try
        out = strip(read(`julia --project=$PROJECT -e $full`, String))
        parse(Float64, out)
    catch
        return NaN
    end
end

function python_bench(code::String; setup::String="", warmup::Int=1, trials::Int=5)
    full = """
import time
$setup
# warmup
for _ in range($warmup):
    $code
# measure
times = []
for _ in range($trials):
    t0 = time.perf_counter()
    $code
    times.append(time.perf_counter() - t0)
print(min(times))
"""
    try
        out = strip(read(`$PYTHON -c $full`, String))
        parse(Float64, out)
    catch
        return NaN
    end
end

function fmt_time(t::Float64)
    if t < 0.001
        @sprintf("%.1fμs", t * 1e6)
    elseif t < 1.0
        @sprintf("%.1fms", t * 1e3)
    else
        @sprintf("%.2fs", t)
    end
end

function fmt_ratio(jl::Float64, py::Float64)
    r = py / jl
    if r >= 1.0
        @sprintf("%.1f×", r)
    else
        @sprintf("%.2f×", r)
    end
end

function print_result(name::String, jl::Float64, py::Float64; unit::String="")
    if isnan(jl) && isnan(py)
        @printf("  %-40s  %10s  %10s  %s\n", name, "N/A", "N/A", "⚪ (both errored)")
        return
    elseif isnan(jl)
        @printf("  %-40s  %10s  %10s  %s\n", name, "N/A", fmt_time(py), "⚪ (Julia error)")
        return
    elseif isnan(py)
        @printf("  %-40s  %10s  %10s  %s\n", name, fmt_time(jl), "N/A", "⚪ (Python error)")
        return
    end
    ratio = py / jl
    bar = ratio >= 1.0 ? "🟢" : "🔴"
    extra = isempty(unit) ? "" : " ($unit)"
    @printf("  %-40s  %10s  %10s  %s %s%s\n", name, fmt_time(jl), fmt_time(py), bar, fmt_ratio(jl, py), extra)
end

# ─── Correctness verification helpers ────────────────────────────

function julia_eval(code::String; setup::String="")
    full = """
    include("src/RDFLib.jl"); using .RDFLib
    $setup
    $code
    """
    try
        strip(read(`julia --project=$PROJECT -e $full`, String))
    catch
        "ERROR"
    end
end

function python_eval(code::String; setup::String="")
    full = """
$setup
$code
"""
    try
        strip(read(pipeline(`$PYTHON -c $full`, stderr=devnull), String))
    catch
        "ERROR"
    end
end

function verify(name::String, jl_val::AbstractString, py_val::AbstractString)
    status = jl_val == py_val ? "✅" : "❌"
    if jl_val == py_val
        @printf("  %s %-50s Julia=%s  Python=%s\n", status, name, jl_val, py_val)
    else
        @printf("  %s %-50s Julia=%s  Python=%s  ⚠ MISMATCH\n", status, name, jl_val, py_val)
    end
    jl_val == py_val
end

# ─── Run benchmarks ──────────────────────────────────────────────

function main()
    println("=" ^ 90)
    println("  RDFLib.jl vs Python rdflib — Benchmark Suite")
    println("  Julia $(VERSION) | Python rdflib 7.x | $(Sys.MACHINE)")
    println("=" ^ 90)
    println()

    # ── 0. Correctness Verification ──────────────────────────────
    println("┌─ Correctness Verification ───────────────────────────────────────────────────────┐")
    all_pass = true

    # Graph construction: verify triple count
    for n in [1000, 10000]
        jl = julia_eval("println(length(g))"; setup="""
            g = RDFGraph()
            for i in 1:$n; add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/p"), Literal(string(i)))); end
        """)
        py = python_eval("print(len(g))"; setup="""
from rdflib import Graph, URIRef, Literal
g = Graph()
for i in range($n):
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/p'), Literal(str(i))))
""")
        all_pass &= verify("Graph($n): triple count", jl, py)
    end

    # Pattern matching: verify result counts
    pm_setup_jl = """
    g = RDFGraph()
    for i in 1:10000
        add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/type"), URIRef("http://ex.org/T")))
        add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/name"), Literal("N\$i")))
    end
    """
    pm_setup_py = """
from rdflib import Graph, URIRef, Literal
g = Graph()
for i in range(10000):
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/type'), URIRef('http://ex.org/T')))
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/name'), Literal(f'N{i}')))
"""
    jl = julia_eval("println(length(collect(triples(g, (nothing, URIRef(\"http://ex.org/type\"), nothing)))))"; setup=pm_setup_jl)
    py = python_eval("print(len(list(g.triples((None, URIRef('http://ex.org/type'), None)))))"; setup=pm_setup_py)
    all_pass &= verify("Pattern(?s, :type, ?o): result count", jl, py)

    jl = julia_eval("println(length(collect(triples(g, (URIRef(\"http://ex.org/s500\"), nothing, nothing)))))"; setup=pm_setup_jl)
    py = python_eval("print(len(list(g.triples((URIRef('http://ex.org/s500'), None, None)))))"; setup=pm_setup_py)
    all_pass &= verify("Pattern(:s500, ?p, ?o): result count", jl, py)

    # Serialization roundtrip: serialize then count triples
    ser_setup_jl = """
    g = RDFGraph()
    for i in 1:1000
        s = URIRef("http://example.org/node\$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Person \$i")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"), Literal(string(20 + i % 60), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
    end
    """
    ser_setup_py = """
from rdflib import Graph, URIRef, Literal, Namespace
from rdflib.namespace import RDF, FOAF, XSD
g = Graph()
for i in range(1, 1001):
    s = URIRef(f'http://example.org/node{i}')
    g.add((s, RDF.type, FOAF.Person))
    g.add((s, FOAF.name, Literal(f'Person {i}')))
    g.add((s, FOAF.age, Literal(str(20 + i % 60), datatype=XSD.integer)))
"""
    for (fmt_name, jl_ser, jl_parse, py_fmt) in [
        ("N-Triples", "serialize(g, NTriplesFormat())", "parse_rdf(s, NTriplesFormat())", "nt"),
        ("Turtle",    "serialize(g, TurtleFormat())",   "parse_rdf(s, TurtleFormat())",   "turtle"),
        ("JSON-LD",   "serialize(g, JSONLDFormat())",   "parse_rdf(s, JSONLDFormat())",   "json-ld"),
        ("RDF/XML",   "serialize(g, RDFXMLFormat())",   "parse_rdf(s, RDFXMLFormat())",   "xml"),
    ]
        jl = julia_eval("s = $jl_ser; g2 = $jl_parse; println(length(g2))"; setup=ser_setup_jl)
        py = python_eval("s = g.serialize(format='$py_fmt'); g2 = Graph(); g2.parse(data=s, format='$py_fmt'); print(len(g2))"; setup=ser_setup_py)
        all_pass &= verify("Roundtrip $fmt_name: triple count", jl, py)
    end

    # Jelly roundtrip
    jl = julia_eval("b = serialize_jelly(g); g2 = parse_jelly(b); println(length(g2))"; setup=ser_setup_jl)
    py = python_eval("""
import io
from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
buf = io.BytesIO()
g.serialize(destination=buf, format='jelly')
g2 = Graph()
g2.parse(data=buf.getvalue(), format='jelly')
print(len(g2))
"""; setup=ser_setup_py)
    all_pass &= verify("Roundtrip Jelly: triple count", jl, py)

    # Cross-language parsing: Julia serialized → Python parsed (and vice versa)
    # Generate files with Julia
    julia_eval("""
    g = RDFGraph()
    for i in 1:500
        s = URIRef("http://example.org/node\$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Person \$i")))
    end
    write("/tmp/verify_jl.nt", serialize(g, NTriplesFormat()))
    write("/tmp/verify_jl.jsonld", serialize(g, JSONLDFormat()))
    write("/tmp/verify_jl.rdf", serialize(g, RDFXMLFormat()))
    write("/tmp/verify_jl.jelly", serialize_jelly(g))
    """)

    # Python reads Julia output — test each format individually
    for (fmt, py_fmt, path) in [("N-Triples", "nt", "/tmp/verify_jl.nt"),
                         ("JSON-LD",   "json-ld", "/tmp/verify_jl.jsonld"),
                         ("RDF/XML",   "xml", "/tmp/verify_jl.rdf"),
                         ("Jelly",     "jelly", "/tmp/verify_jl.jelly")]
        py_setup = fmt == "Jelly" ? """
from rdflib import Graph
from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
""" : "from rdflib import Graph"
        py = python_eval("g = Graph(); g.parse('$path', format='$py_fmt'); print(len(g))"; setup=py_setup)
        all_pass &= verify("Cross-lang Julia→Python $fmt", "1000", py)
    end

    # Python generates, Julia reads
    python_eval("""
g = Graph()
for i in range(1, 501):
    s = URIRef(f'http://example.org/node{i}')
    g.add((s, RDF.type, FOAF.Person))
    g.add((s, FOAF.name, Literal(f'Person {i}')))
g.serialize('/tmp/verify_py.nt', format='nt')
g.serialize('/tmp/verify_py.jsonld', format='json-ld')
g.serialize('/tmp/verify_py.rdf', format='xml')
import io
buf = io.BytesIO()
g.serialize(destination=buf, format='jelly')
open('/tmp/verify_py.jelly', 'wb').write(buf.getvalue())
"""; setup="""
from rdflib import Graph, URIRef, Literal
from rdflib.namespace import RDF, FOAF
from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
""")

    # Julia reads Python output — test each format individually
    for (fmt, jl_fmt, path) in [("N-Triples", "NTriplesFormat()", "/tmp/verify_py.nt"),
                                 ("JSON-LD",   "JSONLDFormat()",   "/tmp/verify_py.jsonld"),
                                 ("RDF/XML",   "RDFXMLFormat()",   "/tmp/verify_py.rdf")]
        jl = julia_eval("g = parse_rdf(read(\"$path\", String), $jl_fmt); println(length(g))")
        all_pass &= verify("Cross-lang Python→Julia $fmt", "1000", jl)
    end
    jl = julia_eval("g = parse_jelly(read(\"/tmp/verify_py.jelly\")); println(length(g))")
    all_pass &= verify("Cross-lang Python→Julia Jelly", "1000", jl)

    # SPARQL query result counts
    sparql_verify_jl = """
    g = RDFGraph()
    for i in 1:5000
        s = URIRef("http://example.org/node\$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Person \$i")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"), Literal(string(20 + i % 60), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        if i > 1
            add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/knows"), URIRef("http://example.org/node\$(i-1)")))
        end
    end
    """
    sparql_verify_py = """
from rdflib import Graph, URIRef, Literal
from rdflib.namespace import RDF, FOAF, XSD
g = Graph()
for i in range(1, 5001):
    s = URIRef(f'http://example.org/node{i}')
    g.add((s, RDF.type, FOAF.Person))
    g.add((s, FOAF.name, Literal(f'Person {i}')))
    g.add((s, FOAF.age, Literal(str(20 + i % 60), datatype=XSD.integer)))
    if i > 1:
        g.add((s, FOAF.knows, URIRef(f'http://example.org/node{i-1}')))
"""
    sparql_queries = [
        ("SELECT simple BGP",
            "SELECT ?s ?name WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name }"),
        ("SELECT FILTER",
            "SELECT ?s ?age WHERE { ?s <http://xmlns.com/foaf/0.1/age> ?age FILTER(?age > 50) }"),
        ("SELECT OPTIONAL",
            "SELECT ?s ?name ?knows WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name OPTIONAL { ?s <http://xmlns.com/foaf/0.1/knows> ?knows } }"),
        ("SELECT DISTINCT",
            "SELECT DISTINCT ?age WHERE { ?s <http://xmlns.com/foaf/0.1/age> ?age }"),
        ("ORDER BY LIMIT",
            "SELECT ?s ?name WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name } ORDER BY ?name LIMIT 100"),
        ("CONSTRUCT LIMIT",
            "CONSTRUCT { ?s <http://ex.org/label> ?n } WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?n } LIMIT 1000"),
    ]
    for (name, q) in sparql_queries
        if startswith(q, "CONSTRUCT")
            jl = julia_eval("r = sparql_query(g, \"\"\"$q\"\"\"); println(length(r))"; setup=sparql_verify_jl)
            py = python_eval("r = g.query('''$q'''); print(len(r))"; setup=sparql_verify_py)
        else
            jl = julia_eval("r = sparql_query(g, \"\"\"$q\"\"\"); println(length(r))"; setup=sparql_verify_jl)
            py = python_eval("r = g.query('''$q'''); print(len(list(r)))"; setup=sparql_verify_py)
        end
        all_pass &= verify("SPARQL $name: result count", jl, py)
    end

    # SPARQL Update: verify final graph state
    jl = julia_eval("""
    g2 = RDFGraph()
    for i in 1:100; add!(g2, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/p"), Literal(string(i)))); end
    sparql_update(g2, "DELETE { ?s <http://ex.org/p> ?o } WHERE { ?s <http://ex.org/p> ?o }")
    println(length(g2))
    """)
    py = python_eval("""
from rdflib import Graph, URIRef, Literal
g2 = Graph()
for i in range(100):
    g2.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/p'), Literal(str(i))))
g2.update('DELETE { ?s <http://ex.org/p> ?o } WHERE { ?s <http://ex.org/p> ?o }')
print(len(g2))
""")
    all_pass &= verify("DELETE WHERE: final graph size", jl, py)

    jl = julia_eval("""
    g2 = RDFGraph()
    sparql_update(g2, "INSERT DATA { <http://ex.org/s1> <http://ex.org/p> 1 . <http://ex.org/s2> <http://ex.org/p> 2 . }")
    println(length(g2))
    """)
    py = python_eval("""
from rdflib import Graph
g2 = Graph()
g2.update('INSERT DATA { <http://ex.org/s1> <http://ex.org/p> 1 . <http://ex.org/s2> <http://ex.org/p> 2 . }')
print(len(g2))
""")
    all_pass &= verify("INSERT DATA: final graph size", jl, py)

    # Isomorphism
    jl = julia_eval("""
    g1 = RDFGraph(); g2 = RDFGraph()
    for i in 1:100
        add!(g1, Triple(BNode("b\$i"), URIRef("http://ex.org/p"), Literal(string(i))))
        add!(g2, Triple(BNode("x\$i"), URIRef("http://ex.org/p"), Literal(string(i))))
    end
    println(isomorphic(g1, g2))
    """)
    py = python_eval("""
from rdflib import Graph, BNode, URIRef, Literal
from rdflib.compare import isomorphic
g1 = Graph(); g2 = Graph()
for i in range(100):
    g1.add((BNode(f'b{i}'), URIRef('http://ex.org/p'), Literal(str(i))))
    g2.add((BNode(f'x{i}'), URIRef('http://ex.org/p'), Literal(str(i))))
print(isomorphic(g1, g2))
""")
    all_pass &= verify("Isomorphic (100 bnodes)", jl, py == "True" ? "true" : py)

    # Clean up verify files
    for f in ["/tmp/verify_jl.nt", "/tmp/verify_jl.jsonld", "/tmp/verify_jl.rdf", "/tmp/verify_jl.jelly",
              "/tmp/verify_py.nt", "/tmp/verify_py.jsonld", "/tmp/verify_py.rdf", "/tmp/verify_py.jelly"]
        isfile(f) && rm(f)
    end

    println()
    if all_pass
        println("  ✅ All correctness checks passed!")
    else
        println("  ⚠  Some correctness checks failed — review above")
    end
    println()

    # ── 1. Graph Construction ────────────────────────────────────
    println("┌─ Graph Construction ─────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    for n in [1000, 10000, 100000]
        jl = julia_bench("begin g2 = RDFGraph(); for i in 1:$n; add!(g2, Triple(URIRef(\"http://ex.org/s\$i\"), URIRef(\"http://ex.org/p\"), Literal(string(i)))); end; end")

        py = python_bench("g2 = Graph(); [g2.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/p'), Literal(str(i)))) for i in range($n)]";
            setup="from rdflib import Graph, URIRef, Literal")

        print_result("add! $(n) triples", jl, py)
    end
    println()

    # ── 2. Triple Pattern Matching ───────────────────────────────
    println("┌─ Pattern Matching ───────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    jl = julia_bench(
        "length(collect(triples(g, (nothing, URIRef(\"http://ex.org/type\"), nothing))))",
        setup="""
        g = RDFGraph()
        for i in 1:10000
            add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/type"), URIRef("http://ex.org/T")))
            add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/name"), Literal("N\$i")))
        end
        """)

    py = python_bench(
        "len(list(g.triples((None, URIRef('http://ex.org/type'), None))))",
        setup="""
from rdflib import Graph, URIRef, Literal
g = Graph()
for i in range(10000):
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/type'), URIRef('http://ex.org/T')))
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/name'), Literal(f'N{i}')))
""")

    print_result("triples(?s, :type, ?o) in 20K", jl, py)

    jl = julia_bench(
        "length(collect(triples(g, (URIRef(\"http://ex.org/s500\"), nothing, nothing))))",
        setup="""
        g = RDFGraph()
        for i in 1:10000
            add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/type"), URIRef("http://ex.org/T")))
            add!(g, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/name"), Literal("N\$i")))
        end
        """)

    py = python_bench(
        "len(list(g.triples((URIRef('http://ex.org/s500'), None, None))))",
        setup="""
from rdflib import Graph, URIRef, Literal
g = Graph()
for i in range(10000):
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/type'), URIRef('http://ex.org/T')))
    g.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/name'), Literal(f'N{i}')))
""")

    print_result("triples(:s500, ?p, ?o) in 20K", jl, py)
    println()

    # ── 3. Serialization ─────────────────────────────────────────
    println("┌─ Serialization ──────────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    graph_setup_jl = """
    g = RDFGraph()
    for i in 1:10000
        s = URIRef("http://example.org/node\$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Person \$i")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"), Literal(string(20 + i % 60), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
    end
    """

    graph_setup_py = """
from rdflib import Graph, URIRef, Literal, Namespace
from rdflib.namespace import RDF, FOAF, XSD
g = Graph()
for i in range(1, 10001):
    s = URIRef(f'http://example.org/node{i}')
    g.add((s, RDF.type, FOAF.Person))
    g.add((s, FOAF.name, Literal(f'Person {i}')))
    g.add((s, FOAF.age, Literal(str(20 + i % 60), datatype=XSD.integer)))
"""

    for (name, jl_code, py_code) in [
        ("N-Triples (30K)",
            "serialize(g, NTriplesFormat())",
            "g.serialize(format='nt')"),
        ("Turtle (30K)",
            "serialize(g, TurtleFormat())",
            "g.serialize(format='turtle')"),
        ("JSON-LD (30K)",
            "serialize(g, JSONLDFormat())",
            "g.serialize(format='json-ld')"),
        ("RDF/XML (30K)",
            "serialize(g, RDFXMLFormat())",
            "g.serialize(format='xml')"),
    ]
        jl = julia_bench(jl_code; setup=graph_setup_jl)
        py = python_bench(py_code; setup=graph_setup_py)
        print_result("serialize $name", jl, py)
    end

    # Jelly (Julia only since pyjelly is separate)
    jl_jelly = julia_bench("serialize_jelly(g)"; setup=graph_setup_jl)
    py_jelly = python_bench(
        "buf = io.BytesIO(); g.serialize(destination=buf, format='jelly'); _ = buf.getvalue()";
        setup=graph_setup_py * "\nimport io\nfrom pyjelly.integrations.rdflib import register_extension_to_rdflib\nregister_extension_to_rdflib()")
    print_result("serialize Jelly (30K)", jl_jelly, py_jelly)
    println()

    # ── 4. Parsing ───────────────────────────────────────────────
    println("┌─ Parsing ────────────────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    # Generate test data files
    julia_eval("""
    g = RDFGraph()
    for i in 1:10000
        s = URIRef("http://example.org/node\$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Person \$i")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"), Literal(string(20 + i % 60), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
    end
    write("/tmp/bench_30k.nt", serialize(g, NTriplesFormat()))
    write("/tmp/bench_30k.jsonld", serialize(g, JSONLDFormat()))
    write("/tmp/bench_30k.rdf", serialize(g, RDFXMLFormat()))
    write("/tmp/bench_30k.jelly", serialize_jelly(g))
    """)

    # Generate Turtle via Python for cross-compatibility
    python_eval("g = Graph(); g.parse('/tmp/bench_30k.nt', format='nt'); g.serialize('/tmp/bench_30k.ttl', format='turtle')";
        setup="from rdflib import Graph")

    for (name, jl_code, py_code) in [
        ("N-Triples (30K)",
            "parse_rdf(nt_data, NTriplesFormat())",
            "Graph().parse(data=nt_data, format='nt')"),
        ("Turtle (30K)",
            "parse_rdf(ttl_data, TurtleFormat())",
            "Graph().parse(data=ttl_data, format='turtle')"),
        ("JSON-LD (30K)",
            "parse_rdf(jld_data, JSONLDFormat())",
            "Graph().parse(data=jld_data, format='json-ld')"),
        ("RDF/XML (30K)",
            "parse_rdf(rdf_data, RDFXMLFormat())",
            "Graph().parse(data=rdf_data, format='xml')"),
    ]
        jl = julia_bench(jl_code; setup="""
            nt_data = read("/tmp/bench_30k.nt", String)
            ttl_data = read("/tmp/bench_30k.ttl", String)
            jld_data = read("/tmp/bench_30k.jsonld", String)
            rdf_data = read("/tmp/bench_30k.rdf", String)
        """)
        py = python_bench(py_code; setup="""
from rdflib import Graph
nt_data = open('/tmp/bench_30k.nt').read()
ttl_data = open('/tmp/bench_30k.ttl').read()
jld_data = open('/tmp/bench_30k.jsonld').read()
rdf_data = open('/tmp/bench_30k.rdf').read()
""")
        print_result("parse $name", jl, py)
    end

    # Jelly parsing
    jl = julia_bench("parse_jelly(jelly_data)";
        setup="jelly_data = read(\"/tmp/bench_30k.jelly\")")
    py = python_bench(
        "g2 = Graph(); g2.parse(data=jelly_data, format='jelly')";
        setup="""
from rdflib import Graph
from pyjelly.integrations.rdflib import register_extension_to_rdflib
register_extension_to_rdflib()
jelly_data = open('/tmp/bench_30k.jelly', 'rb').read()
""")
    print_result("parse Jelly (30K)", jl, py)
    println()

    # ── 5. SPARQL Queries ────────────────────────────────────────
    println("┌─ SPARQL Queries ─────────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    sparql_setup_jl = """
    g = RDFGraph()
    for i in 1:5000
        s = URIRef("http://example.org/node\$i")
        add!(g, Triple(s, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Person \$i")))
        add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/age"), Literal(string(20 + i % 60), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
        if i > 1
            add!(g, Triple(s, URIRef("http://xmlns.com/foaf/0.1/knows"), URIRef("http://example.org/node\$(i-1)")))
        end
    end
    """

    sparql_setup_py = """
from rdflib import Graph, URIRef, Literal
from rdflib.namespace import RDF, FOAF, XSD
g = Graph()
for i in range(1, 5001):
    s = URIRef(f'http://example.org/node{i}')
    g.add((s, RDF.type, FOAF.Person))
    g.add((s, FOAF.name, Literal(f'Person {i}')))
    g.add((s, FOAF.age, Literal(str(20 + i % 60), datatype=XSD.integer)))
    if i > 1:
        g.add((s, FOAF.knows, URIRef(f'http://example.org/node{i-1}')))
"""

    queries = [
        ("SELECT * (simple BGP)",
            "SELECT ?s ?name WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name }"),
        ("SELECT with FILTER",
            "SELECT ?s ?age WHERE { ?s <http://xmlns.com/foaf/0.1/age> ?age FILTER(?age > 50) }"),
        ("SELECT with OPTIONAL",
            "SELECT ?s ?name ?knows WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name OPTIONAL { ?s <http://xmlns.com/foaf/0.1/knows> ?knows } }"),
        ("SELECT DISTINCT",
            "SELECT DISTINCT ?age WHERE { ?s <http://xmlns.com/foaf/0.1/age> ?age }"),
        ("SELECT with ORDER BY LIMIT",
            "SELECT ?s ?name WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name } ORDER BY ?name LIMIT 100"),
        ("CONSTRUCT",
            "CONSTRUCT { ?s <http://ex.org/label> ?n } WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?n } LIMIT 1000"),
    ]

    for (name, q) in queries
        jl = julia_bench("sparql_query(g, \"\"\"$q\"\"\")"; setup=sparql_setup_jl)
        py = python_bench("list(g.query('''$q'''))"; setup=sparql_setup_py)
        print_result("$name", jl, py)
    end
    println()

    # ── 6. SPARQL Update ─────────────────────────────────────────
    println("┌─ SPARQL Update ──────────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    jl = julia_bench("""
    begin
        g2 = RDFGraph()
        for i in 1:1000
            add!(g2, Triple(URIRef("http://ex.org/s\$i"), URIRef("http://ex.org/p"), Literal(string(i))))
        end
        sparql_update(g2, "DELETE { ?s <http://ex.org/p> ?o } WHERE { ?s <http://ex.org/p> ?o }")
    end""")

    py = python_bench(
        "g2 = Graph(); [g2.add((URIRef(f'http://ex.org/s{i}'), URIRef('http://ex.org/p'), Literal(str(i)))) for i in range(1000)]; g2.update('DELETE { ?s <http://ex.org/p> ?o } WHERE { ?s <http://ex.org/p> ?o }')";
        setup="from rdflib import Graph, URIRef, Literal")

    print_result("DELETE WHERE (1K triples)", jl, py)

    jl = julia_bench("""
    begin
        g2 = RDFGraph()
        sparql_update(g2, "INSERT DATA { " * join(["<http://ex.org/s\$i> <http://ex.org/p> \$i ." for i in 1:500], " ") * " }")
    end""")

    py = python_bench(
        "g2 = Graph(); stmts = ' '.join([f'<http://ex.org/s{i}> <http://ex.org/p> {i} .' for i in range(500)]); g2.update(f'INSERT DATA {{ {stmts} }}')";
        setup="from rdflib import Graph")

    print_result("INSERT DATA (500 triples)", jl, py)
    println()

    # ── 7. Graph Utilities ───────────────────────────────────────
    println("┌─ Graph Utilities ────────────────────────────────────────────────────────────────┐")
    @printf("  %-40s  %10s  %10s  %s\n", "Operation", "Julia", "Python", "Speedup")
    println("  " * "─" ^ 78)

    iso_setup_jl = """
    g1 = RDFGraph(); g2 = RDFGraph()
    for i in 1:500
        add!(g1, Triple(BNode("b\$i"), URIRef("http://ex.org/p"), Literal(string(i))))
        add!(g2, Triple(BNode("x\$i"), URIRef("http://ex.org/p"), Literal(string(i))))
    end
    """
    iso_setup_py = """
from rdflib import Graph, BNode, URIRef, Literal
from rdflib.compare import isomorphic
g1 = Graph(); g2 = Graph()
for i in range(500):
    g1.add((BNode(f'b{i}'), URIRef('http://ex.org/p'), Literal(str(i))))
    g2.add((BNode(f'x{i}'), URIRef('http://ex.org/p'), Literal(str(i))))
"""

    jl = julia_bench("isomorphic(g1, g2)"; setup=iso_setup_jl)
    py = python_bench("isomorphic(g1, g2)"; setup=iso_setup_py)
    print_result("isomorphic (500 bnodes)", jl, py)

    println()

    # ── Summary ──────────────────────────────────────────────────
    println("=" ^ 90)
    println("  🟢 = Julia faster  |  🔴 = Python faster  |  Ratio = Python_time / Julia_time")
    println("=" ^ 90)

    # Clean up
    for f in ["/tmp/bench_30k.nt", "/tmp/bench_30k.ttl", "/tmp/bench_30k.jsonld",
              "/tmp/bench_30k.rdf", "/tmp/bench_30k.jelly"]
        isfile(f) && rm(f)
    end
end

main()
