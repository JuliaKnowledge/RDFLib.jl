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
    end
end
