using Test
using RDFLib

@testset "Datalog Reasoner" begin

@testset "Basic transitive closure" begin
    # {?a :p ?b} => {?a :p ?b} — identity (noop)
    # {?a :p ?b . ?b :p ?c} => {?a :p ?c} — transitive closure
    n3 = """
    @prefix : <http://example.org/> .
    :a :p :b .
    :b :p :c .
    :c :p :d .
    { ?x :p ?y . ?y :p ?z } => { ?x :p ?z } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    p = URIRef("http://example.org/p")
    a = URIRef("http://example.org/a")
    b = URIRef("http://example.org/b")
    c = URIRef("http://example.org/c")
    d = URIRef("http://example.org/d")

    # Original triples
    @test Triple(a, p, b) in result
    @test Triple(b, p, c) in result
    @test Triple(c, p, d) in result

    # Transitive closure
    @test Triple(a, p, c) in result  # a->b->c
    @test Triple(b, p, d) in result  # b->c->d
    @test Triple(a, p, d) in result  # a->b->c->d
end

@testset "Single-body rule" begin
    n3 = """
    @prefix : <http://example.org/> .
    :alice :type :Person .
    :bob :type :Person .
    { ?x :type :Person } => { ?x :is :human } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    is_pred = URIRef("http://example.org/is")
    human = URIRef("http://example.org/human")
    alice = URIRef("http://example.org/alice")
    bob = URIRef("http://example.org/bob")

    @test Triple(alice, is_pred, human) in result
    @test Triple(bob, is_pred, human) in result
end

@testset "Multi-body join" begin
    n3 = """
    @prefix : <http://example.org/> .
    :alice :parent :bob .
    :bob :parent :carol .
    :alice :parent :dan .
    { ?x :parent ?y . ?y :parent ?z } => { ?x :grandparent ?z } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    gp = URIRef("http://example.org/grandparent")
    alice = URIRef("http://example.org/alice")
    carol = URIRef("http://example.org/carol")

    @test Triple(alice, gp, carol) in result
end

@testset "Multiple rules" begin
    n3 = """
    @prefix : <http://example.org/> .
    :a :subClassOf :b .
    :b :subClassOf :c .
    :x :type :a .
    { ?c1 :subClassOf ?c2 . ?c2 :subClassOf ?c3 } => { ?c1 :subClassOf ?c3 } .
    { ?x :type ?c . ?c :subClassOf ?d } => { ?x :type ?d } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    sc = URIRef("http://example.org/subClassOf")
    tp = URIRef("http://example.org/type")
    a = URIRef("http://example.org/a")
    b = URIRef("http://example.org/b")
    c = URIRef("http://example.org/c")
    x = URIRef("http://example.org/x")

    @test Triple(a, sc, c) in result  # transitive subclass
    @test Triple(x, tp, b) in result  # x type b (via a subClassOf b)
    @test Triple(x, tp, c) in result  # x type c (via a subClassOf c)
end

@testset "Fan-out pattern" begin
    n3 = """
    @prefix : <http://example.org/> .
    :root :child :c1 .
    :root :child :c2 .
    :root :child :c3 .
    { ?x :child ?y } => { ?y :parent :root } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    parent = URIRef("http://example.org/parent")
    root = URIRef("http://example.org/root")
    c1 = URIRef("http://example.org/c1")
    c2 = URIRef("http://example.org/c2")
    c3 = URIRef("http://example.org/c3")

    @test Triple(c1, parent, root) in result
    @test Triple(c2, parent, root) in result
    @test Triple(c3, parent, root) in result
end

@testset "No rules — data only" begin
    n3 = """
    @prefix : <http://example.org/> .
    :a :p :b .
    :c :p :d .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    @test length(result) == 2
end

@testset "Consistency with N3 reasoner" begin
    # Datalog and N3 should produce the same results for pure Datalog rules
    n3 = """
    @prefix : <http://example.org/> .
    :a :p :b .
    :b :p :c .
    :c :p :d .
    :d :p :e .
    { ?x :p ?y . ?y :p ?z } => { ?x :p ?z } .
    """
    g = parse_rdf(n3, N3Format())
    dl_result = datalog_reason(g)
    n3_result = reason(g)

    p = URIRef("http://example.org/p")

    # Count :p triples in both results
    dl_p_triples = Set(t for t in triples(dl_result) if t.predicate == p)
    n3_p_triples = Set(t for t in triples(n3_result) if t.predicate == p)

    @test dl_p_triples == n3_p_triples
end

@testset "Diamond pattern" begin
    n3 = """
    @prefix : <http://example.org/> .
    :a :p :b .
    :a :p :c .
    :b :p :d .
    :c :p :d .
    { ?x :p ?y . ?y :p ?z } => { ?x :p ?z } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    p = URIRef("http://example.org/p")
    a = URIRef("http://example.org/a")
    d = URIRef("http://example.org/d")

    @test Triple(a, p, d) in result  # a->b->d and a->c->d
end

@testset "Chain rule" begin
    n3 = """
    @prefix : <http://example.org/> .
    :a :step1 :b .
    :b :step2 :c .
    { ?x :step1 ?y . ?y :step2 ?z } => { ?x :result ?z } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    res = URIRef("http://example.org/result")
    a = URIRef("http://example.org/a")
    c = URIRef("http://example.org/c")

    @test Triple(a, res, c) in result
end

@testset "Self-loop / reflexive" begin
    n3 = """
    @prefix : <http://example.org/> .
    :a :knows :a .
    { ?x :knows ?y } => { ?y :knows ?x } .
    """
    g = parse_rdf(n3, N3Format())
    result = datalog_reason(g)

    knows = URIRef("http://example.org/knows")
    a = URIRef("http://example.org/a")

    @test Triple(a, knows, a) in result
    @test length(result) == 1  # only one triple, no duplicates
end

@testset "Large transitive chain" begin
    # Build :n0 :p :n1 . :n1 :p :n2 . ... :n49 :p :n50 .
    n3_lines = ["@prefix : <http://example.org/> ."]
    for i in 0:49
        push!(n3_lines, ":n$i :p :n$(i+1) .")
    end
    push!(n3_lines, "{ ?x :p ?y . ?y :p ?z } => { ?x :p ?z } .")

    g = parse_rdf(join(n3_lines, "\n"), N3Format())
    result = datalog_reason(g)

    p = URIRef("http://example.org/p")
    n0 = URIRef("http://example.org/n0")
    n50 = URIRef("http://example.org/n50")

    @test Triple(n0, p, n50) in result

    # Total triples: n*(n+1)/2 where n=50 = 1275 + the 50 original = 1275
    # Actually: 50 original + 50*49/2 transitive = 50 + 1225 = 1275
    p_triples = [t for t in triples(result) if t.predicate == p]
    @test length(p_triples) == 1275
end

@testset "DatalogProgram direct API" begin
    # Test using the DatalogProgram API directly (without N3 parsing)
    enc = RDFLib.TermEncoder()
    prog = RDFLib.DatalogProgram()

    # Encode terms
    a = RDFLib.encode_term!(enc, URIRef("http://example.org/a"))
    b = RDFLib.encode_term!(enc, URIRef("http://example.org/b"))
    c = RDFLib.encode_term!(enc, URIRef("http://example.org/c"))
    p = RDFLib.encode_term!(enc, URIRef("http://example.org/p"))

    # Add facts
    RDFLib.relation_add!(prog.facts, RDFLib.IntTriple(a, p, b))
    RDFLib.relation_add!(prog.facts, RDFLib.IntTriple(b, p, c))

    # Add transitive rule: {?x :p ?y . ?y :p ?z} => {?x :p ?z}
    v1 = RDFLib.VAR_FLAG | UInt32(1)
    v2 = RDFLib.VAR_FLAG | UInt32(2)
    v3 = RDFLib.VAR_FLAG | UInt32(3)
    body = [RDFLib.IntPattern(v1, p, v2), RDFLib.IntPattern(v2, p, v3)]
    head = [RDFLib.IntPattern(v1, p, v3)]
    push!(prog.rules, RDFLib.DatalogRule(head, body, 3))

    n_derived = RDFLib.semi_naive!(prog)
    @test n_derived == 1  # a :p c
    @test length(prog.facts.tuples) == 3
end

end
