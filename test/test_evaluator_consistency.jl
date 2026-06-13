# ─── Cross-evaluator consistency tests ───────────────────────────────
#
# Executes the same SPARQL queries against the SAME data loaded into
#   * RDFGraph(MemoryStore)   — the reference evaluator
#   * RDFGraph(EncodedStore)  — encoded fast paths
#   * RDFGraph(DuckDBStore)   — SQL pushdown + generic fallback
# and asserts result-set equality across all three. Results are compared
# as multisets of canonicalized rows (or as ordered lists for ORDER BY
# queries). The MemoryStore answer is the ground truth: every fast path
# must either produce the identical answer or fall back.

using Test
using RDFLib

# ── Row canonicalization ─────────────────────────────────────────────

_consistency_canon_term(t::URIRef) = "<" * t.value * ">"
_consistency_canon_term(t::BNode) = "_:" * t.id
function _consistency_canon_term(t::Literal)
    s = "\"" * t.lexical * "\""
    t.language !== nothing && (s *= "@" * t.language)
    t.datatype !== nothing && (s *= "^^<" * t.datatype.value * ">")
    s
end
_consistency_canon_term(t) = string(t)

_consistency_canon_row(b) =
    join(sort!([string(k) * "=" * _consistency_canon_term(v) for (k, v) in b]), " | ")

_consistency_rows_multiset(rs) = sort!([_consistency_canon_row(b) for b in rs])
_consistency_rows_ordered(rs) = [_consistency_canon_row(b) for b in rs]

# ── Shared dataset ───────────────────────────────────────────────────

const _CONS_EX = "http://example.org/"
_ce(s) = URIRef(_CONS_EX * s)
_int_lit(i) = Literal(string(i), datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
_dbl_lit(x) = Literal(string(x), datatype=URIRef("http://www.w3.org/2001/XMLSchema#double"))

function _consistency_populate!(g)
    name = _ce("name"); age = _ce("age"); label = _ce("label")
    knows = _ce("knows"); city = _ce("city"); val = _ce("val")
    placedBy = _ce("placedBy"); amount = _ce("amount")
    p = _ce("p"); q = _ce("q"); rel2 = _ce("rel2"); rel = _ce("rel")

    alice = _ce("alice"); bob = _ce("bob"); carol = _ce("carol"); dave = _ce("dave")

    # People
    add!(g, Triple(alice, name, Literal("Alice")))
    add!(g, Triple(bob,   name, Literal("Bob")))
    add!(g, Triple(carol, name, Literal("Carol")))
    add!(g, Triple(dave,  name, Literal("Dave")))
    add!(g, Triple(alice, age, _int_lit(30)))
    add!(g, Triple(bob,   age, _int_lit(25)))
    add!(g, Triple(carol, age, _int_lit(35)))
    # dave: no age (OPTIONAL / MINUS / !BOUND cases)
    add!(g, Triple(alice, label, Literal("Alice", lang="en")))
    add!(g, Triple(bob,   label, Literal("Bob", lang="en")))
    add!(g, Triple(carol, label, Literal("Carole", lang="fr")))
    add!(g, Triple(alice, knows, bob))
    add!(g, Triple(bob,   knows, carol))
    add!(g, Triple(alice, city, _ce("NYC")))
    add!(g, Triple(bob,   city, _ce("NYC")))
    add!(g, Triple(carol, city, _ce("LDN")))

    # Mixed-typed values sharing the lexical "5" (typed-equality probes)
    add!(g, Triple(alice, val, _int_lit(5)))
    add!(g, Triple(bob,   val, Literal("5")))
    add!(g, Triple(carol, val, Literal("5", lang="en")))
    add!(g, Triple(dave,  val, _ce("five")))
    add!(g, Triple(dave,  val, _dbl_lit(7.5)))

    # Orders: alice has 3, bob has 2, carol has NONE (named customer with
    # zero joining rows must not yield a spurious zero-count group).
    for (i, amt) in enumerate((10, 20, 30))
        o = _ce("order_a$i")
        add!(g, Triple(o, placedBy, alice))
        add!(g, Triple(o, amount, _int_lit(amt)))
    end
    for (i, amt) in enumerate((100, 200))
        o = _ce("order_b$i")
        add!(g, Triple(o, placedBy, bob))
        add!(g, Triple(o, amount, _int_lit(amt)))
    end

    # Repeated-variable star-join probe: only e1 satisfies {?s :p ?x . ?s :q ?x}
    e1 = _ce("e1"); e2 = _ce("e2"); e3 = _ce("e3")
    v1 = _ce("v1"); v2 = _ce("v2")
    add!(g, Triple(e1, p, v1)); add!(g, Triple(e1, q, v1))
    add!(g, Triple(e2, p, v1)); add!(g, Triple(e2, q, v2))
    # Self-loop probe for {?s :rel2 ?s}
    add!(g, Triple(e3, rel2, e3))
    add!(g, Triple(e1, rel2, e2))

    # A blank node
    b1 = BNode("cb1")
    add!(g, Triple(_ce("thing"), rel, b1))
    add!(g, Triple(b1, name, Literal("BThing")))
    g
end

# ── Query matrix ─────────────────────────────────────────────────────
# (description, query, ordered?) — `ordered` compares row ORDER too.

const _CONSISTENCY_QUERIES = [
    ("single BGP",
     "SELECT ?s ?name WHERE { ?s ex:name ?name }", false),
    ("star join two predicates",
     "SELECT ?s ?name ?age WHERE { ?s ex:name ?name ; ex:age ?age }", false),
    ("repeated variable star join",
     "SELECT ?s ?x WHERE { ?s ex:p ?x . ?s ex:q ?x }", false),
    ("repeated subject-object variable",
     "SELECT ?s WHERE { ?s ex:rel2 ?s }", false),
    ("multi-hop join",
     "SELECT ?a ?c WHERE { ?a ex:knows ?b . ?b ex:knows ?c }", false),
    ("constant subject",
     "SELECT ?p ?o WHERE { ex:alice ?p ?o }", false),
    ("constant object join",
     "SELECT ?s ?name WHERE { ?s ex:city ex:NYC ; ex:name ?name }", false),
    ("OPTIONAL",
     "SELECT ?s ?name ?age WHERE { ?s ex:name ?name . OPTIONAL { ?s ex:age ?age } }", false),
    ("UNION",
     "SELECT ?s ?n WHERE { { ?s ex:name ?n } UNION { ?s ex:label ?n } }", false),
    ("MINUS",
     "SELECT ?s ?name WHERE { ?s ex:name ?name . MINUS { ?s ex:age ?a } }", false),
    ("FILTER numeric >",
     "SELECT ?s ?age WHERE { ?s ex:age ?age . FILTER(?age > 26) }", false),
    ("FILTER string equality",
     "SELECT ?s WHERE { ?s ex:name ?name . FILTER(?name = \"Alice\") }", false),
    ("FILTER numeric equality over mixed-typed values",
     "SELECT ?s WHERE { ?s ex:val ?v . FILTER(?v = 5) }", false),
    ("FILTER lang()",
     "SELECT ?s ?l WHERE { ?s ex:label ?l . FILTER(LANG(?l) = \"en\") }", false),
    ("FILTER langMatches lang-tagged string equality",
     "SELECT ?s WHERE { ?s ex:label ?l . FILTER(STR(?l) = \"Bob\") }", false),
    ("ORDER BY mixed types (no limit)",
     "SELECT ?s ?v WHERE { ?s ex:val ?v } ORDER BY ?v", true),
    ("ORDER BY numeric DESC with LIMIT",
     "SELECT ?s ?age WHERE { ?s ex:age ?age } ORDER BY DESC(?age) LIMIT 2", true),
    ("DISTINCT over mixed-typed values",
     "SELECT DISTINCT ?v WHERE { ?s ex:val ?v }", false),
    ("REDUCED",
     "SELECT REDUCED ?city WHERE { ?s ex:city ?city }", false),
    ("GROUP BY + COUNT",
     "SELECT ?city (COUNT(?s) AS ?n) WHERE { ?s ex:city ?city } GROUP BY ?city", false),
    ("two-star GROUP BY + COUNT/SUM (no zero-count groups)",
     """SELECT ?name (COUNT(?o) AS ?n) (SUM(?amt) AS ?total)
        WHERE { ?o ex:placedBy ?c ; ex:amount ?amt . ?c ex:name ?name }
        GROUP BY ?name""", false),
    ("GROUP BY + MIN/MAX",
     """SELECT ?c (MIN(?amt) AS ?lo) (MAX(?amt) AS ?hi)
        WHERE { ?o ex:placedBy ?c ; ex:amount ?amt } GROUP BY ?c""", false),
    ("GROUP BY + AVG",
     """SELECT ?c (AVG(?amt) AS ?avg)
        WHERE { ?o ex:placedBy ?c ; ex:amount ?amt } GROUP BY ?c""", false),
    ("aggregates over empty match (COUNT/SUM, no GROUP BY)",
     "SELECT (COUNT(?s) AS ?n) (SUM(?x) AS ?t) WHERE { ?s ex:nonexistent ?x }", false),
    ("COUNT(DISTINCT) through multi-valued link",
     "SELECT (COUNT(DISTINCT ?c) AS ?n) WHERE { ?o ex:placedBy ?c }", false),
    ("OPTIONAL + GROUP BY aggregate (zero counts kept)",
     """SELECT ?name (COUNT(?o) AS ?n)
        WHERE { ?c ex:name ?name . OPTIONAL { ?o ex:placedBy ?c } }
        GROUP BY ?name""", false),
    ("BIND computing a novel value",
     "SELECT ?s ?b WHERE { ?s ex:age ?age . BIND(?age + 1 AS ?b) }", false),
    ("BIND novel value carried through a later join",
     "SELECT ?s ?b ?name WHERE { ?s ex:age ?age . BIND(?age + 1000 AS ?b) ?s ex:name ?name }", false),
    ("VALUES with a value absent from the data",
     "SELECT ?s ?name WHERE { VALUES ?name { \"Alice\" \"Zed\" } ?s ex:name ?name }", false),
    ("VALUES novel value carried through a star join",
     "SELECT ?s ?name ?tag WHERE { VALUES ?tag { \"novel-tag\" } ?s ex:name ?name . ?s ex:age ?a }", false),
    ("property path one-or-more",
     "SELECT ?x WHERE { ex:alice ex:knows+ ?x }", false),
    ("property path alternative",
     "SELECT ?n WHERE { ex:alice ex:name|ex:label ?n }", false),
    ("blank node round-trip",
     "SELECT ?b ?n WHERE { ex:thing ex:rel ?b . ?b ex:name ?n }", false),
]

@testset "Cross-evaluator consistency (Memory vs Encoded vs DuckDB)" begin
    g_mem = RDFGraph()
    g_enc = RDFGraph(store=EncodedStore())
    g_ddb = RDFGraph(store=DuckDBStore())
    for g in (g_mem, g_enc, g_ddb)
        _consistency_populate!(g)
    end
    @test length(g_mem) == length(g_enc) == length(g_ddb)

    prefix = "PREFIX ex: <http://example.org/>\n"
    for (desc, qbody, ordered) in _CONSISTENCY_QUERIES
        @testset "$desc" begin
            q = prefix * qbody
            r_mem = collect(sparql_query(g_mem, q))
            r_enc = collect(sparql_query(g_enc, q))
            r_ddb = collect(sparql_query(g_ddb, q))
            if ordered
                c_mem = _consistency_rows_ordered(r_mem)
                @test _consistency_rows_ordered(r_enc) == c_mem
                @test _consistency_rows_ordered(r_ddb) == c_mem
            else
                c_mem = _consistency_rows_multiset(r_mem)
                @test _consistency_rows_multiset(r_enc) == c_mem
                @test _consistency_rows_multiset(r_ddb) == c_mem
            end
        end
    end

    close(g_ddb.store)
end
