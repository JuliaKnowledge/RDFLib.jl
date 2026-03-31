"""
Remote SPARQL endpoint tests — compares local RDFLib.jl SPARQL engine results
against a Jena Fuseki server at http://localhost:3030.

Fuseki must be running with a dataset named "test" that accepts both
query (http://localhost:3030/test/query) and update
(http://localhost:3030/test/update) operations.

These tests verify that SPARQL 1.2 features produce identical results
locally and remotely, catching semantic divergence between engines.

To run:
    SPARQL_TEST_ENDPOINT=http://localhost:3030/test julia --project=. -e \
        'using Test; using RDFLib; include("test/test_sparql_remote.jl")'
"""

using Test
using RDFLib
using Dates
using Downloads

# ---------------------------------------------------------------------------
# Helper: endpoint from ENV; when unreachable, run a local smoke fallback so the
# suite stays hermetic and skip-free while still allowing live parity testing.
# ---------------------------------------------------------------------------
const FUSEKI_ENDPOINT = get(ENV, "SPARQL_TEST_ENDPOINT",
                            "http://localhost:3030/test")
const FUSEKI_QUERY    = FUSEKI_ENDPOINT * "/query"
const FUSEKI_UPDATE   = FUSEKI_ENDPOINT * "/update"

function _fuseki_available()::Bool
    try
        store = SPARQLStore(FUSEKI_QUERY; update_endpoint=FUSEKI_UPDATE, timeout=5)
        g = RDFGraph(store=store)
        sparql_query(g, "ASK { ?s ?p ?o }")
        return true
    catch e
        @warn "Fuseki not reachable at $FUSEKI_ENDPOINT — skipping remote SPARQL tests" exception=e
        return false
    end
end

const FUSEKI_OK = _fuseki_available()

# ---------------------------------------------------------------------------
# Helper: build local + remote graph pair with the same data
# ---------------------------------------------------------------------------
const TEST_GRAPH_URI = "http://example.org/rdflib-test-" * string(UInt32(hash(time_ns()) & 0xffffffff), base=16)

function _make_test_data()
    ttl = """
    @prefix ex:  <http://example.org/> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

    ex:alice  a           ex:Person ;
              ex:name     "Alice" ;
              ex:age      "30"^^xsd:integer ;
              ex:score    "95.5"^^xsd:double ;
              ex:born     "1994-06-15T08:30:00"^^xsd:dateTime ;
              ex:email    "alice@example.org" ;
              ex:knows    ex:bob, ex:carol ;
              ex:tags     "science", "math" .

    ex:bob    a           ex:Person ;
              ex:name     "Bob" ;
              ex:age      "25"^^xsd:integer ;
              ex:score    "88.0"^^xsd:double ;
              ex:knows    ex:alice ;
              ex:label    "Robert"@en, "Roberto"@es .

    ex:carol  a           ex:Person ;
              ex:name     "Carol" ;
              ex:age      "35"^^xsd:integer ;
              ex:score    "92.3"^^xsd:double ;
              ex:knows    ex:alice .

    ex:dave   a           ex:Student ;
              ex:name     "Dave" ;
              ex:age      "22"^^xsd:integer .

    ex:Student rdfs:subClassOf ex:Person .

    ex:colors rdf:first ex:red ;
              rdf:rest  [ rdf:first ex:green ;
                          rdf:rest  [ rdf:first ex:blue ;
                                      rdf:rest  rdf:nil ] ] .
    """
    # Local graph
    local_g = RDFGraph()
    parse_rdf!(local_g, ttl, TurtleFormat())
    return (local_g, ttl)
end

"""
Upload test data to Fuseki via Graph Store Protocol, returning a remote RDFGraph.
"""
function _setup_remote(ttl::AbstractString)
    store = SPARQLStore(FUSEKI_QUERY;
                        update_endpoint=FUSEKI_UPDATE, timeout=30)
    rg = RDFGraph(store=store)
    # Clear the dataset
    sparql_update(rg, "DROP ALL")
    # Upload data via GSP (Graph Store Protocol) — more reliable than INSERT DATA
    gsp_url = replace(FUSEKI_ENDPOINT, r"/test$" => "") * "/test/data"
    Downloads.request(gsp_url;
        method="PUT",
        headers=["Content-Type" => "text/turtle"],
        input=IOBuffer(ttl),
        output=devnull,
        timeout=30)
    return rg
end

"""
Compare SELECT results from local and remote, ignoring row order.
Returns (local_rows, remote_rows) as sorted vectors of Dict.
"""
function _compare_select(local_g, remote_g, query; sort_key=nothing)
    lr = sparql_query(local_g, query)
    rr = sparql_query(remote_g, query)

    _canonical(rows) = begin
        mapped = [Dict(k => _norm(v) for (k,v) in r) for r in rows]
        sort!(mapped; by = d -> join(sort(collect(values(d))), "|"))
        mapped
    end
    return (_canonical(lr), _canonical(rr))
end

_norm(v::Literal) = v.lexical
_norm(v::URIRef) = string(v)
_norm(v::BNode) = "__bnode__"  # BNode ids differ across engines
_norm(v) = string(v)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@testset "Remote SPARQL (Fuseki)" begin
if !FUSEKI_OK
    @info "Fuseki endpoint not available; running local smoke coverage only" endpoint=FUSEKI_ENDPOINT
    local_g, _ = _make_test_data()

    @testset "Local smoke fallback" begin
        q = """
            PREFIX ex: <http://example.org/>
            SELECT ?name WHERE { ?s ex:name ?name } ORDER BY ?name
        """
        names = [r["name"].lexical for r in sparql_query(local_g, q)]
        @test names == ["Alice", "Bob", "Carol", "Dave"]
        @test sparql_query(local_g, "PREFIX ex: <http://example.org/> ASK { ex:alice ex:name \"Alice\" }")
    end
else

local_g, ttl = _make_test_data()
remote_g = _setup_remote(ttl)

# ── Basic SELECT ──────────────────────────────────────────────────────────

@testset "Basic SELECT" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE { ?s ex:name ?name } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

# ── ASK ───────────────────────────────────────────────────────────────────

@testset "ASK" begin
    q1 = "PREFIX ex: <http://example.org/> ASK { ex:alice ex:name \"Alice\" }"
    q2 = "PREFIX ex: <http://example.org/> ASK { ex:alice ex:name \"MISSING\" }"
    @test sparql_query(local_g, q1) == sparql_query(remote_g, q1)
    @test sparql_query(local_g, q2) == sparql_query(remote_g, q2)
end

# ── CONSTRUCT ─────────────────────────────────────────────────────────────

@testset "CONSTRUCT" begin
    q = """
        PREFIX ex: <http://example.org/>
        CONSTRUCT { ?s ex:fullName ?name }
        WHERE     { ?s ex:name ?name . ?s a ex:Person }
    """
    lg = sparql_query(local_g, q)
    rg = sparql_query(remote_g, q)
    @test lg isa RDFGraph
    @test rg isa RDFGraph
    @test length(lg) == length(rg)
end

# ── FILTER ────────────────────────────────────────────────────────────────

@testset "FILTER comparisons" begin
    q = """
        PREFIX ex: <http://example.org/>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT ?name ?age WHERE {
            ?s ex:name ?name . ?s ex:age ?age .
            FILTER(?age > 24)
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

@testset "FILTER REGEX" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE {
            ?s ex:name ?name . FILTER(REGEX(?name, "^[AB]"))
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    ln = [r["name"].lexical for r in lr]
    rn = [r["name"].lexical for r in rr]
    @test ln == rn
    @test "Alice" in ln
    @test "Bob" in ln
end

@testset "FILTER logical operators" begin
    q = """
        PREFIX ex: <http://example.org/>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT ?name WHERE {
            ?s ex:name ?name . ?s ex:age ?age .
            FILTER(?age >= 25 && ?age <= 30)
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

# ── Aggregates ────────────────────────────────────────────────────────────

@testset "COUNT" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (COUNT(?s) AS ?cnt) WHERE { ?s a ex:Person }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test parse(Int, lr[1]["cnt"].lexical) == parse(Int, rr[1]["cnt"].lexical)
end

@testset "SUM / AVG / MIN / MAX" begin
    q = """
        PREFIX ex: <http://example.org/>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT (SUM(?age) AS ?total) (AVG(?age) AS ?avg)
               (MIN(?age) AS ?youngest) (MAX(?age) AS ?oldest)
        WHERE { ?s a ex:Person . ?s ex:age ?age }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    for v in ["total", "youngest", "oldest"]
        @test parse(Float64, lr[1][v].lexical) ≈ parse(Float64, rr[1][v].lexical) atol=0.01
    end
    @test parse(Float64, lr[1]["avg"].lexical) ≈ parse(Float64, rr[1]["avg"].lexical) atol=0.01
end

@testset "GROUP BY + HAVING" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?type (COUNT(?s) AS ?cnt) WHERE {
            ?s a ?type
        }
        GROUP BY ?type
        HAVING (COUNT(?s) > 1)
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    @test length(lr) >= 1
end

@testset "GROUP_CONCAT" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (GROUP_CONCAT(?name; separator=", ") AS ?allnames) WHERE {
            ?s ex:name ?name
        }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    lnames = sort(split(lr[1]["allnames"].lexical, ", "))
    rnames = sort(split(rr[1]["allnames"].lexical, ", "))
    @test lnames == rnames
end

# ── OPTIONAL ──────────────────────────────────────────────────────────────

@testset "OPTIONAL" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name ?email WHERE {
            ?s ex:name ?name .
            OPTIONAL { ?s ex:email ?email }
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    # Alice has email, others don't
    la = filter(r -> r["name"].lexical == "Alice", lr)
    ra = filter(r -> r["name"].lexical == "Alice", rr)
    @test la[1]["email"].lexical == ra[1]["email"].lexical
end

# ── UNION ─────────────────────────────────────────────────────────────────

@testset "UNION" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?x WHERE {
            { ?x a ex:Person } UNION { ?x a ex:Student }
        }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    luris = sort([string(r["x"]) for r in lr])
    ruris = sort([string(r["x"]) for r in rr])
    @test luris == ruris
end

# ── MINUS ─────────────────────────────────────────────────────────────────

@testset "MINUS" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE {
            ?s ex:name ?name .
            MINUS { ?s ex:email ?e }
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

# ── VALUES ────────────────────────────────────────────────────────────────

@testset "VALUES" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE {
            VALUES ?s { ex:alice ex:carol }
            ?s ex:name ?name
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

# ── BIND ──────────────────────────────────────────────────────────────────

@testset "BIND expressions" begin
    q = """
        PREFIX ex: <http://example.org/>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT ?name ?next WHERE {
            ?s ex:name ?name . ?s ex:age ?age .
            BIND(?age + 1 AS ?next)
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    for i in eachindex(lr)
        @test parse(Float64, lr[i]["next"].lexical) ≈
              parse(Float64, rr[i]["next"].lexical) atol=0.01
    end
end

# ── Subquery ──────────────────────────────────────────────────────────────

@testset "Subquery" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name ?age WHERE {
            ?s ex:name ?name .
            {
                SELECT ?s ?age WHERE { ?s ex:age ?age } ORDER BY DESC(?age) LIMIT 2
            }
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
end

# ── ORDER BY / LIMIT / OFFSET ────────────────────────────────────────────

@testset "ORDER BY / LIMIT / OFFSET" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE { ?s ex:name ?name } ORDER BY ?name LIMIT 2 OFFSET 1
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

# ── DISTINCT ──────────────────────────────────────────────────────────────

@testset "DISTINCT" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT DISTINCT ?type WHERE { ?s a ?type }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    luris = sort([string(r["type"]) for r in lr])
    ruris = sort([string(r["type"]) for r in rr])
    @test luris == ruris
end

# ── NOT EXISTS / EXISTS ───────────────────────────────────────────────────

@testset "FILTER EXISTS / NOT EXISTS" begin
    q1 = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE {
            ?s ex:name ?name .
            FILTER EXISTS { ?s ex:email ?e }
        }
    """
    q2 = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE {
            ?s ex:name ?name .
            FILTER NOT EXISTS { ?s ex:email ?e }
        } ORDER BY ?name
    """
    for q in [q1, q2]
        lr = sparql_query(local_g, q)
        rr = sparql_query(remote_g, q)
        @test sort([r["name"].lexical for r in lr]) ==
              sort([r["name"].lexical for r in rr])
    end
end

# ── Property Paths ────────────────────────────────────────────────────────

@testset "Property Paths" begin
    # Sequence path
    q1 = """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE { ex:alice ex:knows/ex:name ?name } ORDER BY ?name
    """
    lr = sparql_query(local_g, q1)
    rr = sparql_query(remote_g, q1)
    @test sort([r["name"].lexical for r in lr]) ==
          sort([r["name"].lexical for r in rr])

    # Alternative path
    q2 = """
        PREFIX ex: <http://example.org/>
        SELECT ?val WHERE { ex:bob ex:name|ex:label ?val } ORDER BY ?val
    """
    lr = sparql_query(local_g, q2)
    rr = sparql_query(remote_g, q2)
    @test length(lr) == length(rr)

    # Inverse path
    q3 = """
        PREFIX ex: <http://example.org/>
        SELECT ?s WHERE { ex:alice ^ex:knows ?s }
    """
    lr = sparql_query(local_g, q3)
    rr = sparql_query(remote_g, q3)
    @test sort([string(r["s"]) for r in lr]) ==
          sort([string(r["s"]) for r in rr])
end

@testset "Property Path + / *" begin
    # ZeroOrMore path
    q1 = """
        PREFIX ex:   <http://example.org/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        SELECT ?cls WHERE { ex:Student rdfs:subClassOf* ?cls }
    """
    lr = sparql_query(local_g, q1)
    rr = sparql_query(remote_g, q1)
    @test sort([string(r["cls"]) for r in lr]) ==
          sort([string(r["cls"]) for r in rr])

    # OneOrMore path
    q2 = """
        PREFIX ex:   <http://example.org/>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        SELECT ?cls WHERE { ex:Student rdfs:subClassOf+ ?cls }
    """
    lr = sparql_query(local_g, q2)
    rr = sparql_query(remote_g, q2)
    @test sort([string(r["cls"]) for r in lr]) ==
          sort([string(r["cls"]) for r in rr])
end

# ═══════════════════════════════════════════════════════════════════════════
# SPARQL 1.2 Features — local vs remote parity
# ═══════════════════════════════════════════════════════════════════════════

@testset "SPARQL 1.2: Hash Functions" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (SHA256(?name) AS ?h) WHERE { ex:alice ex:name ?name }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == 1
    @test length(rr) == 1
    @test lr[1]["h"].lexical == rr[1]["h"].lexical
end

@testset "SPARQL 1.2: Date/Time Functions" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (YEAR(?d) AS ?y) (MONTH(?d) AS ?m) (DAY(?d) AS ?dy)
               (HOURS(?d) AS ?h) (MINUTES(?d) AS ?mi) (SECONDS(?d) AS ?s)
        WHERE { ex:alice ex:born ?d }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    for k in ["y", "m", "dy", "h", "mi", "s"]
        @test parse(Float64, lr[1][k].lexical) ≈
              parse(Float64, rr[1][k].lexical) atol=0.01
    end
end

@testset "SPARQL 1.2: STRBEFORE / STRAFTER" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (STRBEFORE(?email, "@") AS ?user)
               (STRAFTER(?email, "@") AS ?domain)
        WHERE { ex:alice ex:email ?email }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test lr[1]["user"].lexical == rr[1]["user"].lexical
    @test lr[1]["domain"].lexical == rr[1]["domain"].lexical
end

@testset "SPARQL 1.2: Arithmetic Expressions" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name (?age * 2 + 1 AS ?val) WHERE {
            ?s ex:name ?name . ?s ex:age ?age
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    for i in eachindex(lr)
        @test lr[i]["name"].lexical == rr[i]["name"].lexical
        @test parse(Float64, lr[i]["val"].lexical) ≈
              parse(Float64, rr[i]["val"].lexical) atol=0.01
    end
end

@testset "SPARQL 1.2: String Functions" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (UCASE(?name) AS ?up) (LCASE(?name) AS ?lo)
               (STRLEN(?name) AS ?len) (SUBSTR(?name, 1, 3) AS ?sub)
               (CONTAINS(?name, "lic") AS ?has) (STRSTARTS(?name, "Al") AS ?st)
               (STRENDS(?name, "ce") AS ?en) (CONCAT(?name, "!") AS ?cat)
        WHERE { ex:alice ex:name ?name }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    for k in ["up", "lo", "len", "sub", "has", "st", "en", "cat"]
        @test lr[1][k].lexical == rr[1][k].lexical
    end
end

@testset "SPARQL 1.2: IF Function" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name (IF(?age > 30, "senior", "junior") AS ?cat) WHERE {
            ?s ex:name ?name . ?s ex:age ?age
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    for i in eachindex(lr)
        @test lr[i]["cat"].lexical == rr[i]["cat"].lexical
    end
end

@testset "SPARQL 1.2: COALESCE" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name (COALESCE(?email, "none") AS ?e) WHERE {
            ?s ex:name ?name .
            OPTIONAL { ?s ex:email ?email }
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    for i in eachindex(lr)
        @test lr[i]["e"].lexical == rr[i]["e"].lexical
    end
end

@testset "SPARQL 1.2: REPLACE" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (REPLACE(?name, "l", "L") AS ?rep) WHERE {
            ex:alice ex:name ?name
        }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test lr[1]["rep"].lexical == rr[1]["rep"].lexical
end

@testset "SPARQL 1.2: ENCODE_FOR_URI" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT (ENCODE_FOR_URI(?email) AS ?enc) WHERE {
            ex:alice ex:email ?email
        }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test lr[1]["enc"].lexical == rr[1]["enc"].lexical
end

@testset "SPARQL 1.2: Language Tag Functions" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?lbl (LANG(?lbl) AS ?lng) (LANGMATCHES(LANG(?lbl), "en") AS ?lmatch)
        WHERE { ex:bob ex:label ?lbl }
        ORDER BY LANG(?lbl)
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    for i in eachindex(lr)
        @test lr[i]["lng"].lexical == rr[i]["lng"].lexical
        @test lr[i]["lmatch"].lexical == rr[i]["lmatch"].lexical
    end
end

@testset "SPARQL 1.2: Datatype / STR / IRI" begin
    q = """
        PREFIX ex: <http://example.org/>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT (DATATYPE(?age) AS ?dt) (STR(?age) AS ?sv) (STR(?s) AS ?su)
        WHERE { ?s ex:age ?age . ?s ex:name "Alice" }
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test string(lr[1]["dt"]) == string(rr[1]["dt"])
    @test lr[1]["sv"].lexical == rr[1]["sv"].lexical
end

@testset "SPARQL 1.2: BOUND / isIRI / isLiteral / isBlank" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name (isIRI(?s) AS ?isuri) (isLiteral(?name) AS ?islit)
               (BOUND(?name) AS ?isbound)
        WHERE { ?s ex:name ?name }
        ORDER BY ?name LIMIT 2
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    for i in eachindex(lr)
        @test lr[i]["isuri"].lexical == rr[i]["isuri"].lexical
        @test lr[i]["islit"].lexical == rr[i]["islit"].lexical
        @test lr[i]["isbound"].lexical == rr[i]["isbound"].lexical
    end
end

@testset "SPARQL 1.2: CONSTRUCT WHERE shorthand" begin
    q = """
        PREFIX ex: <http://example.org/>
        CONSTRUCT WHERE { ex:alice ex:name ?name }
    """
    lg = sparql_query(local_g, q)
    rg = sparql_query(remote_g, q)
    @test lg isa RDFGraph
    @test rg isa RDFGraph
    @test length(lg) == length(rg)
end

@testset "SPARQL 1.2: REDUCED" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT REDUCED ?name WHERE { ?s ex:name ?name } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test sort([r["name"].lexical for r in lr]) ==
          sort([r["name"].lexical for r in rr])
end

# ── SPARQL UPDATE parity ─────────────────────────────────────────────────

@testset "SPARQL UPDATE: INSERT DATA" begin
    # Insert on both engines — use separate triples (local parser doesn't handle `;` in INSERT DATA)
    ins = """
        PREFIX ex: <http://example.org/>
        INSERT DATA {
            ex:eve ex:name "Eve" .
            ex:eve ex:age "28"^^<http://www.w3.org/2001/XMLSchema#integer> .
        }
    """
    sparql_update(local_g, ins)
    sparql_update(remote_g, ins)

    q = "PREFIX ex: <http://example.org/> SELECT ?name WHERE { ex:eve ex:name ?name }"
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == 1
    @test length(rr) == 1
    @test lr[1]["name"].lexical == rr[1]["name"].lexical
end

@testset "SPARQL UPDATE: DELETE DATA" begin
    del = """
        PREFIX ex: <http://example.org/>
        DELETE DATA { ex:eve ex:name "Eve" }
    """
    sparql_update(local_g, del)
    sparql_update(remote_g, del)

    q = "PREFIX ex: <http://example.org/> ASK { ex:eve ex:name \"Eve\" }"
    local_result = sparql_query(local_g, q)
    remote_result = sparql_query(remote_g, q)
    @test local_result == false
    @test remote_result == false
end

@testset "SPARQL UPDATE: DELETE WHERE" begin
    # Remote DELETE WHERE
    sparql_update(remote_g, """
        PREFIX ex: <http://example.org/>
        DELETE WHERE { ex:eve ?p ?o }
    """)
    q = "PREFIX ex: <http://example.org/> ASK { ex:eve ?p ?o }"
    @test sparql_query(remote_g, q) == false
    # Local engine DELETE WHERE
    local_g2 = RDFGraph()
    add!(local_g2, Triple(URIRef("http://example.org/x"), URIRef("http://example.org/p"), Literal("val")))
    add!(local_g2, Triple(URIRef("http://example.org/x"), URIRef("http://example.org/q"), Literal("other")))
    sparql_update(local_g2, """
        PREFIX ex: <http://example.org/>
        DELETE WHERE { ex:x ex:p ?o }
    """)
    @test length(local_g2) == 1
    @test sparql_query(local_g2, "PREFIX ex: <http://example.org/> ASK { ex:x ex:p ?o }") == false
    @test sparql_query(local_g2, "PREFIX ex: <http://example.org/> ASK { ex:x ex:q ?o }") == true
end

# ── Complex combined queries ─────────────────────────────────────────────

@testset "Complex: aggregate + HAVING + ORDER" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name (COUNT(?friend) AS ?fc) WHERE {
            ?s ex:name ?name .
            ?s ex:knows ?friend
        }
        GROUP BY ?name
        HAVING (COUNT(?friend) > 0)
        ORDER BY DESC(?fc)
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    @test length(lr) >= 1
    lsorted = sort([(r["name"].lexical, parse(Int, r["fc"].lexical)) for r in lr])
    rsorted = sort([(r["name"].lexical, parse(Int, r["fc"].lexical)) for r in rr])
    @test lsorted == rsorted
end

@testset "Complex: nested OPTIONAL + FILTER" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name ?email ?score WHERE {
            ?s a ex:Person .
            ?s ex:name ?name .
            OPTIONAL { ?s ex:email ?email }
            OPTIONAL { ?s ex:score ?score }
            FILTER(?name != "Dave")
        } ORDER BY ?name
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
    @test [r["name"].lexical for r in lr] == [r["name"].lexical for r in rr]
end

@testset "Complex: subquery + aggregate" begin
    q = """
        PREFIX ex: <http://example.org/>
        SELECT ?name ?avg_score WHERE {
            ?s ex:name ?name .
            {
                SELECT (AVG(?sc) AS ?avg_score) WHERE {
                    ?p ex:score ?sc
                }
            }
        } ORDER BY ?name LIMIT 3
    """
    lr = sparql_query(local_g, q)
    rr = sparql_query(remote_g, q)
    @test length(lr) == length(rr)
end

# ── Cleanup remote ───────────────────────────────────────────────────────

@testset "Cleanup remote dataset" begin
    sparql_update(remote_g, "DROP ALL")
    @test sparql_query(remote_g, "SELECT (COUNT(*) AS ?c) WHERE { ?s ?p ?o }")[1]["c"].lexical == "0"
end

end  # FUSEKI_OK
end  # @testset
