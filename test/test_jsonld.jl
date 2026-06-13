using Test
using RDFLib

@testset "JSON-LD" begin
    EX = Namespace("http://example.org/")
    RDF_FIRST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
    RDF_REST = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
    RDF_NIL = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
    RDF_JSON = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON")

    # Walk an rdf:first/rdf:rest chain, returning the item terms
    function walk_list(g, head)
        items = []
        cur = head
        while cur != RDF_NIL
            fs = collect(objects(g, cur, RDF_FIRST))
            rs = collect(objects(g, cur, RDF_REST))
            (length(fs) == 1 && length(rs) == 1) || return nothing
            push!(items, fs[1])
            cur = rs[1]
        end
        items
    end

    @testset "serialization" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        jsonld = serialize(g, JSONLDFormat())

        @test contains(jsonld, "@context") || contains(jsonld, "@id")
        @test contains(jsonld, "http://example.org/alice")
        @test contains(jsonld, "Alice")
    end

    @testset "serialization - types" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        jsonld = serialize(g, JSONLDFormat())
        @test contains(jsonld, "@type")
    end

    @testset "serialization - numeric" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("age"), Literal(30))
        jsonld = serialize(g, JSONLDFormat())
        @test contains(jsonld, "30")
    end

    @testset "parsing" begin
        jsonld = """{
            "@context": {
                "ex": "http://example.org/"
            },
            "@id": "http://example.org/alice",
            "@type": "ex:Person",
            "ex:name": "Alice"
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 2  # type + name

        type_objs = collect(objects(g, EX("alice"), RDF.type))
        @test EX("Person") in type_objs
    end

    @testset "parsing - @graph" begin
        jsonld = """{
            "@context": {
                "ex": "http://example.org/"
            },
            "@graph": [
                {
                    "@id": "http://example.org/alice",
                    "ex:name": "Alice"
                },
                {
                    "@id": "http://example.org/bob",
                    "ex:name": "Bob"
                }
            ]
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 2
    end

    @testset "parsing - language tag" begin
        jsonld = """{
            "@id": "http://example.org/alice",
            "http://www.w3.org/2000/01/rdf-schema#label": {
                "@value": "Alice",
                "@language": "en"
            }
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        objs = collect(objects(g, EX("alice"), RDFS.label))
        @test length(objs) == 1
        @test lang(objs[1]) == "en"
    end

    @testset "parsing - datatype" begin
        jsonld = """{
            "@id": "http://example.org/alice",
            "http://example.org/age": {
                "@value": "30",
                "@type": "http://www.w3.org/2001/XMLSchema#integer"
            }
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        objs = collect(objects(g, EX("alice"), EX("age")))
        @test length(objs) == 1
        @test convert(Any, objs[1]) == 30
    end

    @testset "parsing - native types" begin
        jsonld = """{
            "@context": { "ex": "http://example.org/" },
            "@id": "http://example.org/s",
            "ex:count": 42,
            "ex:ratio": 3.14,
            "ex:active": true
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 3
    end

    @testset "parsing - nested node objects" begin
        # Nested nodes now produce triples (previously dropped)
        jsonld = """{
            "@context": { "ex": "http://example.org/" },
            "@id": "http://example.org/alice",
            "ex:knows": {
                "@id": "http://example.org/bob",
                "ex:name": "Bob"
            }
        }"""
        g = parse_rdf(jsonld, JSONLDFormat())
        @test length(g) == 2
        @test EX("bob") in collect(objects(g, EX("alice"), EX("knows")))
        @test Literal("Bob") in collect(objects(g, EX("bob"), EX("name")))
    end

    @testset "round-trip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice"))

        jsonld = serialize(g1, JSONLDFormat())
        g2 = parse_rdf(jsonld, JSONLDFormat())

        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # @list <-> rdf:first/rdf:rest/rdf:nil (JSON-LD 1.1 §4.3.1 Lists)
    # ═══════════════════════════════════════════════════════════════════
    @testset "@list to RDF" begin
        @testset "@container @list parses to a chain" begin
            jsonld = """{
                "@context": {
                    "ex": "http://example.org/",
                    "items": {"@id": "ex:items", "@container": "@list"}
                },
                "@id": "http://example.org/s",
                "items": ["a", "b", "c"]
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            # 1 link triple + 3 cons cells x (first + rest)
            @test length(g) == 7
            heads = collect(objects(g, EX("s"), EX("items")))
            @test length(heads) == 1
            items = walk_list(g, heads[1])
            @test items !== nothing
            @test items == [Literal("a"), Literal("b"), Literal("c")]
        end

        @testset "explicit @list keyword parses to a chain" begin
            jsonld = """{
                "@id": "http://example.org/s",
                "http://example.org/items": {"@list": [{"@id": "http://example.org/a"}, "x"]}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            heads = collect(objects(g, EX("s"), EX("items")))
            items = walk_list(g, heads[1])
            @test items == [EX("a"), Literal("x")]
        end

        @testset "empty @list is rdf:nil" begin
            jsonld = """{
                "@id": "http://example.org/s",
                "http://example.org/items": {"@list": []}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test length(g) == 1
            @test RDF_NIL in collect(objects(g, EX("s"), EX("items")))
        end

        @testset "serializing a collection emits @list" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add_collection!(g, EX("s"), EX("items"), [EX("a"), EX("b"), Literal("three")])
            s = serialize(g, JSONLDFormat())
            @test contains(s, "@list")
            # blank list nodes must not appear as graph subjects
            @test !contains(s, "rdf-syntax-ns#first")
        end

        @testset "list round-trip preserves structure" begin
            g = RDFGraph()
            bind!(g, "ex", EX)
            add_collection!(g, EX("s"), EX("items"), [EX("a"), EX("b"), EX("c")])
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test length(g2) == length(g)
            @test isomorphic(g, g2)
        end

        @testset "nested list round-trip" begin
            jsonld = """{
                "@id": "http://example.org/s",
                "http://example.org/coords": {"@list": [{"@list": ["a", "b"]}, "c"]}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test isomorphic(g, g2)
            heads = collect(objects(g, EX("s"), EX("coords")))
            items = walk_list(g, heads[1])
            @test length(items) == 2
            inner = walk_list(g, items[1])
            @test inner == [Literal("a"), Literal("b")]
        end

        @testset "shared blank node is not converted to @list" begin
            # A chain node referenced twice cannot be losslessly inlined
            g = RDFGraph()
            b = BNode("shared")
            add!(g, b, RDF_FIRST, Literal("x"))
            add!(g, b, RDF_REST, RDF_NIL)
            add!(g, EX("s"), EX("p1"), b)
            add!(g, EX("s"), EX("p2"), b)
            s = serialize(g, JSONLDFormat())
            @test !contains(s, "@list")
            g2 = parse_rdf(s, JSONLDFormat())
            @test length(g2) == length(g)
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # @reverse (JSON-LD 1.1 §4.8 Reverse Properties)
    # ═══════════════════════════════════════════════════════════════════
    @testset "@reverse to RDF" begin
        @testset "@reverse keyword swaps subject/object" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/"},
                "@id": "http://example.org/bob",
                "@reverse": {"ex:knows": {"@id": "http://example.org/alice"}}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test length(g) == 1
            @test EX("bob") in collect(objects(g, EX("alice"), EX("knows")))
        end

        @testset "reverse term swaps subject/object" begin
            jsonld = """{
                "@context": {
                    "ex": "http://example.org/",
                    "isParentOf": {"@reverse": "ex:parent"}
                },
                "@id": "http://example.org/dad",
                "isParentOf": [{"@id": "http://example.org/kid1"},
                               {"@id": "http://example.org/kid2"}]
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test length(g) == 2
            @test EX("dad") in collect(objects(g, EX("kid1"), EX("parent")))
            @test EX("dad") in collect(objects(g, EX("kid2"), EX("parent")))
        end

        @testset "reverse node with properties" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/"},
                "@id": "http://example.org/bob",
                "@reverse": {
                    "ex:knows": {"@id": "http://example.org/alice", "ex:name": "Alice"}
                }
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test length(g) == 2
            @test EX("bob") in collect(objects(g, EX("alice"), EX("knows")))
            @test Literal("Alice") in collect(objects(g, EX("alice"), EX("name")))
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # @direction <-> Literal direction (JSON-LD 1.1 §4.2.4)
    # ═══════════════════════════════════════════════════════════════════
    @testset "@direction" begin
        @testset "serialization emits @direction" begin
            g = RDFGraph()
            add!(g, EX("s"), EX("title"), Literal("שלום", lang="he", direction="rtl"))
            s = serialize(g, JSONLDFormat())
            @test contains(s, "@direction")
            @test contains(s, "rtl")
        end

        @testset "direction literal round-trip" begin
            g = RDFGraph()
            lit = Literal("שלום", lang="he", direction="rtl")
            add!(g, EX("s"), EX("title"), lit)
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test length(g2) == 1
            obj = first(objects(g2, EX("s"), EX("title")))
            @test obj == lit
            @test direction(obj) == "rtl"
        end

        @testset "parsing value object @direction" begin
            jsonld = """{
                "@id": "http://example.org/s",
                "http://example.org/title": {
                    "@value": "פעילות", "@language": "he", "@direction": "rtl"
                }
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            obj = first(objects(g, EX("s"), EX("title")))
            @test lang(obj) == "he"
            @test direction(obj) == "rtl"
        end

        @testset "parsing context default @direction" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/",
                             "@language": "ar", "@direction": "rtl"},
                "@id": "http://example.org/s",
                "ex:title": "عنوان"
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            obj = first(objects(g, EX("s"), EX("title")))
            @test lang(obj) == "ar"
            @test direction(obj) == "rtl"
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # rdf:JSON literals (JSON-LD 1.1 §4.2.5 JSON Literals)
    # ═══════════════════════════════════════════════════════════════════
    @testset "rdf:JSON literals" begin
        @testset "@json term parses to rdf:JSON literal" begin
            jsonld = """{
                "@context": {"e": {"@id": "http://example.org/data", "@type": "@json"}},
                "@id": "http://example.org/s",
                "e": {"a": 1}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            obj = first(objects(g, EX("s"), EX("data")))
            @test obj isa Literal
            @test datatype(obj) == RDF_JSON
            @test contains(obj.lexical, "\"a\"")
        end

        @testset "rdf:JSON literal round-trip preserves lexical form" begin
            g = RDFGraph()
            lit = Literal("""{"a":1,"b":[true,null]}""", datatype=RDF_JSON)
            add!(g, EX("s"), EX("data"), lit)
            s = serialize(g, JSONLDFormat())
            g2 = parse_rdf(s, JSONLDFormat())
            @test length(g2) == 1
            @test lit in collect(objects(g2, EX("s"), EX("data")))
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # Container maps to RDF
    # ═══════════════════════════════════════════════════════════════════
    @testset "container maps to RDF" begin
        @testset "language map (§4.6.2)" begin
            jsonld = """{
                "@context": {"label": {"@id": "http://example.org/label",
                                       "@container": "@language"}},
                "@id": "http://example.org/q",
                "label": {"en": "Queen", "de": "Königin"}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            objs = collect(objects(g, EX("q"), EX("label")))
            @test length(objs) == 2
            @test Set(lang(o) for o in objs) == Set(["en", "de"])
        end

        @testset "index map drops @index in RDF (§4.6.1)" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/",
                             "athletes": {"@id": "ex:athlete", "@container": "@index"}},
                "@id": "http://example.org/team",
                "athletes": {
                    "catcher": {"@id": "ex:p1", "ex:name": "Smith"},
                    "pitcher": {"@id": "ex:p2", "ex:name": "Jones"}
                }
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            objs = collect(objects(g, EX("team"), EX("athlete")))
            @test Set(objs) == Set([EX("p1"), EX("p2")])
            @test length(g) == 4
        end

        @testset "id map (§4.6.3)" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/",
                             "post": {"@id": "ex:post", "@container": "@id"}},
                "@id": "http://example.org/blog",
                "post": {
                    "http://example.org/posts/1": {"ex:title": "First"}
                }
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test URIRef("http://example.org/posts/1") in
                  collect(objects(g, EX("blog"), EX("post")))
            @test Literal("First") in
                  collect(objects(g, URIRef("http://example.org/posts/1"), EX("title")))
        end

        @testset "type map (§4.6.4)" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/",
                             "affiliation": {"@id": "ex:affiliation", "@container": "@type"}},
                "@id": "http://example.org/me",
                "affiliation": {"ex:Corporation": {"@id": "ex:corp"}}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test EX("corp") in collect(objects(g, EX("me"), EX("affiliation")))
            @test EX("Corporation") in collect(objects(g, EX("corp"), RDF.type))
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # @nest, scoped contexts, @vocab/@base on parse
    # ═══════════════════════════════════════════════════════════════════
    @testset "advanced contexts to RDF" begin
        @testset "@nest properties are unfolded (§4.10)" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/",
                             "labels": "@nest",
                             "main": {"@id": "ex:prefLabel", "@nest": "labels"}},
                "@id": "http://example.org/n",
                "labels": {"main": "Main"}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test Literal("Main") in collect(objects(g, EX("n"), EX("prefLabel")))
        end

        @testset "property-scoped context (§4.1.8)" begin
            jsonld = """{
                "@context": {"ex": "http://example.org/",
                             "detail": {"@id": "ex:detail",
                                        "@context": {"name": "ex:name"}}},
                "@id": "http://example.org/thing",
                "detail": {"@id": "http://example.org/d1", "name": "inner"}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            @test EX("d1") in collect(objects(g, EX("thing"), EX("detail")))
            @test Literal("inner") in collect(objects(g, EX("d1"), EX("name")))
        end

        @testset "@vocab and @base (§4.1.2, §4.1.3)" begin
            jsonld = """{
                "@context": {"@base": "http://example.org/",
                             "@vocab": "http://example.org/vocab#"},
                "@id": "alice",
                "knows": {"@id": "bob"}
            }"""
            g = parse_rdf(jsonld, JSONLDFormat())
            V = Namespace("http://example.org/vocab#")
            @test EX("bob") in collect(objects(g, EX("alice"), V("knows")))
        end

        @testset "remote context via injected loader" begin
            loader = url -> begin
                url == "http://remote.example/ctx.jsonld" || error("unexpected URL $url")
                """{"@context": {"name": "http://example.org/name"}}"""
            end
            jsonld = """{
                "@context": "http://remote.example/ctx.jsonld",
                "@id": "http://example.org/alice",
                "name": "Alice"
            }"""
            g = RDFGraph()
            RDFLib.parse_jsonld!(g, jsonld; context_loader=loader)
            @test Literal("Alice") in collect(objects(g, EX("alice"), EX("name")))
        end

        @testset "base keyword argument on parse" begin
            jsonld = """{"@id": "alice", "http://example.org/p": {"@id": "bob"}}"""
            g = RDFGraph()
            RDFLib.parse_jsonld!(g, jsonld; base="http://example.org/")
            @test EX("bob") in collect(objects(g, EX("alice"), EX("p")))
        end
    end

    @testset "mixed round-trip with 1.1 features" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        add!(g, EX("alice"), EX("title"), Literal("מלכה", lang="he", direction="rtl"))
        add!(g, EX("alice"), EX("age"), Literal(30))
        add_collection!(g, EX("alice"), EX("nicknames"), [Literal("Al"), Literal("Ally")])
        b = BNode()
        add!(g, EX("alice"), EX("address"), b)
        add!(g, b, EX("city"), Literal("London"))

        s = serialize(g, JSONLDFormat())
        g2 = parse_rdf(s, JSONLDFormat())
        @test length(g2) == length(g)
        @test isomorphic(g, g2)
    end
end
