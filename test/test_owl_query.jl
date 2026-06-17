# Tests for OWL class-expression query rewriting + regime materialization
# (src/owl_query.jl), exercising the SPARQL entailment-regime answering path.

using Test
using RDFLib

@testset "OWL class-expression query rewriting" begin
    simple = """
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix : <http://example.org/test#> .
    :A a owl:Class . :B a owl:Class . :C a owl:Class .
    :p a owl:ObjectProperty , owl:FunctionalProperty .
    :a a :A , :B ; :p :b .
    :b a :B ; :p :c .
    :c a :C ; :p :d .
    :d a :A , :B , :C .
    """
    mkg() = (g = RDFGraph(); RDFLib.parse_turtle!(g, simple); RDFLib.materialize_entailment!(g, ["OWL-Direct"]); g)

    answer(q) = begin
        g = mkg()
        rows = sparql_query(g, RDFLib.rewrite_owl_query(q))
        rows = RDFLib.filter_entailment_results(g, rows)
        Set(String(r["x"].value) for r in rows)
    end
    P = "http://example.org/test#"

    @testset "intersectionOf" begin
        q = "PREFIX owl: <http://www.w3.org/2002/07/owl#> PREFIX : <$P> SELECT ?x WHERE { ?x a [ owl:intersectionOf ( :A :B ) ] }"
        @test answer(q) == Set([P*"a", P*"d"])
    end

    @testset "unionOf (distinct)" begin
        q = "PREFIX owl: <http://www.w3.org/2002/07/owl#> PREFIX : <$P> SELECT ?x WHERE { ?x a [ owl:unionOf ( :B :C ) ] }"
        @test answer(q) == Set([P*"a", P*"b", P*"c", P*"d"])
    end

    @testset "Restriction someValuesFrom" begin
        q = "PREFIX owl: <http://www.w3.org/2002/07/owl#> PREFIX : <$P> SELECT ?x WHERE { ?x a [ a owl:Restriction ; owl:onProperty :p ; owl:someValuesFrom :B ] }"
        # a→b(B), b→c, c→d(B): a (b is B), c (d is B)
        @test answer(q) == Set([P*"a", P*"c"])
    end

    @testset "nested intersection of restriction" begin
        q = "PREFIX owl: <http://www.w3.org/2002/07/owl#> PREFIX : <$P> SELECT ?x WHERE { ?x a [ owl:intersectionOf ( :A [ a owl:Restriction ; owl:onProperty :p ; owl:someValuesFrom :B ] ) ] }"
        @test answer(q) == Set([P*"a"])
    end

    @testset "oneOf → VALUES" begin
        q = "PREFIX owl: <http://www.w3.org/2002/07/owl#> PREFIX : <$P> SELECT ?x WHERE { ?x a [ owl:oneOf ( :a :d ) ] }"
        @test answer(q) == Set([P*"a", P*"d"])
    end

    @testset "rewrite is a no-op without class expressions" begin
        q = "SELECT ?x WHERE { ?x a ?c }"
        @test RDFLib.rewrite_owl_query(q) == q
    end
end

@testset "Graph-aware OWL-DL query rewriting" begin
    # Mirrors the W3C parent.ttl entailment fixture: Parent ≡ (hasChild some Thing);
    # Alice is an asserted Parent (no hasChild edge); Bob/Dudley have hasChild
    # edges; Dudley's hasChild role is CLOSED to {Alice} via allValuesFrom oneOf.
    parent = """
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix : <http://example.org/test#> .
    :hasChild a owl:ObjectProperty .
    :Female a owl:Class . :Male a owl:Class .
    :Parent a owl:Class ; owl:equivalentClass
        [ a owl:Restriction ; owl:onProperty :hasChild ; owl:someValuesFrom owl:Thing ] .
    :Alice a :Female , :Parent , owl:NamedIndividual .
    :Bob a :Male , owl:NamedIndividual ; :hasChild :Charlie .
    :Charlie a owl:NamedIndividual .
    :Dudley a owl:NamedIndividual ,
        [ a owl:Restriction ; owl:onProperty :hasChild ;
          owl:allValuesFrom [ a owl:Class ; owl:oneOf ( :Alice ) ] ] ;
        :hasChild :Alice .
    """
    mkg() = (g = RDFGraph(); RDFLib.parse_turtle!(g, parent; base = "http://example.org/test#");
             RDFLib.materialize_entailment!(g, ["OWL-Direct"]); g)
    P = "http://example.org/test#"
    answer(q) = begin
        g = mkg()
        rows = sparql_query(g, RDFLib.rewrite_owl_query(q, g))
        rows = RDFLib.filter_entailment_results(g, rows)
        Set(String(r["parent"].value) for r in rows)
    end
    pre = "PREFIX owl: <http://www.w3.org/2002/07/owl#> PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> PREFIX xsd: <http://www.w3.org/2001/XMLSchema#> PREFIX : <$P> "

    @testset "someValuesFrom owl:Thing matches equivalentClass member (Alice)" begin
        q = pre * "SELECT * WHERE { ?parent a [ a owl:Restriction ; owl:onProperty :hasChild ; owl:someValuesFrom owl:Thing ] }"
        @test answer(q) == Set([P*"Alice", P*"Bob", P*"Dudley"])
    end

    @testset "minCardinality 1 ≡ someValuesFrom owl:Thing" begin
        q = pre * "SELECT * WHERE { ?parent a [ a owl:Restriction ; owl:onProperty :hasChild ; owl:minCardinality \"1\"^^xsd:nonNegativeInteger ] }"
        @test answer(q) == Set([P*"Alice", P*"Bob", P*"Dudley"])
    end

    @testset "minQualifiedCardinality 1 onClass :Female ≡ some :Female" begin
        q = pre * "SELECT * WHERE { ?parent a [ a owl:Restriction ; owl:onProperty :hasChild ; owl:minQualifiedCardinality \"1\"^^xsd:nonNegativeInteger ; owl:onClass :Female ] }"
        @test answer(q) == Set([P*"Dudley"])
    end

    @testset "maxQualifiedCardinality 1 onClass :Female needs closed role (Dudley)" begin
        q = pre * "SELECT * WHERE { ?parent a [ a owl:Restriction ; owl:onProperty :hasChild ; owl:maxQualifiedCardinality \"1\"^^xsd:nonNegativeInteger ; owl:onClass :Female ] }"
        @test answer(q) == Set([P*"Dudley"])
    end

    @testset "qualifiedCardinality 1 onClass :Female (exactly 1) closed role (Dudley)" begin
        q = pre * "SELECT * WHERE { ?parent a [ a owl:Restriction ; owl:onProperty :hasChild ; owl:qualifiedCardinality \"1\"^^xsd:nonNegativeInteger ; owl:onClass :Female ] }"
        @test answer(q) == Set([P*"Dudley"])
    end
end

@testset "OWL-DL someValuesFrom complementOf via disjointness" begin
    # John/person1 publish paper1, a ConferencePaper ⊑ (publishedAt some Conference);
    # Conference disjointWith Workshop, so paper1 ∈ (publishedAt some (not Workshop)).
    data = """
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    @prefix : <http://example.org/> .
    :hasPublication a owl:ObjectProperty . :publishedAt a owl:ObjectProperty .
    :Conference a owl:Class ; owl:disjointWith :Workshop .
    :Workshop a owl:Class .
    :ConferencePaper a owl:Class ; rdfs:subClassOf
        [ a owl:Restriction ; owl:onProperty :publishedAt ; owl:someValuesFrom :Conference ] .
    :John a owl:NamedIndividual ; :hasPublication :paper1 .
    :person1 a owl:NamedIndividual ; :hasPublication :paper1 .
    :paper1 a :ConferencePaper , owl:NamedIndividual .
    """
    g = RDFGraph(); RDFLib.parse_turtle!(g, data; base = "http://example.org/")
    RDFLib.materialize_entailment!(g, ["OWL-Direct"])
    q = """
    PREFIX ex: <http://example.org/>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    SELECT ?x WHERE {
      ?x ex:hasPublication _:b0 .
      _:b0 rdf:type [ owl:onProperty ex:publishedAt ; rdf:type owl:Restriction ;
        owl:someValuesFrom [ rdf:type owl:Class ; owl:complementOf ex:Workshop ] ] }
    """
    rows = sparql_query(g, RDFLib.rewrite_owl_query(q, g))
    rows = RDFLib.filter_entailment_results(g, rows)
    got = Set(String(r["x"].value) for r in rows)
    @test got == Set(["http://example.org/John", "http://example.org/person1"])
end

@testset "Regime materialization completions" begin
    rdf_type = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    rdfProperty = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#Property")
    subClassOf = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
    subPropOf = URIRef("http://www.w3.org/2000/01/rdf-schema#subPropertyOf")
    sameAs = URIRef("http://www.w3.org/2002/07/owl#sameAs")

    @testset "RDF: predicate is rdf:Property, ObjectProperty ⊑ Property" begin
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        @prefix ex: <http://example.org/ns#> .
        @prefix owl: <http://www.w3.org/2002/07/owl#> .
        ex:b a owl:ObjectProperty .
        ex:a ex:b ex:c .
        """)
        RDFLib.materialize_entailment!(g, ["RDF"])
        @test Triple(URIRef("http://example.org/ns#b"), rdf_type, rdfProperty) in g
    end

    @testset "reflexive subClassOf for owl:Class" begin
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        @prefix : <http://example.org/x/> .
        @prefix owl: <http://www.w3.org/2002/07/owl#> .
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
        :c a owl:Class . :d a owl:Class . :c rdfs:subClassOf :d .
        :x a owl:NamedIndividual ; a :c .
        """)
        RDFLib.materialize_entailment!(g, ["RDFS"])
        @test Triple(URIRef("http://example.org/x/d"), subClassOf, URIRef("http://example.org/x/d")) in g
    end

    @testset "object property domain/range owl:Thing + inverseOf swap" begin
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        @prefix owl: <http://www.w3.org/2002/07/owl#>.
        @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#>.
        @prefix : <foo://bla/names#>.
        :child a owl:ObjectProperty ; rdfs:domain :Parent ; owl:inverseOf :parent .
        :parent a owl:ObjectProperty .
        """)
        RDFLib.materialize_entailment!(g, ["OWL-Direct"])
        rdfsRange = URIRef("http://www.w3.org/2000/01/rdf-schema#range")
        owlThing = URIRef("http://www.w3.org/2002/07/owl#Thing")
        # inverseOf: domain(child)=Parent ⊢ range(parent)=Parent
        @test Triple(URIRef("foo://bla/names#parent"), rdfsRange, URIRef("foo://bla/names#Parent")) in g
        # object property range owl:Thing
        @test Triple(URIRef("foo://bla/names#parent"), rdfsRange, owlThing) in g
    end

    @testset "reflexive sameAs over named individuals" begin
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        @prefix : <http://example.org/test#> .
        @prefix owl: <http://www.w3.org/2002/07/owl#> .
        :a a owl:NamedIndividual . :b a owl:NamedIndividual .
        """)
        RDFLib.materialize_entailment!(g, ["OWL-Direct"])
        @test Triple(URIRef("http://example.org/test#b"), sameAs, URIRef("http://example.org/test#b")) in g
    end

    @testset "owl:Nothing subClassOf every class" begin
        g = RDFGraph()
        RDFLib.parse_turtle!(g, """
        @prefix : <http://example.org/> .
        @prefix owl: <http://www.w3.org/2002/07/owl#> .
        :Student a owl:Class .
        """)
        RDFLib.materialize_entailment!(g, ["OWL-Direct"])
        owlNothing = URIRef("http://www.w3.org/2002/07/owl#Nothing")
        @test Triple(owlNothing, subClassOf, URIRef("http://example.org/Student")) in g
    end
end

@testset "Entailment result filtering of surrogate bnodes" begin
    g = RDFGraph()
    RDFLib.parse_turtle!(g, """
    @prefix : <http://example.org/test#> .
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    :Parent a owl:Class ; owl:equivalentClass [ a owl:Restriction ; owl:onProperty :hasChild ; owl:someValuesFrom owl:Thing ] .
    :hasChild a owl:ObjectProperty .
    """)
    RDFLib.materialize_entailment!(g, ["OWL-Direct"])
    sb = RDFLib._structural_bnodes(g)
    @test !isempty(sb)
    structural = first(sb)
    rows = [Dict{String,Identifier}("C" => structural),
            Dict{String,Identifier}("C" => URIRef("http://example.org/test#Parent"))]
    filtered = RDFLib.filter_entailment_results(g, rows)
    @test all(r -> r["C"] isa URIRef, filtered)
    @test length(filtered) == 1
end
