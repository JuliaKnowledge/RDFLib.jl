# RIF Core entailment: RIF/XML parsing, forward chaining, and the minimal
# OWL Functional Syntax reader. Network-independent — uses inline documents.

using Test
using RDFLib

@testset "RIF" begin

    # The "uncle" rule plus inline ground facts, in RIF/XML (entity-expanded).
    rif_uncle = """
    <!DOCTYPE Document [
      <!ENTITY rif "http://www.w3.org/2007/rif#">
      <!ENTITY ex  "http://example.org/ns#">
    ]>
    <Document xmlns="&rif;">
      <payload>
        <Group>
          <sentence>
            <Forall>
              <declare><Var>x</Var></declare>
              <declare><Var>y</Var></declare>
              <declare><Var>z</Var></declare>
              <formula>
                <Implies>
                  <if>
                    <And>
                      <formula>
                        <Frame>
                          <object><Var>x</Var></object>
                          <slot ordered="yes">
                            <Const type="&rif;iri">&ex;parent</Const>
                            <Var>y</Var>
                          </slot>
                        </Frame>
                      </formula>
                      <formula>
                        <Frame>
                          <object><Var>y</Var></object>
                          <slot ordered="yes">
                            <Const type="&rif;iri">&ex;brother</Const>
                            <Var>z</Var>
                          </slot>
                        </Frame>
                      </formula>
                    </And>
                  </if>
                  <then>
                    <Frame>
                      <object><Var>x</Var></object>
                      <slot ordered="yes">
                        <Const type="&rif;iri">&ex;uncle</Const>
                        <Var>z</Var>
                      </slot>
                    </Frame>
                  </then>
                </Implies>
              </formula>
            </Forall>
          </sentence>
          <sentence>
            <Frame>
              <object><Const type="&rif;iri">&ex;Emeka</Const></object>
              <slot ordered="yes">
                <Const type="&rif;iri">&ex;parent</Const>
                <Const type="&rif;iri">&ex;Okechukwu</Const>
              </slot>
            </Frame>
          </sentence>
        </Group>
      </payload>
    </Document>
    """

    @testset "parse_rif: rules + facts" begin
        doc = parse_rif(rif_uncle)
        @test length(doc.rules) == 1
        @test length(doc.facts) == 1
        @test isempty(doc.imports)
        r = doc.rules[1]
        @test length(r.body) == 2
        @test length(r.head) == 1
        # body patterns carry Variables where the RIF text used <Var>.
        @test r.head[1].p == URIRef("http://example.org/ns#uncle")
        @test r.head[1].s isa Variable
        # ground fact decoded into a Triple.
        f = doc.facts[1]
        @test f.subject == URIRef("http://example.org/ns#Emeka")
        @test f.predicate == URIRef("http://example.org/ns#parent")
        @test f.object == URIRef("http://example.org/ns#Okechukwu")
    end

    @testset "forward chaining derives uncle" begin
        doc = parse_rif(rif_uncle)
        g = RDFGraph()
        for t in doc.facts
            add!(g, t)
        end
        # second fact: Okechukwu brother Chijoke
        add!(g, Triple(URIRef("http://example.org/ns#Okechukwu"),
                       URIRef("http://example.org/ns#brother"),
                       URIRef("http://example.org/ns#Chijoke")))
        rif_forward_chain!(g, doc.rules)
        derived = collect(triples(g, (URIRef("http://example.org/ns#Emeka"),
                                       URIRef("http://example.org/ns#uncle"), nothing)))
        @test length(derived) == 1
        @test derived[1].object == URIRef("http://example.org/ns#Chijoke")
    end

    @testset "typed-literal const in head" begin
        rif_disc = """
        <!DOCTYPE Document [
          <!ENTITY rif "http://www.w3.org/2007/rif#">
          <!ENTITY xs  "http://www.w3.org/2001/XMLSchema#">
        ]>
        <Document xmlns="&rif;">
          <payload><Group>
            <sentence>
              <Forall>
                <declare><Var>c</Var></declare>
                <formula><Implies>
                  <if>
                    <Frame>
                      <object><Var>c</Var></object>
                      <slot ordered="yes">
                        <Const type="&rif;iri">http://ex#status</Const>
                        <Const type="&xs;string">gold</Const>
                      </slot>
                    </Frame>
                  </if>
                  <then>
                    <Frame>
                      <object><Var>c</Var></object>
                      <slot ordered="yes">
                        <Const type="&rif;iri">http://ex#discount</Const>
                        <Const type="&xs;integer">10</Const>
                      </slot>
                    </Frame>
                  </then>
                </Implies></formula>
              </Forall>
            </sentence>
          </Group></payload>
        </Document>
        """
        doc = parse_rif(rif_disc)
        g = RDFGraph()
        add!(g, Triple(URIRef("http://ex#cust"), URIRef("http://ex#status"), Literal("gold")))
        rif_forward_chain!(g, doc.rules)
        out = collect(triples(g, (URIRef("http://ex#cust"), URIRef("http://ex#discount"), nothing)))
        @test length(out) == 1
        lit = out[1].object
        @test lit isa Literal
        @test lit.lexical == "10"
        @test RDFLib.datatype(lit) == URIRef("http://www.w3.org/2001/XMLSchema#integer")
    end

    @testset "minimal OWL Functional Syntax" begin
        owlfs = """
        Namespace(=<http://example.org/o#>)
        Ontology(<http://example.org/o>
          # a comment with a # inside should be stripped after the IRI
          SubClassOf(Gyrus MaterialAnatomicalEntity)
          SymmetricObjectProperty(isMAEConnectedTo)
          ObjectPropertyDomain(isMAEBoundedBy MaterialAnatomicalEntity)
          ObjectPropertyRange(isMAEBoundedBy ObjectUnionOf(GyriConnection SucalFold))
          ClassAssertion(Gyrus g1)
          ObjectPropertyAssertion(isMAEBoundedBy g1 op)
        )
        """
        g = RDFGraph()
        parse_owl_functional!(g, owlfs)
        O(s) = URIRef("http://example.org/o#" * s)
        RDFS = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
        RDFTYPE = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        OWLSym = URIRef("http://www.w3.org/2002/07/owl#SymmetricProperty")
        @test Triple(O("Gyrus"), RDFS, O("MaterialAnatomicalEntity")) in g
        @test Triple(O("isMAEConnectedTo"), RDFTYPE, OWLSym) in g
        @test Triple(O("g1"), RDFTYPE, O("Gyrus")) in g
        @test Triple(O("g1"), O("isMAEBoundedBy"), O("op")) in g
        @test Triple(O("isMAEBoundedBy"),
                     URIRef("http://www.w3.org/2000/01/rdf-schema#domain"),
                     O("MaterialAnatomicalEntity")) in g
        # range is an ObjectUnionOf → a bnode with owl:unionOf list
        rng = collect(triples(g, (O("isMAEBoundedBy"),
              URIRef("http://www.w3.org/2000/01/rdf-schema#range"), nothing)))
        @test length(rng) == 1
        @test rng[1].object isa BNode
    end

    @testset "import location collection" begin
        rif_imp = """
        <!DOCTYPE Document [ <!ENTITY rif "http://www.w3.org/2007/rif#"> ]>
        <Document xmlns="&rif;">
          <directive>
            <Import>
              <location>http://example.org/data.ttl</location>
              <profile>http://www.w3.org/ns/entailment/RDF</profile>
            </Import>
          </directive>
          <payload><Group></Group></payload>
        </Document>
        """
        doc = parse_rif(rif_imp)
        @test doc.imports == ["http://example.org/data.ttl"]
    end
end
