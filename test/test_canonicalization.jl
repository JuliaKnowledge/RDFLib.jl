# Tests for RDF canonicalization (canonical N-Triples/N-Quads + RDFC-1.0).

using Test
using RDFLib

const _EX = "http://example.org/"
_u(s) = URIRef(_EX * s)

@testset "Canonicalization" begin

    @testset "canonical serialization (rdf_canonicalize)" begin
        # Single ground triple → canonical N-Triples line + trailing newline.
        g = RDFGraph()
        add!(g, Triple(_u("s"), _u("p"), _u("o")))
        @test rdf_canonicalize(g) ==
            "<http://example.org/s> <http://example.org/p> <http://example.org/o> .\n"

        # xsd:string datatype is omitted from the canonical form.
        g2 = RDFGraph()
        add!(g2, Triple(_u("s"), _u("p"),
              Literal("foo", datatype = URIRef("http://www.w3.org/2001/XMLSchema#string"))))
        @test rdf_canonicalize(g2) ==
            "<http://example.org/s> <http://example.org/p> \"foo\" .\n"

        # Language tags are lower-cased.
        g3 = RDFGraph()
        add!(g3, Triple(_u("s"), _u("p"), Literal("chat", lang = "EN")))
        @test rdf_canonicalize(g3) ==
            "<http://example.org/s> <http://example.org/p> \"chat\"@en .\n"

        # Control-character escaping: tab/newline short escapes, others \\uXXXX.
        g4 = RDFGraph()
        add!(g4, Triple(_u("s"), _u("p"), Literal("a\tbc")))
        @test rdf_canonicalize(g4) ==
            "<http://example.org/s> <http://example.org/p> \"a\\tb\\u0007c\" .\n"

        # Backslash and double-quote escaping.
        g5 = RDFGraph()
        add!(g5, Triple(_u("s"), _u("p"), Literal("x\\\"y")))
        @test rdf_canonicalize(g5) ==
            "<http://example.org/s> <http://example.org/p> \"x\\\\\\\"y\" .\n"
    end

    @testset "canonical N-Quads serialization" begin
        ds = Dataset()
        add!(ds, Triple(_u("s"), _u("p"), _u("o")), _u("g"))
        @test rdf_canonicalize(ds) ==
            "<http://example.org/s> <http://example.org/p> <http://example.org/o> <http://example.org/g> .\n"

        # Default-graph quad omits the graph component.
        ds2 = Dataset()
        add!(ds2, Triple(_u("s"), _u("p"), _u("o")))
        @test rdf_canonicalize(ds2) ==
            "<http://example.org/s> <http://example.org/p> <http://example.org/o> .\n"
    end

    @testset "triple terms (RDF 1.2)" begin
        g = RDFGraph()
        tt = TripleTerm(_u("s1"), _u("p1"), Literal("o1"))
        add!(g, Triple(_u("s"), _u("p"), tt))
        @test rdf_canonicalize(g) ==
            "<http://example.org/s> <http://example.org/p> <<( <http://example.org/s1> <http://example.org/p1> \"o1\" )>> .\n"
    end

    @testset "RDFC-1.0 blank-node relabelling (rdfc10)" begin
        # A single blank node is relabelled to c14n0.
        g = RDFGraph()
        b = BNode("xyz")
        add!(g, Triple(b, _u("p"), _u("o")))
        @test rdfc10(g) ==
            "_:c14n0 <http://example.org/p> <http://example.org/o> .\n"

        # canonical_bnode_labels reports the mapping.
        labels = canonical_bnode_labels(g)
        @test labels["xyz"] == "c14n0"
    end

    @testset "RDFC-1.0 stability under input reordering" begin
        # Two distinguishable blank nodes; output must be identical regardless
        # of the order in which triples were inserted, and independent of the
        # original blank-node labels.
        function build(b1lbl, b2lbl, order)
            g = RDFGraph()
            b1 = BNode(b1lbl); b2 = BNode(b2lbl)
            ts = [
                Triple(b1, _u("p"), Literal("1")),
                Triple(b2, _u("p"), Literal("2")),
                Triple(b1, _u("knows"), b2),
            ]
            for i in order
                add!(g, ts[i])
            end
            g
        end
        c1 = rdfc10(build("aaa", "bbb", [1, 2, 3]))
        c2 = rdfc10(build("aaa", "bbb", [3, 2, 1]))
        c3 = rdfc10(build("zzz", "qqq", [2, 3, 1]))  # different labels
        @test c1 == c2
        @test c1 == c3
        # Sanity: the canonical form contains c14n0/c14n1 and is sorted.
        @test occursin("c14n0", c1) && occursin("c14n1", c1)
    end

    @testset "RDFC-1.0 isomorphic graphs canonicalize identically" begin
        # Symmetric structure (automorphism): two bnodes that mutually link.
        function symmetric(l1, l2)
            g = RDFGraph()
            a = BNode(l1); b = BNode(l2)
            add!(g, Triple(a, _u("p"), b))
            add!(g, Triple(b, _u("p"), a))
            g
        end
        @test rdfc10(symmetric("a", "b")) == rdfc10(symmetric("c", "d"))
        @test rdfc10(symmetric("a", "b")) == rdfc10(symmetric("b", "a"))
    end

    @testset "RDFC-1.0 dataset with blank graph name" begin
        ds1 = Dataset()
        bg = BNode("g1")
        add!(ds1, Triple(_u("s"), _u("p"), _u("o")), bg)
        ds2 = Dataset()
        bg2 = BNode("other")
        add!(ds2, Triple(_u("s"), _u("p"), _u("o")), bg2)
        # Isomorphic datasets (differ only in the bnode graph label) match.
        @test rdfc10(ds1) == rdfc10(ds2)
        @test occursin("_:c14n0", rdfc10(ds1))
    end

    @testset "empty input" begin
        @test rdf_canonicalize(RDFGraph()) == ""
        @test rdfc10(RDFGraph()) == ""
        @test rdf_canonicalize(Dataset()) == ""
        @test rdfc10(Dataset()) == ""
    end
end
