using Test
using RDFLib

include("../src/infixowl.jl")

const EX = Namespace("http://example.org/")

@testset "InfixOWL" begin
    @testset "OWLClass creation" begin
        g = RDFGraph()
        cls = OWLClass(EX("Animal"), g)
        @test cls.uri == EX("Animal")
        @test Triple(EX("Animal"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     URIRef("http://www.w3.org/2002/07/owl#Class")) in g
    end

    @testset "OWLClass with label" begin
        g = RDFGraph()
        cls = OWLClass(EX("Person"), g; label="Person")
        @test Triple(EX("Person"), URIRef("http://www.w3.org/2000/01/rdf-schema#label"),
                     Literal("Person")) in g
    end

    @testset "subclass_of! with OWLClass" begin
        g = RDFGraph()
        animal = OWLClass(EX("Animal"), g)
        dog = OWLClass(EX("Dog"), g)
        subclass_of!(dog, animal)
        @test Triple(EX("Dog"), URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf"),
                     EX("Animal")) in g
    end

    @testset "subclass_of! with URIRef" begin
        g = RDFGraph()
        dog = OWLClass(EX("Dog"), g)
        subclass_of!(dog, EX("Animal"))
        @test Triple(EX("Dog"), URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf"),
                     EX("Animal")) in g
    end

    @testset "OWLObjectProperty" begin
        g = RDFGraph()
        animal = OWLClass(EX("Animal"), g)
        prop = OWLObjectProperty(EX("hasPart"), g; domain=animal, range=animal, label="has part")
        @test prop.property_type == :object
        @test Triple(EX("hasPart"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     URIRef("http://www.w3.org/2002/07/owl#ObjectProperty")) in g
        @test Triple(EX("hasPart"), URIRef("http://www.w3.org/2000/01/rdf-schema#domain"),
                     EX("Animal")) in g
        @test Triple(EX("hasPart"), URIRef("http://www.w3.org/2000/01/rdf-schema#range"),
                     EX("Animal")) in g
        @test Triple(EX("hasPart"), URIRef("http://www.w3.org/2000/01/rdf-schema#label"),
                     Literal("has part")) in g
    end

    @testset "OWLDatatypeProperty" begin
        g = RDFGraph()
        person = OWLClass(EX("Person"), g)
        prop = OWLDatatypeProperty(EX("age"), g; domain=person,
                                   range=URIRef("http://www.w3.org/2001/XMLSchema#integer"))
        @test prop.property_type == :datatype
        @test Triple(EX("age"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     URIRef("http://www.w3.org/2002/07/owl#DatatypeProperty")) in g
        @test Triple(EX("age"), URIRef("http://www.w3.org/2000/01/rdf-schema#domain"),
                     EX("Person")) in g
    end

    @testset "owl_restriction someValuesFrom" begin
        g = RDFGraph()
        animal = OWLClass(EX("Animal"), g)
        r = owl_restriction(g, EX("hasPart"); some_values_from=animal)
        @test r isa BNode
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#onProperty"), EX("hasPart")) in g
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#someValuesFrom"), EX("Animal")) in g
    end

    @testset "owl_restriction allValuesFrom" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("eats"); all_values_from=EX("Food"))
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#allValuesFrom"), EX("Food")) in g
    end

    @testset "owl_restriction cardinality" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("hasParent"); cardinality=2)
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#cardinality"), Literal(2)) in g
    end

    @testset "owl_restriction min/max cardinality" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("hasChild"); min_cardinality=0, max_cardinality=10)
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#minCardinality"), Literal(0)) in g
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#maxCardinality"), Literal(10)) in g
    end

    @testset "owl_restriction hasValue" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("color"); has_value=Literal("red"))
        @test Triple(r, URIRef("http://www.w3.org/2002/07/owl#hasValue"), Literal("red")) in g
    end

    @testset "owl_ontology!" begin
        g = RDFGraph()
        owl_ontology!(g, EX("myOntology"); label="My Ontology",
                      version=EX("myOntology/1.0"),
                      imports=[EX("otherOntology")])
        @test Triple(EX("myOntology"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     URIRef("http://www.w3.org/2002/07/owl#Ontology")) in g
        @test Triple(EX("myOntology"), URIRef("http://www.w3.org/2000/01/rdf-schema#label"),
                     Literal("My Ontology")) in g
        @test Triple(EX("myOntology"), URIRef("http://www.w3.org/2002/07/owl#versionIRI"),
                     EX("myOntology/1.0")) in g
        @test Triple(EX("myOntology"), URIRef("http://www.w3.org/2002/07/owl#imports"),
                     EX("otherOntology")) in g
    end

    @testset "owl_union" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        b = OWLClass(EX("B"), g)
        u = owl_union(g, [a, b])
        @test u isa BNode
        @test Triple(u, URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     URIRef("http://www.w3.org/2002/07/owl#Class")) in g
        # Check owl:unionOf points to a list head
        union_heads = collect(objects(g, u, URIRef("http://www.w3.org/2002/07/owl#unionOf")))
        @test length(union_heads) == 1
    end

    @testset "owl_intersection" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        b = OWLClass(EX("B"), g)
        isect = owl_intersection(g, [a, b])
        @test isect isa BNode
        inter_heads = collect(objects(g, isect, URIRef("http://www.w3.org/2002/07/owl#intersectionOf")))
        @test length(inter_heads) == 1
    end

    @testset "owl_complement" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        c = owl_complement(g, a)
        @test c isa BNode
        @test Triple(c, URIRef("http://www.w3.org/2002/07/owl#complementOf"), EX("A")) in g
    end

    @testset "owl_individual" begin
        g = RDFGraph()
        person = OWLClass(EX("Person"), g)
        owl_individual(g, EX("alice"), person;
                       properties=Dict(EX("name") => Literal("Alice"),
                                       EX("age") => Literal(30)))
        @test Triple(EX("alice"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     EX("Person")) in g
        @test Triple(EX("alice"), EX("name"), Literal("Alice")) in g
        @test Triple(EX("alice"), EX("age"), Literal(30)) in g
    end

    @testset "owl_individual with URIRef class" begin
        g = RDFGraph()
        owl_individual(g, EX("bob"), EX("Person"))
        @test Triple(EX("bob"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                     EX("Person")) in g
    end
end
