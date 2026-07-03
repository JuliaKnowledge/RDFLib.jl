using Test
using RDFLib

@testset "LMDBStore" begin
    mktempdir() do dir
        @testset "Basic add/length/triples" begin
            store = LMDBStore(joinpath(dir, "basic"))
            g = RDFGraph(store=store)

            @test length(g) == 0
            @test isempty(g)

            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), Literal("hello")))
            @test length(g) == 1
            @test !isempty(g)

            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), Literal("world")))
            @test length(g) == 2

            # Duplicate should not increase count
            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), Literal("hello")))
            @test length(g) == 2

            close(store)
        end

        @testset "Pattern matching" begin
            store = LMDBStore(joinpath(dir, "pattern"))
            g = RDFGraph(store=store)

            for i in 1:10
                add!(g, Triple(URIRef("http://ex.org/s$i"), URIRef("http://ex.org/type"), URIRef("http://ex.org/Thing")))
                add!(g, Triple(URIRef("http://ex.org/s$i"), URIRef("http://ex.org/name"), Literal("item$i")))
            end
            @test length(g) == 20

            # S ? ?
            r = triples(g, (URIRef("http://ex.org/s5"), nothing, nothing))
            @test length(r) == 2

            # ? P ?
            r = triples(g, (nothing, URIRef("http://ex.org/type"), nothing))
            @test length(r) == 10

            # ? ? O
            r = triples(g, (nothing, nothing, URIRef("http://ex.org/Thing")))
            @test length(r) == 10

            r = triples(g, (nothing, nothing, Literal("item3")))
            @test length(r) == 1

            # S P ?
            r = triples(g, (URIRef("http://ex.org/s1"), URIRef("http://ex.org/type"), nothing))
            @test length(r) == 1

            # S ? O
            r = triples(g, (URIRef("http://ex.org/s1"), nothing, URIRef("http://ex.org/Thing")))
            @test length(r) == 1

            # ? P O
            r = triples(g, (nothing, URIRef("http://ex.org/type"), URIRef("http://ex.org/Thing")))
            @test length(r) == 10

            # S P O (exact match)
            r = triples(g, (URIRef("http://ex.org/s1"), URIRef("http://ex.org/type"), URIRef("http://ex.org/Thing")))
            @test length(r) == 1

            # No match
            r = triples(g, (URIRef("http://ex.org/nonexistent"), nothing, nothing))
            @test length(r) == 0

            # All triples
            r = triples(g, (nothing, nothing, nothing))
            @test length(r) == 20

            close(store)
        end

        @testset "Remove" begin
            store = LMDBStore(joinpath(dir, "remove"))
            g = RDFGraph(store=store)

            t1 = Triple(URIRef("http://ex.org/a"), URIRef("http://ex.org/b"), URIRef("http://ex.org/c"))
            t2 = Triple(URIRef("http://ex.org/a"), URIRef("http://ex.org/b"), URIRef("http://ex.org/d"))
            add!(g, t1)
            add!(g, t2)
            @test length(g) == 2

            remove!(g, t1)
            @test length(g) == 1

            r = triples(g, (URIRef("http://ex.org/a"), nothing, nothing))
            @test length(r) == 1
            @test r[1] == t2

            # Remove non-existent — no error
            remove!(g, t1)
            @test length(g) == 1

            close(store)
        end

        @testset "Persistence" begin
            path = joinpath(dir, "persist")
            store = LMDBStore(path)
            g = RDFGraph(store=store)

            for i in 1:50
                add!(g, Triple(URIRef("http://ex.org/s$i"), URIRef("http://ex.org/p"), Literal("v$i")))
            end
            @test length(g) == 50
            close(store)

            # Reopen and verify
            store2 = LMDBStore(path)
            g2 = RDFGraph(store=store2)
            @test length(g2) == 50

            r = triples(g2, (URIRef("http://ex.org/s25"), nothing, nothing))
            @test length(r) == 1
            @test r[1].object == Literal("v25")

            # Add more and close
            add!(g2, Triple(URIRef("http://ex.org/new"), URIRef("http://ex.org/p"), Literal("added")))
            @test length(g2) == 51
            close(store2)

            # Reopen again
            store3 = LMDBStore(path)
            g3 = RDFGraph(store=store3)
            @test length(g3) == 51
            close(store3)
        end

        @testset "Bulk add" begin
            store = LMDBStore(joinpath(dir, "bulk"))
            ts = [Triple(URIRef("http://ex.org/s$i"), URIRef("http://ex.org/p"), Literal("v$i")) for i in 1:1000]
            n = add_bulk!(store, ts)
            @test n == 1000
            @test length(store) == 1000

            # Duplicates should be skipped
            n2 = add_bulk!(store, ts)
            @test n2 == 0
            @test length(store) == 1000

            close(store)
        end

        @testset "Term types" begin
            store = LMDBStore(joinpath(dir, "termtypes"))
            g = RDFGraph(store=store)

            # URI subjects/objects
            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), URIRef("http://ex.org/o")))
            # BNode subjects
            add!(g, Triple(BNode("b1"), URIRef("http://ex.org/p"), Literal("val")))
            # Typed literals
            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/age"),
                          Literal("42", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
            # Language-tagged literals
            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/label"),
                          Literal("hello", lang="en")))

            @test length(g) == 4

            # Verify round-trip
            r = triples(g, (nothing, nothing, nothing))
            @test length(r) == 4

            # Check typed literal preserved
            r_age = triples(g, (nothing, URIRef("http://ex.org/age"), nothing))
            @test length(r_age) == 1
            @test r_age[1].object.datatype == URIRef("http://www.w3.org/2001/XMLSchema#integer")

            # Check language tag preserved
            r_label = triples(g, (nothing, URIRef("http://ex.org/label"), nothing))
            @test length(r_label) == 1
            @test r_label[1].object.language == "en"

            close(store)
        end

        @testset "Directional and embedded-NUL literals" begin
            store = LMDBStore(joinpath(dir, "dirnul"))
            g = RDFGraph(store=store)
            EX = Namespace("http://example.org/")

            lit_rtl = Literal("a\0b", lang="ar", direction="rtl")
            lit_ltr = Literal("a\0b", lang="ar", direction="ltr")
            add!(g, Triple(EX("s"), EX("label"), lit_rtl))
            add!(g, Triple(EX("s"), EX("label"), lit_ltr))

            got = [t.object for t in triples(g, (EX("s"), EX("label"), nothing))]
            @test length(got) == 2
            @test lit_rtl in got
            @test lit_ltr in got

            close(store)
        end

        @testset "SPARQL on LMDBStore" begin
            store = LMDBStore(joinpath(dir, "sparql"))
            g = RDFGraph(store=store)

            for i in 1:10
                add!(g, Triple(URIRef("http://ex.org/person$i"),
                              URIRef("http://ex.org/age"),
                              Literal("$(20+i)", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
                add!(g, Triple(URIRef("http://ex.org/person$i"),
                              URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                              URIRef("http://ex.org/Person")))
            end

            # SELECT
            results = sparql_query(g, """
                SELECT ?p ?age WHERE {
                    ?p <http://ex.org/age> ?age
                    FILTER(?age > 25)
                }
            """)
            @test length(results) == 5

            # ASK
            ask_result = sparql_query(g, """
                ASK { <http://ex.org/person1> <http://ex.org/age> ?age }
            """)
            @test ask_result == true

            # CONSTRUCT
            cg = sparql_query(g, """
                CONSTRUCT { ?p <http://ex.org/isOld> true }
                WHERE { ?p <http://ex.org/age> ?age FILTER(?age > 28) }
            """)
            @test length(cg) == 2

            close(store)
        end

        @testset "map_size >= 4 GiB (regression)" begin
            # Cuint(map_size) used to throw InexactError for sizes ≥ 4 GiB;
            # map_size is now passed to LMDB as a size_t. The map is virtual
            # address space, not allocated memory, so this is cheap.
            store = LMDBStore(joinpath(dir, "bigmap"); map_size=5 * 1024^3)
            g = RDFGraph(store=store)
            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), Literal("big")))
            @test length(g) == 1
            r = triples(g, (nothing, nothing, nothing))
            @test length(r) == 1
            close(store)

            @test_throws ArgumentError LMDBStore(joinpath(dir, "badmap"); map_size=0)
        end

        @testset "Term cache bounding" begin
            old_cap = RDFLib._LMDB_TERM_CACHE_MAX[]
            try
                RDFLib._LMDB_TERM_CACHE_MAX[] = 8
                store = LMDBStore(joinpath(dir, "cachebound"))
                g = RDFGraph(store=store)
                for i in 1:20
                    add!(g, Triple(URIRef("http://ex.org/s$i"), URIRef("http://ex.org/p"), Literal("v$i")))
                end
                # Cache stays bounded (cap + at most one in-flight insert)
                @test length(store._term2id_cache) <= 9
                @test length(store._id2term_cache) <= 9
                # Data is still complete and correct after evictions
                @test length(g) == 20
                r = triples(g, (URIRef("http://ex.org/s7"), nothing, nothing))
                @test length(r) == 1
                @test r[1].object == Literal("v7")
                @test length(triples(g, (nothing, nothing, nothing))) == 20
                close(store)
            finally
                RDFLib._LMDB_TERM_CACHE_MAX[] = old_cap
            end
        end

        @testset "Dataset with LMDBStore graph" begin
            store = LMDBStore(joinpath(dir, "ds_graph"))
            g = RDFGraph(store=store)

            add!(g, Triple(URIRef("http://ex.org/s"), URIRef("http://ex.org/p"), Literal("v")))
            @test length(g) == 1
            @test g.store isa LMDBStore

            close(store)
        end
    end
end
