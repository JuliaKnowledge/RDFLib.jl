using Test
using RDFLib

@testset "RDF/XML" begin
    EX = Namespace("http://example.org/")

    @testset "serialization" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDF.type, EX("Person"))
        add!(g, EX("alice"), RDFS.label, Literal("Alice"))
        xml = serialize(g, RDFXMLFormat())

        @test contains(xml, "rdf:RDF")
        @test contains(xml, "rdf:Description")
        @test contains(xml, "http://example.org/alice")
        @test contains(xml, "Alice")
    end

    @testset "serialization - URI object" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), EX("knows"), EX("bob"))
        xml = serialize(g, RDFXMLFormat())
        @test contains(xml, "rdf:resource")
        @test contains(xml, "http://example.org/bob")
    end

    @testset "serialization - language tag" begin
        g = RDFGraph()
        bind!(g, "ex", EX)
        add!(g, EX("alice"), RDFS.label, Literal("Alice", lang="en"))
        xml = serialize(g, RDFXMLFormat())
        @test contains(xml, "xml:lang")
        @test contains(xml, "en")
    end

    @testset "parsing - basic" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <rdf:type rdf:resource="http://example.org/Person"/>
                <ex:name>Alice</ex:name>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
    end

    @testset "parsing - URI objects" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows rdf:resource="http://example.org/bob"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 1
        t = first(g)
        @test t.object == EX("bob")
    end

    @testset "parsing - typed node" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <ex:Person rdf:about="http://example.org/alice">
                <ex:name>Alice</ex:name>
            </ex:Person>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2  # type triple + name triple
        # Check type triple exists
        type_objs = collect(objects(g, EX("alice"), RDF.type))
        @test EX("Person") in type_objs
    end

    @testset "parsing - datatype" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/"
                 xmlns:xsd="http://www.w3.org/2001/XMLSchema#">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:age rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">30</ex:age>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        objs = collect(objects(g, EX("alice"), EX("age")))
        @test length(objs) == 1
        @test convert(Any, objs[1]) == 30
    end

    @testset "parsing - blank nodes" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:address rdf:parseType="Resource">
                    <ex:city>London</ex:city>
                </ex:address>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2  # alice→address→_:b, _:b→city→"London"
    end

    @testset "nested node element shares one subject" begin
        # The object of the outer triple must BE the subject of the inner triples
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows>
                    <rdf:Description rdf:about="http://example.org/bob">
                        <ex:name>Bob</ex:name>
                    </rdf:Description>
                </ex:knows>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
        knows = collect(objects(g, EX("alice"), EX("knows")))
        @test knows == [EX("bob")]
        @test collect(objects(g, EX("bob"), EX("name"))) == [Literal("Bob")]
    end

    @testset "nested anonymous node element - graph connectivity" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows>
                    <rdf:Description>
                        <ex:name>Carol</ex:name>
                    </rdf:Description>
                </ex:knows>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 2
        knows = collect(objects(g, EX("alice"), EX("knows")))
        @test length(knows) == 1
        @test knows[1] isa BNode
        # The SAME blank node must carry the inner triple
        @test collect(objects(g, knows[1], EX("name"))) == [Literal("Carol")]
    end

    @testset "nested typed node element connectivity" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:knows>
                    <ex:Person>
                        <ex:name>Dave</ex:name>
                    </ex:Person>
                </ex:knows>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 3
        knows = collect(objects(g, EX("alice"), EX("knows")))
        @test length(knows) == 1
        @test knows[1] isa BNode
        @test EX("Person") in collect(objects(g, knows[1], RDF.type))
        @test collect(objects(g, knows[1], EX("name"))) == [Literal("Dave")]
    end

    @testset "parseType=Collection - item nodes shared" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/alice">
                <ex:list rdf:parseType="Collection">
                    <rdf:Description rdf:about="http://example.org/x"/>
                    <rdf:Description>
                        <ex:name>anon</ex:name>
                    </rdf:Description>
                </ex:list>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        rdf_first = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
        rdf_rest = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
        rdf_nil = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
        heads = collect(objects(g, EX("alice"), EX("list")))
        @test length(heads) == 1
        head = heads[1]
        @test head isa BNode
        @test collect(objects(g, head, rdf_first)) == [EX("x")]
        rests = collect(objects(g, head, rdf_rest))
        @test length(rests) == 1
        cell2 = rests[1]
        items2 = collect(objects(g, cell2, rdf_first))
        @test length(items2) == 1
        @test items2[1] isa BNode
        # The collection item must BE the node that carries the inner triple
        @test collect(objects(g, items2[1], EX("name"))) == [Literal("anon")]
        @test collect(objects(g, cell2, rdf_rest)) == [rdf_nil]
    end

    @testset "parseType=Literal - single XMLLiteral triple" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/doc">
                <ex:content rdf:parseType="Literal"><b>bold</b> and text</ex:content>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 1
        t = first(g)
        @test t.subject == EX("doc")
        @test t.predicate == EX("content")
        @test t.object isa Literal
        @test t.object.datatype == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#XMLLiteral")
        @test t.object.lexical == "<b>bold</b> and text"
    end

    @testset "literal whitespace preserved verbatim" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/a">
                <ex:note>  padded  value  </ex:note>
                <ex:multi>line1
line2</ex:multi>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test collect(objects(g, EX("a"), EX("note"))) == [Literal("  padded  value  ")]
        @test collect(objects(g, EX("a"), EX("multi"))) == [Literal("line1\nline2")]
    end

    @testset "xml:base resolution" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/ns#"
                 xml:base="http://example.org/base/doc">
            <rdf:Description rdf:about="rel">
                <ex:p rdf:resource="other"/>
            </rdf:Description>
            <rdf:Description rdf:ID="frag">
                <ex:p>v</ex:p>
            </rdf:Description>
            <rdf:Description rdf:about="http://absolute.example.org/keep">
                <ex:p rdf:resource="http://absolute.example.org/obj"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        EXNS = Namespace("http://example.org/ns#")
        @test collect(objects(g, URIRef("http://example.org/base/rel"), EXNS("p"))) ==
              [URIRef("http://example.org/base/other")]
        @test collect(objects(g, URIRef("http://example.org/base/doc#frag"), EXNS("p"))) ==
              [Literal("v")]
        # Absolute IRIs untouched
        @test collect(objects(g, URIRef("http://absolute.example.org/keep"), EXNS("p"))) ==
              [URIRef("http://absolute.example.org/obj")]
    end

    @testset "xml:base inherited and overridable" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/ns#"
                 xml:base="http://example.org/base/">
            <rdf:Description rdf:about="inherited">
                <ex:p>a</ex:p>
            </rdf:Description>
            <rdf:Description rdf:about="x" xml:base="http://other.org/">
                <ex:p rdf:resource="y"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        EXNS = Namespace("http://example.org/ns#")
        @test collect(objects(g, URIRef("http://example.org/base/inherited"), EXNS("p"))) ==
              [Literal("a")]
        @test collect(objects(g, URIRef("http://other.org/x"), EXNS("p"))) ==
              [URIRef("http://other.org/y")]
    end

    @testset "base keyword argument" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/ns#">
            <rdf:Description rdf:ID="thing">
                <ex:p rdf:resource="rel"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = RDFLib.parse_rdfxml(xml; base="http://example.org/doc")
        EXNS = Namespace("http://example.org/ns#")
        @test collect(objects(g, URIRef("http://example.org/doc#thing"), EXNS("p"))) ==
              [URIRef("http://example.org/rel")]
    end

    @testset "no base - relative IRIs left as-is" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/ns#">
            <rdf:Description rdf:ID="thing">
                <ex:p rdf:resource="rel"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        EXNS = Namespace("http://example.org/ns#")
        @test collect(objects(g, URIRef("#thing"), EXNS("p"))) == [URIRef("rel")]
    end

    @testset "rdf:li expands to rdf:_1, rdf:_2 per parent" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Seq rdf:about="http://example.org/seq1">
                <rdf:li>one</rdf:li>
                <rdf:li>two</rdf:li>
            </rdf:Seq>
            <rdf:Bag rdf:about="http://example.org/bag1">
                <rdf:li>solo</rdf:li>
            </rdf:Bag>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        rdf_1 = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_1")
        rdf_2 = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#_2")
        @test collect(objects(g, URIRef("http://example.org/seq1"), rdf_1)) == [Literal("one")]
        @test collect(objects(g, URIRef("http://example.org/seq1"), rdf_2)) == [Literal("two")]
        # Counter restarts for each container element
        @test collect(objects(g, URIRef("http://example.org/bag1"), rdf_1)) == [Literal("solo")]
        # No rdf:li predicate must survive
        @test !any(t -> t.predicate == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#li"), collect(g))
    end

    @testset "xml:lang inheritance" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/a" xml:lang="en">
                <ex:p>hello</ex:p>
                <ex:q xml:lang="fr">bonjour</ex:q>
                <ex:r xml:lang="">plain</ex:r>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        # Inherited from the node element
        @test collect(objects(g, EX("a"), EX("p"))) == [Literal("hello", lang="en")]
        # Nearest declaration wins
        @test collect(objects(g, EX("a"), EX("q"))) == [Literal("bonjour", lang="fr")]
        # Empty xml:lang cancels inheritance
        @test collect(objects(g, EX("a"), EX("r"))) == [Literal("plain")]
    end

    @testset "xml:lang inherited from rdf:RDF root" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/" xml:lang="de">
            <rdf:Description rdf:about="http://example.org/a">
                <ex:p>hallo</ex:p>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test collect(objects(g, EX("a"), EX("p"))) == [Literal("hallo", lang="de")]
    end

    @testset "rdf:ID on property element reifies the statement" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/"
                 xml:base="http://example.org/doc">
            <rdf:Description rdf:about="http://example.org/a">
                <ex:p rdf:ID="st1" rdf:resource="http://example.org/b"/>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 5
        stmt = URIRef("http://example.org/doc#st1")
        rdfns = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        @test Triple(EX("a"), EX("p"), EX("b")) in g
        @test Triple(stmt, URIRef(rdfns * "type"), URIRef(rdfns * "Statement")) in g
        @test Triple(stmt, URIRef(rdfns * "subject"), EX("a")) in g
        @test Triple(stmt, URIRef(rdfns * "predicate"), EX("p")) in g
        @test Triple(stmt, URIRef(rdfns * "object"), EX("b")) in g
    end

    @testset "rdf:ID reification of a literal statement (no base)" begin
        xml = """<?xml version="1.0" encoding="UTF-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:ex="http://example.org/">
            <rdf:Description rdf:about="http://example.org/a">
                <ex:p rdf:ID="st2">val</ex:p>
            </rdf:Description>
        </rdf:RDF>"""
        g = parse_rdf(xml, RDFXMLFormat())
        @test length(g) == 5
        rdfns = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        @test Triple(EX("a"), EX("p"), Literal("val")) in g
        @test Triple(URIRef("#st2"), URIRef(rdfns * "object"), Literal("val")) in g
    end

    @testset "serializer declares generated namespace prefixes" begin
        g = RDFGraph()
        # Predicate URI with no '#' or '/' separator (fails compute_qname)
        add!(g, Triple(EX("s"), URIRef("urn:example:prop"), Literal("v")))
        xml = serialize(g, RDFXMLFormat())
        # Any generated prefix must be declared on the root element
        m = match(r"<(\w+):prop[ >/]", xml)
        @test m !== nothing
        prefix = m.captures[1]
        @test contains(xml, "xmlns:$prefix=\"urn:example:\"")
        # And the result must be valid, re-parseable XML preserving the triple
        g2 = parse_rdf(xml, RDFXMLFormat())
        @test Triple(EX("s"), URIRef("urn:example:prop"), Literal("v")) in g2
    end

    @testset "round-trip" begin
        g1 = RDFGraph()
        bind!(g1, "ex", EX)
        add!(g1, EX("alice"), RDF.type, EX("Person"))
        add!(g1, EX("alice"), RDFS.label, Literal("Alice"))
        add!(g1, EX("alice"), EX("knows"), EX("bob"))

        xml = serialize(g1, RDFXMLFormat())
        g2 = parse_rdf(xml, RDFXMLFormat())

        @test length(g2) == length(g1)
        for t in g1
            @test t in g2
        end
    end
end
