using Test, RDFLib

@testset "JSON-LD Processing" begin

    @testset "Expansion" begin
        @testset "simple properties" begin
            input = """{"@context": {"name": "http://schema.org/name"}, "@id": "http://ex.org/1", "name": "Alice"}"""
            result = jsonld_expand(input)
            @test length(result) == 1
            node = result[1]
            @test node["@id"] == "http://ex.org/1"
            @test haskey(node, "http://schema.org/name")
            vals = node["http://schema.org/name"]
            @test length(vals) == 1
            @test vals[1]["@value"] == "Alice"
        end

        @testset "@type handling" begin
            input = """{
                "@context": {"Person": "http://schema.org/Person"},
                "@id": "http://ex.org/1",
                "@type": "Person"
            }"""
            result = jsonld_expand(input)
            @test result[1]["@type"] == ["http://schema.org/Person"]
        end

        @testset "language strings" begin
            input = """{
                "@context": {"@language": "en", "name": "http://schema.org/name"},
                "@id": "http://ex.org/1",
                "name": "Alice"
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://schema.org/name"]
            @test vals[1]["@value"] == "Alice"
            @test vals[1]["@language"] == "en"
        end

        @testset "nested objects" begin
            input = """{
                "@context": {
                    "name": "http://schema.org/name",
                    "knows": "http://schema.org/knows"
                },
                "@id": "http://ex.org/1",
                "name": "Alice",
                "knows": {
                    "@id": "http://ex.org/2",
                    "name": "Bob"
                }
            }"""
            result = jsonld_expand(input)
            @test length(result) == 1
            node = result[1]
            knows = node["http://schema.org/knows"]
            @test length(knows) == 1
            @test knows[1]["@id"] == "http://ex.org/2"
            @test knows[1]["http://schema.org/name"][1]["@value"] == "Bob"
        end

        @testset "multiple values" begin
            input = """{
                "@context": {"nick": "http://xmlns.com/foaf/0.1/nick"},
                "@id": "http://ex.org/1",
                "nick": ["Al", "Ally"]
            }"""
            result = jsonld_expand(input)
            nicks = result[1]["http://xmlns.com/foaf/0.1/nick"]
            @test length(nicks) == 2
            @test Set([nicks[1]["@value"], nicks[2]["@value"]]) == Set(["Al", "Ally"])
        end

        @testset "prefixed names" begin
            input = """{
                "@context": {"schema": "http://schema.org/"},
                "@id": "http://ex.org/1",
                "schema:name": "Alice"
            }"""
            result = jsonld_expand(input)
            @test haskey(result[1], "http://schema.org/name")
        end

        @testset "numeric values" begin
            input = """{
                "@context": {"age": "http://schema.org/age"},
                "@id": "http://ex.org/1",
                "age": 30
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://schema.org/age"]
            @test vals[1]["@value"] == 30
        end

        @testset "boolean values" begin
            input = """{
                "@context": {"active": "http://schema.org/active"},
                "@id": "http://ex.org/1",
                "active": true
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://schema.org/active"]
            @test vals[1]["@value"] == true
        end

        @testset "@type coercion to @id" begin
            input = """{
                "@context": {
                    "homepage": {"@id": "http://schema.org/url", "@type": "@id"}
                },
                "@id": "http://ex.org/1",
                "homepage": "http://alice.example.com"
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://schema.org/url"]
            @test vals[1]["@id"] == "http://alice.example.com"
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # JSON-LD 1.1 expansion features
    # ═══════════════════════════════════════════════════════════════════
    @testset "Expansion 1.1" begin
        # JSON-LD 1.1 §4.3.1 Lists ("@container": "@list", cf. Example 87)
        @testset "@container: @list" begin
            input = """{
                "@context": {"nick": {"@id": "http://xmlns.com/foaf/0.1/nick", "@container": "@list"}},
                "@id": "http://ex.org/1",
                "nick": ["joe", "bob", "JB"]
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://xmlns.com/foaf/0.1/nick"]
            @test length(vals) == 1
            @test haskey(vals[1], "@list")
            @test [v["@value"] for v in vals[1]["@list"]] == ["joe", "bob", "JB"]
        end

        # JSON-LD 1.1 §4.3.1 Lists, explicit @list keyword (cf. Example 86)
        @testset "explicit @list keyword" begin
            input = """{
                "@context": {"nick": "http://xmlns.com/foaf/0.1/nick"},
                "@id": "http://ex.org/1",
                "nick": {"@list": ["joe", "bob"]}
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://xmlns.com/foaf/0.1/nick"]
            @test haskey(vals[1], "@list")
            @test length(vals[1]["@list"]) == 2
        end

        # JSON-LD 1.1 §4.3.1: lists of lists (allowed in 1.1, cf. Example 89)
        @testset "nested lists" begin
            input = """{
                "@context": {"coords": {"@id": "http://ex.org/coords", "@container": "@list"}},
                "@id": "http://ex.org/road",
                "coords": [[[1.0, 2.0], [3.0, 4.0]]]
            }"""
            result = jsonld_expand(input)
            outer = result[1]["http://ex.org/coords"][1]
            @test haskey(outer, "@list")
            inner = outer["@list"][1]
            @test haskey(inner, "@list")
            @test inner["@list"][1]["@value"] == 1.0
        end

        # JSON-LD 1.1 §4.3.2 Sets: @set is unwrapped during expansion
        @testset "@set is unwrapped" begin
            input = """{
                "@context": {"nick": "http://xmlns.com/foaf/0.1/nick"},
                "@id": "http://ex.org/1",
                "nick": {"@set": ["joe", "bob"]}
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://xmlns.com/foaf/0.1/nick"]
            @test length(vals) == 2
            @test all(v -> haskey(v, "@value"), vals)
        end

        # JSON-LD 1.1 §4.8 Reverse Properties: @reverse keyword (cf. Example 119)
        @testset "@reverse keyword" begin
            input = """{
                "@id": "http://ex.org/bob",
                "@reverse": {
                    "http://xmlns.com/foaf/0.1/knows": {"@id": "http://ex.org/alice"}
                }
            }"""
            result = jsonld_expand(input)
            node = result[1]
            @test haskey(node, "@reverse")
            rev = node["@reverse"]["http://xmlns.com/foaf/0.1/knows"]
            @test rev[1]["@id"] == "http://ex.org/alice"
        end

        # JSON-LD 1.1 §4.8 Reverse Properties: reverse term (cf. Example 121)
        @testset "reverse term in context" begin
            input = """{
                "@context": {"isParentOf": {"@reverse": "http://ex.org/parent"}},
                "@id": "http://ex.org/dad",
                "isParentOf": [{"@id": "http://ex.org/kid1"}, {"@id": "http://ex.org/kid2"}]
            }"""
            result = jsonld_expand(input)
            node = result[1]
            @test haskey(node, "@reverse")
            kids = node["@reverse"]["http://ex.org/parent"]
            @test length(kids) == 2
            @test Set(k["@id"] for k in kids) == Set(["http://ex.org/kid1", "http://ex.org/kid2"])
        end

        @testset "reverse property rejects literals" begin
            input = """{
                "@context": {"rt": {"@reverse": "http://ex.org/p"}},
                "@id": "http://ex.org/x",
                "rt": "a literal"
            }"""
            @test_throws Exception jsonld_expand(input)
        end

        # JSON-LD 1.1 §4.6.2 Language Indexing (cf. Example 110)
        @testset "language map" begin
            input = """{
                "@context": {"label": {"@id": "http://ex.org/label", "@container": "@language"}},
                "@id": "http://ex.org/queen",
                "label": {"en": "The Queen", "de": ["Die Königin", "Ihre Majestät"]}
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://ex.org/label"]
            @test length(vals) == 3
            en = filter(v -> get(v, "@language", "") == "en", vals)
            de = filter(v -> get(v, "@language", "") == "de", vals)
            @test length(en) == 1 && en[1]["@value"] == "The Queen"
            @test length(de) == 2
        end

        @testset "language map with @none key" begin
            input = """{
                "@context": {"label": {"@id": "http://ex.org/label", "@container": "@language"}},
                "@id": "http://ex.org/x",
                "label": {"@none": "plain", "en": "english"}
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://ex.org/label"]
            plain = filter(v -> !haskey(v, "@language"), vals)
            @test length(plain) == 1 && plain[1]["@value"] == "plain"
        end

        # JSON-LD 1.1 §4.6.1 Data Indexing (cf. Example 105)
        @testset "index map preserves @index" begin
            input = """{
                "@context": {
                    "schema": "http://schema.org/",
                    "athletes": {"@id": "schema:athlete", "@container": "@index"}
                },
                "@id": "http://ex.org/team",
                "athletes": {
                    "catcher": {"@id": "http://ex.org/p1", "schema:name": "Smith"},
                    "pitcher": {"@id": "http://ex.org/p2", "schema:name": "Jones"}
                }
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://schema.org/athlete"]
            @test length(vals) == 2
            idxs = Set(v["@index"] for v in vals)
            @test idxs == Set(["catcher", "pitcher"])
        end

        # JSON-LD 1.1 §4.6.3 Node Identifier Indexing (cf. Example 113)
        @testset "id map" begin
            input = """{
                "@context": {
                    "ex": "http://ex.org/",
                    "post": {"@id": "ex:post", "@container": "@id"}
                },
                "@id": "http://ex.org/blog",
                "post": {
                    "http://ex.org/posts/1": {"ex:title": "First"},
                    "http://ex.org/posts/2": {"ex:title": "Second"}
                }
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://ex.org/post"]
            @test length(vals) == 2
            @test Set(v["@id"] for v in vals) ==
                  Set(["http://ex.org/posts/1", "http://ex.org/posts/2"])
        end

        # JSON-LD 1.1 §4.6.4 Node Type Indexing (cf. Example 115)
        @testset "type map" begin
            input = """{
                "@context": {
                    "ex": "http://ex.org/",
                    "affiliation": {"@id": "ex:affiliation", "@container": "@type"}
                },
                "@id": "http://ex.org/me",
                "affiliation": {
                    "ex:Corporation": {"@id": "http://ex.org/corp", "ex:name": "ACME"}
                }
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://ex.org/affiliation"]
            @test length(vals) == 1
            @test "http://ex.org/Corporation" in vals[1]["@type"]
            @test vals[1]["@id"] == "http://ex.org/corp"
        end

        # JSON-LD 1.1 §4.10 (Nested Properties): @nest is transparent (cf. Example 132)
        @testset "@nest unfolds nested properties" begin
            input = """{
                "@context": {
                    "skos": "http://www.w3.org/2004/02/skos/core#",
                    "labels": "@nest",
                    "main_label": {"@id": "skos:prefLabel"},
                    "other_label": {"@id": "skos:altLabel"}
                },
                "@id": "http://ex.org/n",
                "labels": {
                    "main_label": "This is the main label",
                    "other_label": "This is the other label"
                }
            }"""
            result = jsonld_expand(input)
            node = result[1]
            @test !haskey(node, "@nest")
            @test node["http://www.w3.org/2004/02/skos/core#prefLabel"][1]["@value"] ==
                  "This is the main label"
            @test node["http://www.w3.org/2004/02/skos/core#altLabel"][1]["@value"] ==
                  "This is the other label"
        end

        # JSON-LD 1.1 §4.1.8 Scoped Contexts: property-scoped (cf. Example 26)
        @testset "property-scoped context" begin
            input = """{
                "@context": {
                    "ex": "http://example.org/",
                    "detail": {"@id": "ex:detail", "@context": {"name": "ex:name"}}
                },
                "@id": "http://example.org/thing",
                "detail": {"name": "inner"},
                "name": "outer-should-be-dropped"
            }"""
            result = jsonld_expand(input)
            node = result[1]
            # "name" only has meaning inside "detail"
            @test !haskey(node, "name")
            detail = node["http://example.org/detail"][1]
            @test detail["http://example.org/name"][1]["@value"] == "inner"
        end

        # Property-scoped contexts propagate to deeper nodes
        @testset "property-scoped context propagates" begin
            input = """{
                "@context": {
                    "ex": "http://example.org/",
                    "p": {"@id": "ex:p", "@context": {"name": "ex:name"}},
                    "q": "ex:q"
                },
                "@id": "http://example.org/a",
                "p": {"@id": "http://example.org/b",
                      "q": {"@id": "http://example.org/c", "name": "deep"}}
            }"""
            result = jsonld_expand(input)
            b = result[1]["http://example.org/p"][1]
            c = b["http://example.org/q"][1]
            @test c["http://example.org/name"][1]["@value"] == "deep"
        end

        # JSON-LD 1.1 §4.1.8: type-scoped contexts (cf. Example 28)
        @testset "type-scoped context" begin
            input = """{
                "@context": {
                    "ex": "http://example.org/",
                    "Person": {"@id": "ex:Person", "@context": {"name": "ex:name"}}
                },
                "@id": "http://example.org/alice",
                "@type": "Person",
                "name": "Alice"
            }"""
            result = jsonld_expand(input)
            node = result[1]
            @test node["@type"] == ["http://example.org/Person"]
            @test node["http://example.org/name"][1]["@value"] == "Alice"
        end

        # JSON-LD 1.1 §4.1.9 @propagate: type-scoped contexts do NOT propagate
        # to nested node objects by default (cf. Example 31)
        @testset "type-scoped context does not propagate" begin
            input = """{
                "@context": {
                    "ex": "http://example.org/",
                    "knows": "ex:knows",
                    "Person": {"@id": "ex:Person", "@context": {"name": "ex:name"}}
                },
                "@id": "http://example.org/alice",
                "@type": "Person",
                "name": "Alice",
                "knows": {"@id": "http://example.org/bob", "name": "Bob"}
            }"""
            result = jsonld_expand(input)
            node = result[1]
            @test node["http://example.org/name"][1]["@value"] == "Alice"
            bob = node["http://example.org/knows"][1]
            @test bob["@id"] == "http://example.org/bob"
            # the scoped "name" term reverted for the nested node
            @test !haskey(bob, "http://example.org/name")
        end

        # "@propagate": true makes a type-scoped context stick (cf. Example 32)
        @testset "type-scoped context with @propagate true" begin
            input = """{
                "@context": {
                    "ex": "http://example.org/",
                    "knows": "ex:knows",
                    "Person": {"@id": "ex:Person",
                               "@context": {"@propagate": true, "name": "ex:name"}}
                },
                "@id": "http://example.org/alice",
                "@type": "Person",
                "knows": {"@id": "http://example.org/bob", "name": "Bob"}
            }"""
            result = jsonld_expand(input)
            bob = result[1]["http://example.org/knows"][1]
            @test bob["http://example.org/name"][1]["@value"] == "Bob"
        end

        # JSON-LD 1.1 §4.2.4 String Internationalization: @direction (cf. Example 53)
        @testset "context default @direction" begin
            input = """{
                "@context": {"@language": "ar-eg", "@direction": "rtl",
                             "title": "http://ex.org/title"},
                "@id": "http://ex.org/book",
                "title": "HTML والقرآن"
            }"""
            result = jsonld_expand(input)
            v = result[1]["http://ex.org/title"][1]
            @test v["@language"] == "ar-eg"
            @test v["@direction"] == "rtl"
        end

        @testset "term-level @direction overrides default" begin
            input = """{
                "@context": {"@direction": "rtl", "@language": "ar",
                             "a": {"@id": "http://ex.org/a", "@direction": "ltr"},
                             "b": {"@id": "http://ex.org/b", "@direction": null}},
                "@id": "http://ex.org/x",
                "a": "one",
                "b": "two"
            }"""
            result = jsonld_expand(input)
            @test result[1]["http://ex.org/a"][1]["@direction"] == "ltr"
            @test !haskey(result[1]["http://ex.org/b"][1], "@direction")
        end

        @testset "value object @direction" begin
            input = """{
                "@id": "http://ex.org/x",
                "http://ex.org/title": {"@value": "פעילות", "@language": "he", "@direction": "rtl"}
            }"""
            result = jsonld_expand(input)
            v = result[1]["http://ex.org/title"][1]
            @test v["@direction"] == "rtl"
        end

        # JSON-LD 1.1 §4.1.2 Default Vocabulary (cf. Example 17)
        @testset "@vocab" begin
            input = """{
                "@context": {"@vocab": "http://schema.org/"},
                "@id": "http://ex.org/1",
                "name": "Alice",
                "@type": "Person"
            }"""
            result = jsonld_expand(input)
            @test result[1]["http://schema.org/name"][1]["@value"] == "Alice"
            @test result[1]["@type"] == ["http://schema.org/Person"]
        end

        # "@vocab": "" resolves vocabulary terms against @base (cf. Example 18)
        @testset "@vocab empty string with @base" begin
            input = """{
                "@context": {"@base": "http://example.org/doc", "@vocab": ""},
                "@id": "http://example.org/doc",
                "houseColor": "red"
            }"""
            result = jsonld_expand(input)
            @test haskey(result[1], "http://example.org/dochouseColor")
        end

        # JSON-LD 1.1 §4.1.3 Base IRI
        @testset "@base resolves relative @id" begin
            input = """{
                "@context": {"@base": "http://example.org/dir/", "p": "http://ex.org/p"},
                "@id": "doc1",
                "p": {"@id": "../other"}
            }"""
            result = jsonld_expand(input)
            @test result[1]["@id"] == "http://example.org/dir/doc1"
            @test result[1]["http://ex.org/p"][1]["@id"] == "http://example.org/other"
        end

        @testset "base keyword argument" begin
            input = """{"@id": "doc1", "http://ex.org/p": {"@id": "o"}}"""
            result = jsonld_expand(input; base="http://example.org/dir/")
            @test result[1]["@id"] == "http://example.org/dir/doc1"
        end

        # JSON-LD 1.1 §4.2.2 Type coercion with @vocab
        @testset "type coercion @vocab" begin
            input = """{
                "@context": {"@vocab": "http://ex.org/",
                             "ref": {"@id": "http://ex.org/ref", "@type": "@vocab"}},
                "@id": "http://ex.org/1",
                "ref": "Thing"
            }"""
            result = jsonld_expand(input)
            @test result[1]["http://ex.org/ref"][1]["@id"] == "http://ex.org/Thing"
        end

        # JSON-LD 1.1 §4.2.5 JSON Literals (cf. Example 60)
        @testset "@json type coercion" begin
            input = """{
                "@context": {"e": {"@id": "http://example.com/vocab/json", "@type": "@json"}},
                "@id": "http://ex.org/1",
                "e": [56, {"d": [true, 8.5]}]
            }"""
            result = jsonld_expand(input)
            vals = result[1]["http://example.com/vocab/json"]
            @test length(vals) == 1
            @test vals[1]["@type"] == "@json"
            @test vals[1]["@value"] == Any[56, Dict{String,Any}("d" => Any[true, 8.5])]
        end

        # JSON-LD 1.1 §4.1.6 Aliasing Keywords (cf. Example 23)
        @testset "keyword aliases" begin
            input = """{
                "@context": {"id": "@id", "type": "@type", "url": "http://schema.org/url"},
                "id": "http://ex.org/1",
                "type": "http://schema.org/Person",
                "url": "http://example.com/"
            }"""
            result = jsonld_expand(input)
            @test result[1]["@id"] == "http://ex.org/1"
            @test result[1]["@type"] == ["http://schema.org/Person"]
        end

        @testset "term explicitly set to null is dropped" begin
            input = """{
                "@context": [{"name": "http://schema.org/name"}, {"name": null}],
                "@id": "http://ex.org/1",
                "name": "Alice"
            }"""
            result = jsonld_expand(input)
            @test length(result) == 1
            @test !any(k -> occursin("name", k), keys(result[1]))
        end

        # JSON-LD 1.1 §3.1: remote contexts via a document loader
        @testset "remote context with injected loader" begin
            calls = Ref(0)
            loader = url -> begin
                calls[] += 1
                url == "http://example.com/ctx.jsonld" ||
                    error("unexpected URL $url")
                """{"@context": {"name": "http://schema.org/name"}}"""
            end
            input = """{
                "@context": "http://example.com/ctx.jsonld",
                "@id": "http://ex.org/1",
                "name": "Alice"
            }"""
            result = jsonld_expand(input; context_loader=loader)
            @test result[1]["http://schema.org/name"][1]["@value"] == "Alice"
            @test calls[] == 1
        end

        @testset "remote contexts are cached per call" begin
            calls = Ref(0)
            loader = url -> begin
                calls[] += 1
                """{"@context": {"name": "http://schema.org/name"}}"""
            end
            input = """{
                "@context": ["http://example.com/ctx.jsonld", "http://example.com/ctx.jsonld"],
                "@id": "http://ex.org/1",
                "name": "Alice"
            }"""
            result = jsonld_expand(input; context_loader=loader)
            @test result[1]["http://schema.org/name"][1]["@value"] == "Alice"
            @test calls[] == 1
        end

        @testset "remote context loader may return a Dict" begin
            loader = url -> Dict{String,Any}("@context" =>
                Dict{String,Any}("name" => "http://schema.org/name"))
            input = """{
                "@context": "http://example.com/ctx.jsonld",
                "@id": "http://ex.org/1",
                "name": "Alice"
            }"""
            result = jsonld_expand(input; context_loader=loader)
            @test haskey(result[1], "http://schema.org/name")
        end

        @testset "cyclic remote contexts raise an error" begin
            loader = url -> begin
                if url == "http://example.com/a.jsonld"
                    """{"@context": "http://example.com/b.jsonld"}"""
                else
                    """{"@context": "http://example.com/a.jsonld"}"""
                end
            end
            input = """{
                "@context": "http://example.com/a.jsonld",
                "@id": "http://ex.org/1",
                "http://ex.org/p": "v"
            }"""
            @test_throws Exception jsonld_expand(input; context_loader=loader)
        end

        @testset "missing loader for remote context errors" begin
            input = """{
                "@context": "http://example.com/ctx.jsonld",
                "@id": "http://ex.org/1",
                "http://ex.org/p": "v"
            }"""
            @test_throws Exception jsonld_expand(input; context_loader=nothing)
        end

        @testset "expand_context keyword argument" begin
            input = """{"@id": "http://ex.org/1", "name": "Alice"}"""
            result = jsonld_expand(input;
                expand_context=Dict{String,Any}("name" => "http://schema.org/name"))
            @test result[1]["http://schema.org/name"][1]["@value"] == "Alice"
        end
    end

    @testset "Compaction" begin
        @testset "basic compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://schema.org/name" => [Dict{String,Any}("@value" => "Alice")]
            )]
            context = Dict{String,Any}("name" => "http://schema.org/name")
            result = jsonld_compact(expanded, context)
            @test result["@context"] == context
            @test result["@id"] == "http://ex.org/1"
            @test result["name"] == "Alice"
        end

        @testset "compact @type" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "@type" => ["http://schema.org/Person"]
            )]
            context = Dict{String,Any}("Person" => "http://schema.org/Person")
            result = jsonld_compact(expanded, context)
            @test result["@type"] == "Person"
        end

        @testset "compact with prefix" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://schema.org/name" => [Dict{String,Any}("@value" => "Alice")],
                "http://schema.org/age" => [Dict{String,Any}("@value" => 30)]
            )]
            context = Dict{String,Any}("schema" => "http://schema.org/")
            result = jsonld_compact(expanded, context)
            @test haskey(result, "schema:name") || haskey(result, "name")
            @test result["@id"] == "http://ex.org/1"
        end

        @testset "compact from JSON string" begin
            input = """{"@context": {"name": "http://schema.org/name"}, "@id": "http://ex.org/1", "name": "Alice"}"""
            context = Dict{String,Any}("name" => "http://schema.org/name")
            result = jsonld_compact(input, context)
            @test result["name"] == "Alice"
            @test result["@id"] == "http://ex.org/1"
        end
    end

    # ═══════════════════════════════════════════════════════════════════
    # JSON-LD 1.1 compaction features
    # ═══════════════════════════════════════════════════════════════════
    @testset "Compaction 1.1" begin
        # §4.3.1 Lists: @container @list compacts to a bare array
        @testset "@container @list compacts to bare array" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://xmlns.com/foaf/0.1/nick" => Any[Dict{String,Any}(
                    "@list" => Any[Dict{String,Any}("@value" => "joe"),
                                   Dict{String,Any}("@value" => "bob")])]
            )]
            context = Dict{String,Any}("nick" => Dict{String,Any}(
                "@id" => "http://xmlns.com/foaf/0.1/nick", "@container" => "@list"))
            result = jsonld_compact(expanded, context)
            @test result["nick"] == ["joe", "bob"]
        end

        @testset "@list without container keeps @list object" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://ex.org/items" => Any[Dict{String,Any}(
                    "@list" => Any[Dict{String,Any}("@value" => "a")])]
            )]
            context = Dict{String,Any}("items" => "http://ex.org/items")
            result = jsonld_compact(expanded, context)
            @test result["items"] isa AbstractDict
            @test result["items"]["@list"] == ["a"]
        end

        # §4.8 Reverse Properties: reverse term compaction (cf. Example 121)
        @testset "reverse term compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/dad",
                "@reverse" => Dict{String,Any}(
                    "http://ex.org/parent" => Any[
                        Dict{String,Any}("@id" => "http://ex.org/kid")])
            )]
            context = Dict{String,Any}("isParentOf" => Dict{String,Any}(
                "@reverse" => "http://ex.org/parent", "@type" => "@id"))
            result = jsonld_compact(expanded, context)
            @test result["isParentOf"] == "http://ex.org/kid"
            @test !haskey(result, "@reverse")
        end

        @testset "@reverse fallback without reverse term" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/dad",
                "@reverse" => Dict{String,Any}(
                    "http://ex.org/parent" => Any[
                        Dict{String,Any}("@id" => "http://ex.org/kid")])
            )]
            context = Dict{String,Any}("ex" => "http://ex.org/")
            result = jsonld_compact(expanded, context)
            @test haskey(result, "@reverse")
            rev = result["@reverse"]
            @test haskey(rev, "ex:parent")
        end

        # §4.6.2 Language Indexing: compaction into a language map
        @testset "language map compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/queen",
                "http://ex.org/label" => Any[
                    Dict{String,Any}("@value" => "The Queen", "@language" => "en"),
                    Dict{String,Any}("@value" => "Die Königin", "@language" => "de")]
            )]
            context = Dict{String,Any}("label" => Dict{String,Any}(
                "@id" => "http://ex.org/label", "@container" => "@language"))
            result = jsonld_compact(expanded, context)
            @test result["label"]["en"] == "The Queen"
            @test result["label"]["de"] == "Die Königin"
        end

        # §4.6.1 Data Indexing: compaction into an index map, @index removed
        @testset "index map compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/team",
                "http://schema.org/athlete" => Any[
                    Dict{String,Any}("@id" => "http://ex.org/p1", "@index" => "catcher"),
                    Dict{String,Any}("@id" => "http://ex.org/p2", "@index" => "pitcher")]
            )]
            context = Dict{String,Any}("athletes" => Dict{String,Any}(
                "@id" => "http://schema.org/athlete", "@container" => "@index"))
            result = jsonld_compact(expanded, context)
            m = result["athletes"]
            @test m["catcher"]["@id"] == "http://ex.org/p1"
            @test !haskey(m["catcher"], "@index")
            @test m["pitcher"]["@id"] == "http://ex.org/p2"
        end

        # §4.6.3 Node Identifier Indexing: compaction into an id map
        @testset "id map compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/blog",
                "http://ex.org/post" => Any[
                    Dict{String,Any}("@id" => "http://ex.org/posts/1",
                        "http://ex.org/title" => Any[Dict{String,Any}("@value" => "First")])]
            )]
            context = Dict{String,Any}(
                "ex" => "http://ex.org/",
                "post" => Dict{String,Any}("@id" => "http://ex.org/post",
                                           "@container" => "@id"))
            result = jsonld_compact(expanded, context)
            m = result["post"]
            @test haskey(m, "ex:posts/1") || haskey(m, "http://ex.org/posts/1")
            entry = haskey(m, "ex:posts/1") ? m["ex:posts/1"] : m["http://ex.org/posts/1"]
            @test !haskey(entry, "@id")
            @test entry["ex:title"] == "First"
        end

        # §4.6.4 Node Type Indexing: compaction into a type map
        @testset "type map compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/me",
                "http://ex.org/affiliation" => Any[
                    Dict{String,Any}("@id" => "http://ex.org/corp",
                        "@type" => Any["http://ex.org/Corporation"])]
            )]
            context = Dict{String,Any}(
                "ex" => "http://ex.org/",
                "affiliation" => Dict{String,Any}("@id" => "http://ex.org/affiliation",
                                                  "@container" => "@type"))
            result = jsonld_compact(expanded, context)
            m = result["affiliation"]
            @test haskey(m, "ex:Corporation")
            @test !haskey(m["ex:Corporation"], "@type")
            # the node @id is itself compacted to a compact IRI
            @test m["ex:Corporation"]["@id"] == "ex:corp"
        end

        # §4.10 Nested Properties: compaction re-nests (cf. Example 134)
        @testset "@nest compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/n",
                "http://www.w3.org/2004/02/skos/core#prefLabel" => Any[
                    Dict{String,Any}("@value" => "Main")]
            )]
            context = Dict{String,Any}(
                "labels" => "@nest",
                "main_label" => Dict{String,Any}(
                    "@id" => "http://www.w3.org/2004/02/skos/core#prefLabel",
                    "@nest" => "labels"))
            result = jsonld_compact(expanded, context)
            @test haskey(result, "labels")
            @test result["labels"]["main_label"] == "Main"
        end

        # §4.2.2 Type Coercion: matching coercion unwraps the value object
        @testset "type coercion compaction" begin
            xsd_int = "http://www.w3.org/2001/XMLSchema#integer"
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://ex.org/age" => Any[
                    Dict{String,Any}("@value" => "30", "@type" => xsd_int)],
                "http://ex.org/url" => Any[
                    Dict{String,Any}("@id" => "http://example.com/")]
            )]
            context = Dict{String,Any}(
                "age" => Dict{String,Any}("@id" => "http://ex.org/age", "@type" => xsd_int),
                "url" => Dict{String,Any}("@id" => "http://ex.org/url", "@type" => "@id"))
            result = jsonld_compact(expanded, context)
            @test result["age"] == "30"
            @test result["url"] == "http://example.com/"
        end

        @testset "mismatched type keeps value object" begin
            xsd_int = "http://www.w3.org/2001/XMLSchema#integer"
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://ex.org/age" => Any[
                    Dict{String,Any}("@value" => "30", "@type" => xsd_int)]
            )]
            context = Dict{String,Any}("age" => "http://ex.org/age",
                                       "xsd" => "http://www.w3.org/2001/XMLSchema#")
            result = jsonld_compact(expanded, context)
            @test result["age"] isa AbstractDict
            @test result["age"]["@value"] == "30"
            @test result["age"]["@type"] == "xsd:integer"
        end

        # §4.2.4 String Internationalization: direction-aware compaction
        @testset "@direction compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://ex.org/title" => Any[
                    Dict{String,Any}("@value" => "פעילות", "@language" => "he",
                                     "@direction" => "rtl")]
            )]
            ctx_match = Dict{String,Any}("title" => "http://ex.org/title",
                                         "@language" => "he", "@direction" => "rtl")
            result = jsonld_compact(expanded, ctx_match)
            @test result["title"] == "פעילות"

            ctx_mismatch = Dict{String,Any}("title" => "http://ex.org/title",
                                            "@language" => "he", "@direction" => "ltr")
            result2 = jsonld_compact(expanded, ctx_mismatch)
            @test result2["title"] isa AbstractDict
            @test result2["title"]["@direction"] == "rtl"
        end

        # §4.2.5 JSON Literals: @json term compaction returns native JSON
        @testset "@json compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://example.com/vocab/json" => Any[
                    Dict{String,Any}("@value" => Any[1, 2], "@type" => "@json")]
            )]
            context = Dict{String,Any}("e" => Dict{String,Any}(
                "@id" => "http://example.com/vocab/json", "@type" => "@json"))
            result = jsonld_compact(expanded, context)
            @test result["e"] == Any[1, 2]
        end

        # §4.1.2 Default Vocabulary: vocab-relative compaction
        @testset "@vocab suffix compaction" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://schema.org/name" => Any[Dict{String,Any}("@value" => "Alice")]
            )]
            context = Dict{String,Any}("@vocab" => "http://schema.org/")
            result = jsonld_compact(expanded, context)
            @test result["name"] == "Alice"
        end

        # §4.3.2 Sets: @container @set always keeps arrays
        @testset "@set keeps arrays" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://ex.org/tag" => Any[Dict{String,Any}("@value" => "solo")]
            )]
            context = Dict{String,Any}("tag" => Dict{String,Any}(
                "@id" => "http://ex.org/tag", "@container" => "@set"))
            result = jsonld_compact(expanded, context)
            @test result["tag"] == ["solo"]
        end

        @testset "plain string with default language keeps wrapper" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "http://ex.org/p" => Any[Dict{String,Any}("@value" => "plain")]
            )]
            context = Dict{String,Any}("p" => "http://ex.org/p", "@language" => "en")
            result = jsonld_compact(expanded, context)
            @test result["p"] isa AbstractDict
            @test result["p"]["@value"] == "plain"
        end
    end

    @testset "Framing" begin
        @testset "select by type" begin
            expanded = [
                Dict{String,Any}(
                    "@id" => "http://ex.org/1",
                    "@type" => ["http://schema.org/Person"],
                    "http://schema.org/name" => [Dict{String,Any}("@value" => "Alice")]
                ),
                Dict{String,Any}(
                    "@id" => "http://ex.org/2",
                    "@type" => ["http://schema.org/Organization"],
                    "http://schema.org/name" => [Dict{String,Any}("@value" => "ACME")]
                )
            ]
            frame = Dict{String,Any}("@type" => "http://schema.org/Person")
            result = jsonld_frame(expanded, frame)
            @test result["@id"] == "http://ex.org/1"
            @test result["@type"] == ["http://schema.org/Person"]
        end

        @testset "include specific properties" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "@type" => ["http://schema.org/Person"],
                "http://schema.org/name" => [Dict{String,Any}("@value" => "Alice")],
                "http://schema.org/age" => [Dict{String,Any}("@value" => 30)]
            )]
            frame = Dict{String,Any}(
                "@type" => "http://schema.org/Person",
                "http://schema.org/name" => Dict{String,Any}()
            )
            result = jsonld_frame(expanded, frame)
            @test haskey(result, "http://schema.org/name")
            @test !haskey(result, "http://schema.org/age")
        end

        @testset "embed referenced nodes" begin
            expanded = [
                Dict{String,Any}(
                    "@id" => "http://ex.org/1",
                    "@type" => ["http://schema.org/Person"],
                    "http://schema.org/knows" => [Dict{String,Any}("@id" => "http://ex.org/2")]
                ),
                Dict{String,Any}(
                    "@id" => "http://ex.org/2",
                    "@type" => ["http://schema.org/Person"],
                    "http://schema.org/name" => [Dict{String,Any}("@value" => "Bob")]
                )
            ]
            frame = Dict{String,Any}(
                "@type" => "http://schema.org/Person",
                "http://schema.org/knows" => Dict{String,Any}(),
                "@embed" => "@always"
            )
            result = jsonld_frame(expanded, frame)
            # Multiple persons match; result has @graph
            if haskey(result, "@graph")
                alice = result["@graph"][1]
            else
                alice = result
            end
            knows_vals = alice["http://schema.org/knows"]
            embedded = knows_vals isa AbstractVector ? knows_vals[1] : knows_vals
            @test embedded["@id"] == "http://ex.org/2"
            @test haskey(embedded, "http://schema.org/name")
        end

        @testset "frame with context" begin
            expanded = [Dict{String,Any}(
                "@id" => "http://ex.org/1",
                "@type" => ["http://schema.org/Person"],
                "http://schema.org/name" => [Dict{String,Any}("@value" => "Alice")]
            )]
            frame = Dict{String,Any}(
                "@context" => Dict{String,Any}("name" => "http://schema.org/name"),
                "@type" => "http://schema.org/Person",
                "name" => Dict{String,Any}()
            )
            result = jsonld_frame(expanded, frame)
            @test haskey(result, "@context")
            @test haskey(result, "http://schema.org/name")
        end
    end

    @testset "Flatten" begin
        @testset "flat graph output" begin
            input = """{
                "@context": {
                    "name": "http://schema.org/name",
                    "knows": "http://schema.org/knows"
                },
                "@id": "http://ex.org/1",
                "name": "Alice",
                "knows": {
                    "@id": "http://ex.org/2",
                    "name": "Bob"
                }
            }"""
            result = jsonld_flatten(input)
            @test haskey(result, "@graph")
            graph = result["@graph"]
            @test length(graph) == 2
            ids = Set(n["@id"] for n in graph)
            @test "http://ex.org/1" in ids
            @test "http://ex.org/2" in ids
        end

        @testset "blank nodes get IDs" begin
            input = """{
                "@context": {
                    "name": "http://schema.org/name",
                    "knows": "http://schema.org/knows"
                },
                "@id": "http://ex.org/1",
                "name": "Alice",
                "knows": {
                    "name": "Unknown"
                }
            }"""
            result = jsonld_flatten(input)
            graph = result["@graph"]
            @test length(graph) == 2
            # All nodes should have @id
            for node in graph
                @test haskey(node, "@id")
            end
            # One should be a blank node
            bnode_nodes = filter(n -> startswith(n["@id"], "_:"), graph)
            @test length(bnode_nodes) == 1
        end

        @testset "references between nodes" begin
            input = """{
                "@context": {
                    "name": "http://schema.org/name",
                    "knows": "http://schema.org/knows"
                },
                "@id": "http://ex.org/1",
                "name": "Alice",
                "knows": {
                    "@id": "http://ex.org/2",
                    "name": "Bob"
                }
            }"""
            result = jsonld_flatten(input)
            graph = result["@graph"]
            alice = first(filter(n -> n["@id"] == "http://ex.org/1", graph))
            knows_refs = alice["http://schema.org/knows"]
            @test length(knows_refs) == 1
            @test knows_refs[1]["@id"] == "http://ex.org/2"
        end

        # JSON-LD 1.1 §4.3.1: lists survive flattening with node items as refs
        @testset "@list preserved in flattening" begin
            input = """{
                "@context": {"items": {"@id": "http://ex.org/items", "@container": "@list"}},
                "@id": "http://ex.org/s",
                "items": ["a", {"@id": "http://ex.org/n", "http://ex.org/p": "v"}]
            }"""
            result = jsonld_flatten(input)
            graph = result["@graph"]
            s = first(filter(n -> n["@id"] == "http://ex.org/s", graph))
            lst = s["http://ex.org/items"][1]
            @test haskey(lst, "@list")
            @test lst["@list"][1]["@value"] == "a"
            @test lst["@list"][2] == Dict{String,Any}("@id" => "http://ex.org/n")
            # the node item was lifted into the graph
            @test any(n -> n["@id"] == "http://ex.org/n", graph)
        end

        # §4.8: flattening converts @reverse into forward edges
        @testset "@reverse becomes forward edges" begin
            input = """{
                "@context": {"isParentOf": {"@reverse": "http://ex.org/parent"}},
                "@id": "http://ex.org/dad",
                "http://ex.org/name": "Dad",
                "isParentOf": {"@id": "http://ex.org/kid", "http://ex.org/name": "Kid"}
            }"""
            result = jsonld_flatten(input)
            graph = result["@graph"]
            kid = first(filter(n -> n["@id"] == "http://ex.org/kid", graph))
            @test kid["http://ex.org/parent"] == Any[Dict{String,Any}("@id" => "http://ex.org/dad")]
        end
    end

    @testset "Round-trip" begin
        @testset "expand then compact" begin
            original = """{
                "@context": {"name": "http://schema.org/name"},
                "@id": "http://ex.org/1",
                "name": "Alice"
            }"""
            expanded = jsonld_expand(original)
            context = Dict{String,Any}("name" => "http://schema.org/name")
            compacted = jsonld_compact(expanded, context)
            @test compacted["name"] == "Alice"
            @test compacted["@id"] == "http://ex.org/1"
        end

        @testset "expand preserves data" begin
            input = """{
                "@context": {
                    "schema": "http://schema.org/",
                    "name": "http://schema.org/name",
                    "age": "http://schema.org/age"
                },
                "@id": "http://ex.org/1",
                "@type": "schema:Person",
                "name": "Alice",
                "age": 30
            }"""
            expanded = jsonld_expand(input)
            @test length(expanded) == 1
            node = expanded[1]
            @test node["@id"] == "http://ex.org/1"
            @test "http://schema.org/Person" in node["@type"]
            @test node["http://schema.org/name"][1]["@value"] == "Alice"
            @test node["http://schema.org/age"][1]["@value"] == 30
        end

        @testset "list expand/compact round-trip" begin
            original = """{
                "@context": {"nick": {"@id": "http://xmlns.com/foaf/0.1/nick", "@container": "@list"}},
                "@id": "http://ex.org/1",
                "nick": ["joe", "bob"]
            }"""
            ctx = Dict{String,Any}("nick" => Dict{String,Any}(
                "@id" => "http://xmlns.com/foaf/0.1/nick", "@container" => "@list"))
            expanded = jsonld_expand(original)
            compacted = jsonld_compact(expanded, ctx)
            @test compacted["nick"] == ["joe", "bob"]
        end

        @testset "language map expand/compact round-trip" begin
            original = """{
                "@context": {"label": {"@id": "http://ex.org/label", "@container": "@language"}},
                "@id": "http://ex.org/q",
                "label": {"en": "Queen", "de": "Königin"}
            }"""
            ctx = Dict{String,Any}("label" => Dict{String,Any}(
                "@id" => "http://ex.org/label", "@container" => "@language"))
            compacted = jsonld_compact(jsonld_expand(original), ctx)
            @test compacted["label"]["en"] == "Queen"
            @test compacted["label"]["de"] == "Königin"
        end

        @testset "reverse expand/compact round-trip" begin
            original = """{
                "@context": {"isParentOf": {"@reverse": "http://ex.org/parent", "@type": "@id"}},
                "@id": "http://ex.org/dad",
                "isParentOf": "http://ex.org/kid"
            }"""
            ctx = Dict{String,Any}("isParentOf" => Dict{String,Any}(
                "@reverse" => "http://ex.org/parent", "@type" => "@id"))
            compacted = jsonld_compact(jsonld_expand(original), ctx)
            @test compacted["isParentOf"] == "http://ex.org/kid"
        end

        @testset "@nest expand/compact round-trip" begin
            original = """{
                "@context": {
                    "labels": "@nest",
                    "main_label": {"@id": "http://ex.org/prefLabel", "@nest": "labels"}
                },
                "@id": "http://ex.org/n",
                "labels": {"main_label": "Main"}
            }"""
            ctx = Dict{String,Any}(
                "labels" => "@nest",
                "main_label" => Dict{String,Any}(
                    "@id" => "http://ex.org/prefLabel", "@nest" => "labels"))
            expanded = jsonld_expand(original)
            @test expanded[1]["http://ex.org/prefLabel"][1]["@value"] == "Main"
            compacted = jsonld_compact(expanded, ctx)
            @test compacted["labels"]["main_label"] == "Main"
        end
    end
end
