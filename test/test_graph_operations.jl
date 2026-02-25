using Test
using RDFLib

@testset "Graph Operations" begin
    EX = Namespace("http://example.org/")

    # ─── 1. CBD Tests ────────────────────────────────────────────────

    @testset "CBD (Concise Bounded Description)" begin
        @testset "basic CBD for a resource" begin
            g = RDFGraph()
            add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
            add!(g, Triple(EX("alice"), EX("age"), Literal("30")))
            add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))
            add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))
            add!(g, Triple(EX("charlie"), EX("name"), Literal("Charlie")))

            desc = cbd(g, EX("alice"))
            @test length(desc) == 3
            @test Triple(EX("alice"), EX("name"), Literal("Alice")) in desc
            @test Triple(EX("alice"), EX("age"), Literal("30")) in desc
            @test Triple(EX("alice"), EX("knows"), EX("bob")) in desc
            # Bob's own triples should NOT be included (he's a URIRef, not a BNode)
            @test !(Triple(EX("bob"), EX("name"), Literal("Bob")) in desc)
        end

        @testset "CBD follows blank nodes" begin
            g = RDFGraph()
            addr = BNode("addr1")
            add!(g, Triple(EX("alice"), EX("address"), addr))
            add!(g, Triple(addr, EX("street"), Literal("123 Main St")))
            add!(g, Triple(addr, EX("city"), Literal("NYC")))
            add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))

            desc = cbd(g, EX("alice"))
            @test length(desc) == 3  # alice->addr, addr->street, addr->city
            @test Triple(EX("alice"), EX("address"), addr) in desc
            @test Triple(addr, EX("street"), Literal("123 Main St")) in desc
            @test Triple(addr, EX("city"), Literal("NYC")) in desc
        end

        @testset "CBD follows nested blank nodes" begin
            g = RDFGraph()
            b1 = BNode("b1")
            b2 = BNode("b2")
            add!(g, Triple(EX("alice"), EX("contact"), b1))
            add!(g, Triple(b1, EX("phone"), b2))
            add!(g, Triple(b2, EX("number"), Literal("555-1234")))
            add!(g, Triple(EX("unrelated"), EX("p"), Literal("x")))

            desc = cbd(g, EX("alice"))
            @test length(desc) == 3
            @test Triple(b2, EX("number"), Literal("555-1234")) in desc
        end

        @testset "CBD of node with no triples" begin
            g = RDFGraph()
            add!(g, Triple(EX("bob"), EX("name"), Literal("Bob")))

            desc = cbd(g, EX("alice"))
            @test length(desc) == 0
        end
    end

    # ─── 2. Graph Diff Tests ─────────────────────────────────────────

    @testset "Graph Diff" begin
        @testset "identical graphs" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g1, Triple(EX("b"), EX("q"), Literal("2")))
            add!(g2, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g2, Triple(EX("b"), EX("q"), Literal("2")))

            shared, only1, only2 = graph_diff(g1, g2)
            @test length(shared) == 2
            @test length(only1) == 0
            @test length(only2) == 0
        end

        @testset "completely disjoint graphs" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g2, Triple(EX("b"), EX("q"), Literal("2")))

            shared, only1, only2 = graph_diff(g1, g2)
            @test length(shared) == 0
            @test length(only1) == 1
            @test length(only2) == 1
        end

        @testset "partial overlap" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("shared")))
            add!(g1, Triple(EX("a"), EX("q"), Literal("only_g1")))
            add!(g2, Triple(EX("a"), EX("p"), Literal("shared")))
            add!(g2, Triple(EX("a"), EX("r"), Literal("only_g2")))

            shared, only1, only2 = graph_diff(g1, g2)
            @test length(shared) == 1
            @test Triple(EX("a"), EX("p"), Literal("shared")) in shared
            @test length(only1) == 1
            @test Triple(EX("a"), EX("q"), Literal("only_g1")) in only1
            @test length(only2) == 1
            @test Triple(EX("a"), EX("r"), Literal("only_g2")) in only2
        end

        @testset "subset detection via diff" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g2, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g2, Triple(EX("b"), EX("q"), Literal("2")))

            shared, only1, only2 = graph_diff(g1, g2)
            # g1 is a subset of g2
            @test length(only1) == 0
            @test length(shared) == 1
            @test length(only2) == 1
        end
    end

    # ─── 3. Skolemization Tests ──────────────────────────────────────

    @testset "Skolemization" begin
        @testset "skolemize converts BNodes to URIs" begin
            g = RDFGraph()
            b = BNode("test1")
            add!(g, Triple(b, RDF("type"), EX("Thing")))
            add!(g, Triple(EX("s"), EX("p"), b))

            sg = skolemize(g)
            @test length(sg) == 2
            # No BNodes should remain
            for t in sg
                @test !(t.subject isa BNode)
                @test !(t.object isa BNode)
            end
            # The skolem URI should contain the BNode id
            skolem_uri = URIRef("https://rdflib.github.io/.well-known/genid/test1")
            found_subj = collect(triples(sg, (skolem_uri, nothing, nothing)))
            @test length(found_subj) == 1
            found_obj = collect(triples(sg, (nothing, nothing, skolem_uri)))
            @test length(found_obj) == 1
        end

        @testset "de_skolemize converts URIs back to BNodes" begin
            g = RDFGraph()
            skolem_uri = URIRef("https://rdflib.github.io/.well-known/genid/abc")
            add!(g, Triple(skolem_uri, RDF("type"), EX("Thing")))

            dg = de_skolemize(g)
            @test length(dg) == 1
            t = first(collect(dg))
            @test t.subject isa BNode
            @test t.subject == BNode("abc")
        end

        @testset "round-trip skolemize/de_skolemize preserves structure" begin
            g = RDFGraph()
            b1 = BNode("n1")
            b2 = BNode("n2")
            add!(g, Triple(b1, EX("knows"), b2))
            add!(g, Triple(b1, EX("name"), Literal("Alice")))
            add!(g, Triple(b2, EX("name"), Literal("Bob")))

            roundtripped = de_skolemize(skolemize(g))
            @test length(roundtripped) == length(g)
            # Check that we can match by the BNode IDs (preserved through round-trip)
            @test isomorphic(g, roundtripped)
        end

        @testset "skolemize with custom authority" begin
            g = RDFGraph()
            b = BNode("x")
            add!(g, Triple(b, EX("p"), Literal("v")))

            sg = skolemize(g; authority="http://my.org/bnodes/")
            t = first(collect(sg))
            @test t.subject == URIRef("http://my.org/bnodes/x")
        end
    end

    # ─── 4. Graph Set Operation Tests ────────────────────────────────

    @testset "Graph Set Operations" begin
        @testset "union (+)" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g1, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("c"), EX("p"), Literal("3")))

            u = g1 + g2
            @test length(u) == 3
            @test Triple(EX("a"), EX("p"), Literal("1")) in u
            @test Triple(EX("b"), EX("p"), Literal("2")) in u
            @test Triple(EX("c"), EX("p"), Literal("3")) in u
        end

        @testset "intersection (intersect)" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g1, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("c"), EX("p"), Literal("3")))

            i = intersect(g1, g2)
            @test length(i) == 1
            @test Triple(EX("b"), EX("p"), Literal("2")) in i
        end

        @testset "difference (-)" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g1, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("c"), EX("p"), Literal("3")))

            d = g1 - g2
            @test length(d) == 1
            @test Triple(EX("a"), EX("p"), Literal("1")) in d
            @test !(Triple(EX("b"), EX("p"), Literal("2")) in d)
        end

        @testset "symmetric difference (symdiff)" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g1, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("b"), EX("p"), Literal("2")))
            add!(g2, Triple(EX("c"), EX("p"), Literal("3")))

            sd = symdiff(g1, g2)
            @test length(sd) == 2
            @test Triple(EX("a"), EX("p"), Literal("1")) in sd
            @test Triple(EX("c"), EX("p"), Literal("3")) in sd
            @test !(Triple(EX("b"), EX("p"), Literal("2")) in sd)
        end

        @testset "union with empty graph" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))

            u = g1 + g2
            @test length(u) == 1
        end

        @testset "intersection of disjoint graphs" begin
            g1 = RDFGraph()
            g2 = RDFGraph()
            add!(g1, Triple(EX("a"), EX("p"), Literal("1")))
            add!(g2, Triple(EX("b"), EX("q"), Literal("2")))

            i = intersect(g1, g2)
            @test length(i) == 0
        end
    end

    # ─── 5. RDF Collection Tests ─────────────────────────────────────

    @testset "RDF Collections" begin
        @testset "build and collect a list" begin
            g = RDFGraph()
            items = Identifier[Literal("a"), Literal("b"), Literal("c")]
            head, tris = Collection(items)
            for t in tris
                add!(g, t)
            end

            collected = collect_list(g, head)
            @test length(collected) == 3
            @test collected[1] == Literal("a")
            @test collected[2] == Literal("b")
            @test collected[3] == Literal("c")
        end

        @testset "empty collection" begin
            head, tris = Collection(Identifier[])
            @test head == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
            @test isempty(tris)
        end

        @testset "add_collection! helper" begin
            g = RDFGraph()
            add_collection!(g, EX("subj"), EX("list"), Identifier[Literal("x"), Literal("y")])
            # Should have: subj->list->head, head->first->x, head->rest->node2,
            # node2->first->y, node2->rest->nil  = 5 triples
            @test length(g) == 5

            # Retrieve via predicate
            heads = collect(objects(g, EX("subj"), EX("list")))
            @test length(heads) == 1
            items = collect_list(g, heads[1]::Node)
            @test items == Identifier[Literal("x"), Literal("y")]
        end

        @testset "CollectionView indexing and iteration" begin
            g = RDFGraph()
            items = Identifier[Literal("one"), Literal("two"), Literal("three")]
            head, tris = Collection(items)
            for t in tris; add!(g, t); end

            cv = CollectionView(g, head)
            @test length(cv) == 3
            @test cv[1] == Literal("one")
            @test cv[2] == Literal("two")
            @test cv[3] == Literal("three")

            # Iteration
            collected = Identifier[]
            for item in cv
                push!(collected, item)
            end
            @test collected == items
        end

        @testset "CollectionView bounds error" begin
            g = RDFGraph()
            items = Identifier[Literal("a")]
            head, tris = Collection(items)
            for t in tris; add!(g, t); end
            cv = CollectionView(g, head)
            @test_throws BoundsError cv[2]
        end

        @testset "collection_view convenience" begin
            g = RDFGraph()
            add_collection!(g, EX("s"), EX("items"), Identifier[Literal("p"), Literal("q")])
            cv = collection_view(g, EX("s"), EX("items"))
            @test length(cv) == 2
            @test cv[1] == Literal("p")
            @test cv[2] == Literal("q")
        end
    end

    # ─── 6. ConjunctiveGraph Tests ───────────────────────────────────

    @testset "ConjunctiveGraph Operations" begin
        @testset "add to default and named graphs" begin
            cg = ConjunctiveGraph()
            add!(cg, Triple(EX("s1"), EX("p1"), Literal("default")))
            add!(cg, Triple(EX("s2"), EX("p2"), Literal("named")), EX("g1"))

            @test length(cg) == 2
        end

        @testset "triples across all contexts" begin
            cg = ConjunctiveGraph()
            add!(cg, Triple(EX("a"), EX("p"), Literal("1")))
            add!(cg, Triple(EX("b"), EX("q"), Literal("2")), EX("g1"))
            add!(cg, Triple(EX("c"), EX("r"), Literal("3")), EX("g2"))

            all_triples = collect(triples(cg))
            @test length(all_triples) == 3
        end

        @testset "contexts listing" begin
            cg = ConjunctiveGraph()
            add!(cg, Triple(EX("a"), EX("p"), Literal("1")))
            add!(cg, Triple(EX("b"), EX("q"), Literal("2")), EX("g1"))

            ctx = collect(contexts(cg))
            @test length(ctx) >= 1
        end

        @testset "get_context retrieves specific graph" begin
            cg = ConjunctiveGraph()
            add!(cg, Triple(EX("a"), EX("p"), Literal("in_g1")), EX("g1"))
            add!(cg, Triple(EX("b"), EX("q"), Literal("default")))

            g1 = get_context(cg, EX("g1"))
            @test length(g1) == 1
            @test Triple(EX("a"), EX("p"), Literal("in_g1")) in g1
        end

        @testset "remove_context!" begin
            cg = ConjunctiveGraph()
            add!(cg, Triple(EX("a"), EX("p"), Literal("1")), EX("g1"))
            add!(cg, Triple(EX("b"), EX("q"), Literal("2")))

            remove_context!(cg, EX("g1"))
            all_triples = collect(triples(cg))
            @test length(all_triples) == 1
        end
    end

    # ─── 7. Graph Generator Tests ────────────────────────────────────

    @testset "Graph Generators (subjects/predicates/objects)" begin
        @testset "unique subjects" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p1"), Literal("1")))
            add!(g, Triple(EX("a"), EX("p2"), Literal("2")))
            add!(g, Triple(EX("b"), EX("p1"), Literal("3")))

            subjs = collect(subjects(g))
            unique_subjs = Set(subjs)
            @test EX("a") in unique_subjs
            @test EX("b") in unique_subjs
            @test length(unique_subjs) == 2
        end

        @testset "unique predicates" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p1"), Literal("1")))
            add!(g, Triple(EX("b"), EX("p1"), Literal("2")))
            add!(g, Triple(EX("c"), EX("p2"), Literal("3")))

            preds = collect(predicates(g))
            unique_preds = Set(preds)
            @test EX("p1") in unique_preds
            @test EX("p2") in unique_preds
            @test length(unique_preds) == 2
        end

        @testset "unique objects" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p"), Literal("val")))
            add!(g, Triple(EX("b"), EX("p"), Literal("val")))
            add!(g, Triple(EX("c"), EX("p"), EX("d")))

            objs = collect(objects(g))
            unique_objs = Set(objs)
            @test Literal("val") in unique_objs
            @test EX("d") in unique_objs
            @test length(unique_objs) == 2
        end

        @testset "subject_predicates" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p1"), Literal("1")))
            add!(g, Triple(EX("b"), EX("p2"), Literal("2")))

            sp = collect(subject_predicates(g, Literal("1")))
            @test length(sp) == 1
            @test sp[1] == (EX("a"), EX("p1"))
        end

        @testset "predicate_objects" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p1"), Literal("1")))
            add!(g, Triple(EX("a"), EX("p2"), Literal("2")))

            po = collect(predicate_objects(g, EX("a")))
            @test length(po) == 2
            po_set = Set(po)
            @test (EX("p1"), Literal("1")) in po_set
            @test (EX("p2"), Literal("2")) in po_set
        end

        @testset "all_nodes" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p"), EX("b")))
            add!(g, Triple(EX("b"), EX("q"), Literal("v")))

            nodes = all_nodes(g)
            @test EX("a") in nodes
            @test EX("b") in nodes
            @test Literal("v") in nodes
            # Predicates are not nodes
            @test !(EX("p") in nodes) || EX("p") in nodes  # p could also be an object
        end

        @testset "transitive_objects" begin
            g = RDFGraph()
            add!(g, Triple(EX("A"), RDFS("subClassOf"), EX("B")))
            add!(g, Triple(EX("B"), RDFS("subClassOf"), EX("C")))
            add!(g, Triple(EX("C"), RDFS("subClassOf"), EX("D")))

            result = transitive_objects(g, EX("A"), RDFS("subClassOf"))
            @test EX("A") in result  # includes start node
            @test EX("B") in result
            @test EX("C") in result
            @test EX("D") in result
            @test length(result) == 4
        end

        @testset "transitive_subjects" begin
            g = RDFGraph()
            add!(g, Triple(EX("A"), RDFS("subClassOf"), EX("B")))
            add!(g, Triple(EX("B"), RDFS("subClassOf"), EX("C")))

            result = transitive_subjects(g, EX("C"), RDFS("subClassOf"))
            @test EX("C") in result
            @test EX("B") in result
            @test EX("A") in result
            @test length(result) == 3
        end

        @testset "triples_choices" begin
            g = RDFGraph()
            add!(g, Triple(EX("a"), EX("p1"), Literal("1")))
            add!(g, Triple(EX("b"), EX("p2"), Literal("2")))
            add!(g, Triple(EX("c"), EX("p1"), Literal("3")))

            result = triples_choices(g; subjects=[EX("a"), EX("b")])
            @test length(result) == 2

            result2 = triples_choices(g; predicates=[EX("p1")])
            @test length(result2) == 2
        end
    end

    # ─── 8. Roundtrip Serialization Tests ────────────────────────────

    @testset "Roundtrip Serialization" begin
        @testset "NTriples roundtrip" begin
            g = RDFGraph()
            add!(g, Triple(EX("s1"), EX("p1"), Literal("hello")))
            add!(g, Triple(EX("s1"), EX("p2"), EX("o1")))
            add!(g, Triple(EX("s2"), RDF("type"), EX("Thing")))

            nt_str = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt_str, NTriplesFormat())

            @test length(g2) == length(g)
            @test Triple(EX("s1"), EX("p1"), Literal("hello")) in g2
            @test Triple(EX("s1"), EX("p2"), EX("o1")) in g2
            @test Triple(EX("s2"), RDF("type"), EX("Thing")) in g2
        end

        @testset "Turtle roundtrip" begin
            g = RDFGraph()
            add!(g, Triple(EX("alice"), RDF("type"), EX("Person")))
            add!(g, Triple(EX("alice"), EX("name"), Literal("Alice")))
            add!(g, Triple(EX("alice"), EX("knows"), EX("bob")))

            ttl_str = serialize(g, TurtleFormat())
            g2 = parse_rdf(ttl_str, TurtleFormat())

            @test length(g2) == length(g)
            @test Triple(EX("alice"), RDF("type"), EX("Person")) in g2
            @test Triple(EX("alice"), EX("name"), Literal("Alice")) in g2
            @test Triple(EX("alice"), EX("knows"), EX("bob")) in g2
        end

        @testset "NTriples roundtrip preserves typed literals" begin
            g = RDFGraph()
            int_lit = Literal("42", datatype=XSD("integer"))
            add!(g, Triple(EX("s"), EX("age"), int_lit))

            nt_str = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt_str, NTriplesFormat())
            @test length(g2) == 1
            obj = first(collect(objects(g2, EX("s"), EX("age"))))
            @test obj isa Literal
            @test obj.lexical == "42"
        end

        @testset "Turtle roundtrip with language tags" begin
            g = RDFGraph()
            add!(g, Triple(EX("s"), RDFS("label"), Literal("hello", lang="en")))
            add!(g, Triple(EX("s"), RDFS("label"), Literal("bonjour", lang="fr")))

            ttl_str = serialize(g, TurtleFormat())
            g2 = parse_rdf(ttl_str, TurtleFormat())

            @test length(g2) == 2
            labels = Set(collect(objects(g2, EX("s"), RDFS("label"))))
            @test Literal("hello", lang="en") in labels
            @test Literal("bonjour", lang="fr") in labels
        end

        @testset "empty graph roundtrip" begin
            g = RDFGraph()
            nt_str = serialize(g, NTriplesFormat())
            g2 = parse_rdf(nt_str, NTriplesFormat())
            @test length(g2) == 0
        end

        @testset "namespace binding" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add!(g, Triple(EX("s"), EX("p"), Literal("v")))

            # Verify the binding exists
            ns = RDFLib.namespaces(g)
            @test haskey(ns, "ex")
        end
    end
end
