using Test
using RDFLib

include("../src/infixowl.jl")

const EX = Namespace("http://example.org/")

# Commonly used URIs
const RDF_TYPE      = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const RDFS_LABEL    = URIRef("http://www.w3.org/2000/01/rdf-schema#label")
const RDFS_COMMENT  = URIRef("http://www.w3.org/2000/01/rdf-schema#comment")
const RDFS_SUBCLASSOF = URIRef("http://www.w3.org/2000/01/rdf-schema#subClassOf")
const RDFS_DOMAIN   = URIRef("http://www.w3.org/2000/01/rdf-schema#domain")
const RDFS_RANGE    = URIRef("http://www.w3.org/2000/01/rdf-schema#range")
const OWL_CLASS     = URIRef("http://www.w3.org/2002/07/owl#Class")
const OWL_OBJECTPROPERTY = URIRef("http://www.w3.org/2002/07/owl#ObjectProperty")
const OWL_DATATYPEPROPERTY = URIRef("http://www.w3.org/2002/07/owl#DatatypeProperty")
const OWL_RESTRICTION = URIRef("http://www.w3.org/2002/07/owl#Restriction")
const OWL_ONPROPERTY = URIRef("http://www.w3.org/2002/07/owl#onProperty")
const OWL_SOMEVALUESFROM = URIRef("http://www.w3.org/2002/07/owl#someValuesFrom")
const OWL_ALLVALUESFROM = URIRef("http://www.w3.org/2002/07/owl#allValuesFrom")
const OWL_HASVALUE   = URIRef("http://www.w3.org/2002/07/owl#hasValue")
const OWL_CARDINALITY = URIRef("http://www.w3.org/2002/07/owl#cardinality")
const OWL_MINCARDINALITY = URIRef("http://www.w3.org/2002/07/owl#minCardinality")
const OWL_MAXCARDINALITY = URIRef("http://www.w3.org/2002/07/owl#maxCardinality")
const OWL_UNIONOF   = URIRef("http://www.w3.org/2002/07/owl#unionOf")
const OWL_INTERSECTIONOF = URIRef("http://www.w3.org/2002/07/owl#intersectionOf")
const OWL_COMPLEMENTOF  = URIRef("http://www.w3.org/2002/07/owl#complementOf")
const OWL_EQUIVALENTCLASS = URIRef("http://www.w3.org/2002/07/owl#equivalentClass")
const OWL_ONTOLOGY  = URIRef("http://www.w3.org/2002/07/owl#Ontology")
const OWL_VERSIONIRI = URIRef("http://www.w3.org/2002/07/owl#versionIRI")
const OWL_IMPORTS   = URIRef("http://www.w3.org/2002/07/owl#imports")
const OWL_SAMEAS    = URIRef("http://www.w3.org/2002/07/owl#sameAs")
const OWL_DIFFERENTFROM = URIRef("http://www.w3.org/2002/07/owl#differentFrom")
const OWL_FUNCTIONALPROPERTY = URIRef("http://www.w3.org/2002/07/owl#FunctionalProperty")
const OWL_INVERSEOF = URIRef("http://www.w3.org/2002/07/owl#inverseOf")
const RDF_FIRST     = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
const RDF_REST      = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
const RDF_NIL       = URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
const XSD_INTEGER   = URIRef("http://www.w3.org/2001/XMLSchema#integer")
const XSD_STRING    = URIRef("http://www.w3.org/2001/XMLSchema#string")

# Helper: walk an RDF list and return the rdf:first values in order
function collect_rdf_list(g::RDFGraph, head)
    items = []
    node = head
    while node != RDF_NIL
        firsts = collect(objects(g, node, RDF_FIRST))
        isempty(firsts) && break
        push!(items, firsts[1])
        rests = collect(objects(g, node, RDF_REST))
        isempty(rests) && break
        node = rests[1]
    end
    items
end

@testset "InfixOWL extras" begin

    # ── OWL Classes ──────────────────────────────────────────────────

    @testset "subclass chain (A → B → C)" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        b = OWLClass(EX("B"), g)
        c = OWLClass(EX("C"), g)
        subclass_of!(b, a)
        subclass_of!(c, b)
        @test Triple(EX("B"), RDFS_SUBCLASSOF, EX("A")) in g
        @test Triple(EX("C"), RDFS_SUBCLASSOF, EX("B")) in g
        # C is NOT directly subclass of A (no transitivity without reasoner)
        @test !(Triple(EX("C"), RDFS_SUBCLASSOF, EX("A")) in g)
    end

    @testset "equivalentClass via manual triple" begin
        g = RDFGraph()
        a = OWLClass(EX("Human"), g)
        b = OWLClass(EX("Person"), g)
        add!(g, Triple(a.uri, OWL_EQUIVALENTCLASS, b.uri))
        @test Triple(EX("Human"), OWL_EQUIVALENTCLASS, EX("Person")) in g
    end

    @testset "multiple labels on same class" begin
        g = RDFGraph()
        cls = OWLClass(EX("Cat"), g; label="Cat")
        add!(g, Triple(cls.uri, RDFS_LABEL, Literal("Katze")))
        labels = collect(objects(g, cls.uri, RDFS_LABEL))
        @test length(labels) == 2
        @test Literal("Cat") in labels
        @test Literal("Katze") in labels
    end

    @testset "class without label has no label triple" begin
        g = RDFGraph()
        cls = OWLClass(EX("Unlabeled"), g)
        labels = collect(objects(g, cls.uri, RDFS_LABEL))
        @test isempty(labels)
    end

    # ── Properties ───────────────────────────────────────────────────

    @testset "ObjectProperty minimal (no domain/range/label)" begin
        g = RDFGraph()
        prop = OWLObjectProperty(EX("knows"), g)
        @test prop.property_type == :object
        @test Triple(EX("knows"), RDF_TYPE, OWL_OBJECTPROPERTY) in g
        @test isempty(collect(objects(g, EX("knows"), RDFS_DOMAIN)))
        @test isempty(collect(objects(g, EX("knows"), RDFS_RANGE)))
    end

    @testset "DatatypeProperty with label" begin
        g = RDFGraph()
        prop = OWLDatatypeProperty(EX("name"), g; label="name")
        @test prop.property_type == :datatype
        @test Triple(EX("name"), RDFS_LABEL, Literal("name")) in g
    end

    @testset "Property domain/range with URIRef (not OWLClass)" begin
        g = RDFGraph()
        prop = OWLObjectProperty(EX("livesIn"), g;
                                  domain=EX("Person"), range=EX("Place"))
        @test Triple(EX("livesIn"), RDFS_DOMAIN, EX("Person")) in g
        @test Triple(EX("livesIn"), RDFS_RANGE, EX("Place")) in g
    end

    @testset "functional property via manual triple" begin
        g = RDFGraph()
        prop = OWLObjectProperty(EX("hasMother"), g)
        add!(g, Triple(EX("hasMother"), RDF_TYPE, OWL_FUNCTIONALPROPERTY))
        @test Triple(EX("hasMother"), RDF_TYPE, OWL_FUNCTIONALPROPERTY) in g
        @test Triple(EX("hasMother"), RDF_TYPE, OWL_OBJECTPROPERTY) in g
    end

    @testset "inverse property via manual triple" begin
        g = RDFGraph()
        prop1 = OWLObjectProperty(EX("hasChild"), g)
        prop2 = OWLObjectProperty(EX("hasParent"), g)
        add!(g, Triple(EX("hasChild"), OWL_INVERSEOF, EX("hasParent")))
        @test Triple(EX("hasChild"), OWL_INVERSEOF, EX("hasParent")) in g
    end

    # ── Restrictions ─────────────────────────────────────────────────

    @testset "restriction is typed owl:Restriction" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("p"); some_values_from=EX("C"))
        @test Triple(r, RDF_TYPE, OWL_RESTRICTION) in g
    end

    @testset "someValuesFrom with URIRef" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("eats"); some_values_from=EX("Food"))
        @test Triple(r, OWL_SOMEVALUESFROM, EX("Food")) in g
        @test Triple(r, OWL_ONPROPERTY, EX("eats")) in g
    end

    @testset "allValuesFrom with OWLClass" begin
        g = RDFGraph()
        food = OWLClass(EX("Food"), g)
        r = owl_restriction(g, EX("eats"); all_values_from=food)
        @test Triple(r, OWL_ALLVALUESFROM, EX("Food")) in g
    end

    @testset "hasValue with URIRef individual" begin
        g = RDFGraph()
        r = owl_restriction(g, EX("nationality"); has_value=EX("France"))
        @test Triple(r, OWL_HASVALUE, EX("France")) in g
    end

    @testset "multiple restrictions on same property" begin
        g = RDFGraph()
        r1 = owl_restriction(g, EX("hasChild"); min_cardinality=1)
        r2 = owl_restriction(g, EX("hasChild"); max_cardinality=5)
        @test r1 != r2
        @test Triple(r1, OWL_MINCARDINALITY, Literal(1)) in g
        @test Triple(r2, OWL_MAXCARDINALITY, Literal(5)) in g
        # Both restrict the same property
        @test Triple(r1, OWL_ONPROPERTY, EX("hasChild")) in g
        @test Triple(r2, OWL_ONPROPERTY, EX("hasChild")) in g
    end

    @testset "restriction as subclass" begin
        g = RDFGraph()
        parent = OWLClass(EX("Parent"), g)
        r = owl_restriction(g, EX("hasChild"); min_cardinality=1)
        add!(g, Triple(parent.uri, RDFS_SUBCLASSOF, r))
        @test Triple(EX("Parent"), RDFS_SUBCLASSOF, r) in g
    end

    # ── Set operations ───────────────────────────────────────────────

    @testset "union with 3 members and list structure" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        b = OWLClass(EX("B"), g)
        c = OWLClass(EX("C"), g)
        u = owl_union(g, [a, b, c])
        @test Triple(u, RDF_TYPE, OWL_CLASS) in g
        heads = collect(objects(g, u, OWL_UNIONOF))
        @test length(heads) == 1
        items = collect_rdf_list(g, heads[1])
        @test length(items) == 3
        @test EX("A") in items
        @test EX("B") in items
        @test EX("C") in items
    end

    @testset "intersection with 3 members and list structure" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        b = OWLClass(EX("B"), g)
        c = OWLClass(EX("C"), g)
        isect = owl_intersection(g, [a, b, c])
        @test Triple(isect, RDF_TYPE, OWL_CLASS) in g
        heads = collect(objects(g, isect, OWL_INTERSECTIONOF))
        @test length(heads) == 1
        items = collect_rdf_list(g, heads[1])
        @test length(items) == 3
        @test EX("A") in items
        @test EX("C") in items
    end

    @testset "complement with URIRef" begin
        g = RDFGraph()
        c = owl_complement(g, EX("Dead"))
        @test Triple(c, RDF_TYPE, OWL_CLASS) in g
        @test Triple(c, OWL_COMPLEMENTOF, EX("Dead")) in g
    end

    @testset "union with URIRefs (not OWLClass)" begin
        g = RDFGraph()
        u = owl_union(g, [EX("X"), EX("Y")])
        heads = collect(objects(g, u, OWL_UNIONOF))
        items = collect_rdf_list(g, heads[1])
        @test EX("X") in items
        @test EX("Y") in items
    end

    @testset "single-member union" begin
        g = RDFGraph()
        a = OWLClass(EX("Solo"), g)
        u = owl_union(g, [a])
        heads = collect(objects(g, u, OWL_UNIONOF))
        items = collect_rdf_list(g, heads[1])
        @test length(items) == 1
        @test items[1] == EX("Solo")
    end

    @testset "RDF list terminates with rdf:nil" begin
        g = RDFGraph()
        u = owl_union(g, [EX("P"), EX("Q")])
        heads = collect(objects(g, u, OWL_UNIONOF))
        # Walk to the last node and verify rest == rdf:nil
        node = heads[1]
        while true
            rests = collect(objects(g, node, RDF_REST))
            if rests[1] == RDF_NIL
                break
            end
            node = rests[1]
        end
        @test collect(objects(g, node, RDF_REST))[1] == RDF_NIL
    end

    # ── Individuals ──────────────────────────────────────────────────

    @testset "individual with no properties" begin
        g = RDFGraph()
        cls = OWLClass(EX("Thing"), g)
        owl_individual(g, EX("x"), cls)
        @test Triple(EX("x"), RDF_TYPE, EX("Thing")) in g
        # Only the type triple for this individual
        ind_triples = collect(triples(g, (EX("x"), nothing, nothing)))
        @test length(ind_triples) == 1
    end

    @testset "individual with multiple types" begin
        g = RDFGraph()
        person = OWLClass(EX("Person"), g)
        student = OWLClass(EX("Student"), g)
        owl_individual(g, EX("alice"), person)
        owl_individual(g, EX("alice"), student)
        types = collect(objects(g, EX("alice"), RDF_TYPE))
        @test EX("Person") in types
        @test EX("Student") in types
    end

    @testset "individual sameAs via manual triple" begin
        g = RDFGraph()
        cls = OWLClass(EX("Person"), g)
        owl_individual(g, EX("alice"), cls)
        owl_individual(g, EX("aliceSmith"), cls)
        add!(g, Triple(EX("alice"), OWL_SAMEAS, EX("aliceSmith")))
        @test Triple(EX("alice"), OWL_SAMEAS, EX("aliceSmith")) in g
    end

    @testset "individual differentFrom via manual triple" begin
        g = RDFGraph()
        cls = OWLClass(EX("Person"), g)
        owl_individual(g, EX("alice"), cls)
        owl_individual(g, EX("bob"), cls)
        add!(g, Triple(EX("alice"), OWL_DIFFERENTFROM, EX("bob")))
        @test Triple(EX("alice"), OWL_DIFFERENTFROM, EX("bob")) in g
    end

    @testset "individual with label property" begin
        g = RDFGraph()
        cls = OWLClass(EX("Person"), g)
        owl_individual(g, EX("alice"), cls;
                       properties=Dict(RDFS_LABEL => Literal("Alice Wonderland")))
        @test Triple(EX("alice"), RDFS_LABEL, Literal("Alice Wonderland")) in g
    end

    # ── Ontology metadata ────────────────────────────────────────────

    @testset "ontology with multiple imports" begin
        g = RDFGraph()
        owl_ontology!(g, EX("onto");
                      imports=[EX("import1"), EX("import2"), EX("import3")])
        @test Triple(EX("onto"), RDF_TYPE, OWL_ONTOLOGY) in g
        imps = collect(objects(g, EX("onto"), OWL_IMPORTS))
        @test length(imps) == 3
        @test EX("import1") in imps
        @test EX("import2") in imps
        @test EX("import3") in imps
    end

    @testset "ontology minimal (no version/imports/label)" begin
        g = RDFGraph()
        owl_ontology!(g, EX("bare"))
        @test Triple(EX("bare"), RDF_TYPE, OWL_ONTOLOGY) in g
        @test isempty(collect(objects(g, EX("bare"), OWL_VERSIONIRI)))
        @test isempty(collect(objects(g, EX("bare"), OWL_IMPORTS)))
        @test isempty(collect(objects(g, EX("bare"), RDFS_LABEL)))
    end

    @testset "ontology with single import (not array)" begin
        g = RDFGraph()
        owl_ontology!(g, EX("onto2"); imports=EX("singleImport"))
        @test Triple(EX("onto2"), OWL_IMPORTS, EX("singleImport")) in g
    end

    # ── Serialization ────────────────────────────────────────────────

    @testset "serialize OWL ontology to Turtle" begin
        g = RDFGraph()
        owl_ontology!(g, EX("pizza"); label="Pizza Ontology")
        pizza = OWLClass(EX("Pizza"), g; label="Pizza")
        topping = OWLClass(EX("Topping"), g)
        has_topping = OWLObjectProperty(EX("hasTopping"), g;
                                         domain=pizza, range=topping)
        margherita = OWLClass(EX("Margherita"), g)
        subclass_of!(margherita, pizza)

        buf = IOBuffer()
        serialize(buf, g, TurtleFormat())
        ttl = String(take!(buf))

        # Key terms must appear (serializer may use prefixed names)
        @test occursin("Pizza", ttl)
        @test occursin("Topping", ttl)
        @test occursin("hasTopping", ttl)
        @test occursin("Margherita", ttl)
        @test occursin("Class", ttl)
    end

    # ── Complex patterns ─────────────────────────────────────────────

    @testset "restriction on union class" begin
        g = RDFGraph()
        cat = OWLClass(EX("Cat"), g)
        dog = OWLClass(EX("Dog"), g)
        pet_union = owl_union(g, [cat, dog])
        r = owl_restriction(g, EX("hasPet"); some_values_from=pet_union)
        @test Triple(r, OWL_SOMEVALUESFROM, pet_union) in g
        @test Triple(pet_union, OWL_UNIONOF,
                     collect(objects(g, pet_union, OWL_UNIONOF))[1]) in g
    end

    @testset "nested intersection" begin
        g = RDFGraph()
        a = OWLClass(EX("A"), g)
        b = OWLClass(EX("B"), g)
        c = OWLClass(EX("C"), g)
        inner = owl_intersection(g, [a, b])
        outer = owl_intersection(g, [inner, c])
        outer_heads = collect(objects(g, outer, OWL_INTERSECTIONOF))
        outer_items = collect_rdf_list(g, outer_heads[1])
        @test length(outer_items) == 2
        # One item is the inner intersection bnode, the other is C
        @test EX("C") in outer_items
        @test inner in outer_items
    end

    @testset "class with multiple restriction subclasses" begin
        g = RDFGraph()
        person = OWLClass(EX("Person"), g)
        r1 = owl_restriction(g, EX("hasAge"); cardinality=1)
        r2 = owl_restriction(g, EX("hasName"); min_cardinality=1)
        r3 = owl_restriction(g, EX("hasAddress"); some_values_from=EX("Address"))
        add!(g, Triple(person.uri, RDFS_SUBCLASSOF, r1))
        add!(g, Triple(person.uri, RDFS_SUBCLASSOF, r2))
        add!(g, Triple(person.uri, RDFS_SUBCLASSOF, r3))
        parents = collect(objects(g, EX("Person"), RDFS_SUBCLASSOF))
        @test length(parents) == 3
        @test r1 in parents
        @test r2 in parents
        @test r3 in parents
    end

    @testset "equivalentClass to intersection of restrictions" begin
        g = RDFGraph()
        parent = OWLClass(EX("Parent"), g)
        r1 = owl_restriction(g, EX("hasChild"); min_cardinality=1)
        r2 = owl_restriction(g, EX("hasAge"); some_values_from=XSD_INTEGER)
        isect = owl_intersection(g, [r1, r2])
        add!(g, Triple(parent.uri, OWL_EQUIVALENTCLASS, isect))
        @test Triple(EX("Parent"), OWL_EQUIVALENTCLASS, isect) in g
        # Verify the intersection members
        heads = collect(objects(g, isect, OWL_INTERSECTIONOF))
        items = collect_rdf_list(g, heads[1])
        @test length(items) == 2
        @test r1 in items
        @test r2 in items
    end

    @testset "full ontology round-trip structure" begin
        g = RDFGraph()
        owl_ontology!(g, EX("animals"); label="Animal Ontology",
                      version=EX("animals/v1"))
        animal = OWLClass(EX("Animal"), g; label="Animal")
        mammal = OWLClass(EX("Mammal"), g)
        subclass_of!(mammal, animal)
        legs = OWLDatatypeProperty(EX("numLegs"), g;
                                    domain=mammal, range=XSD_INTEGER)
        has_offspring = OWLObjectProperty(EX("hasOffspring"), g;
                                           domain=animal, range=animal)
        r = owl_restriction(g, EX("hasOffspring"); some_values_from=mammal)
        add!(g, Triple(mammal.uri, RDFS_SUBCLASSOF, r))
        owl_individual(g, EX("rex"), mammal;
                       properties=Dict(RDFS_LABEL => Literal("Rex"),
                                       EX("numLegs") => Literal(4)))

        # Verify structure
        @test Triple(EX("animals"), RDF_TYPE, OWL_ONTOLOGY) in g
        @test Triple(EX("Mammal"), RDFS_SUBCLASSOF, EX("Animal")) in g
        @test Triple(EX("Mammal"), RDFS_SUBCLASSOF, r) in g
        @test Triple(EX("rex"), RDF_TYPE, EX("Mammal")) in g
        @test Triple(EX("rex"), EX("numLegs"), Literal(4)) in g
        @test Triple(EX("numLegs"), RDF_TYPE, OWL_DATATYPEPROPERTY) in g
        @test Triple(EX("hasOffspring"), RDF_TYPE, OWL_OBJECTPROPERTY) in g
    end

end
