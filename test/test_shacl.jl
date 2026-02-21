using Test, RDFLib

const shacl_validate = RDFLib.validate
const SGraph = RDFLib.RDFGraph

@testset "SHACL Validation" begin
    EX = Namespace("http://example.org/")

    function make_person_shape()
        shapes = SGraph()
        shape = EX("PersonShape")
        add!(shapes, Triple(shape, RDF.type, SH.NodeShape))
        add!(shapes, Triple(shape, SH.targetClass, EX("Person")))

        # name: required, exactly 1
        name_prop = BNode("name_prop")
        add!(shapes, Triple(shape, SH.property, name_prop))
        add!(shapes, Triple(name_prop, SH.path, EX("name")))
        add!(shapes, Triple(name_prop, SH.minCount, Literal(1)))
        add!(shapes, Triple(name_prop, SH.maxCount, Literal(1)))
        add!(shapes, Triple(name_prop, SH.datatype, XSD.string))

        # age: optional, integer, 0-150
        age_prop = BNode("age_prop")
        add!(shapes, Triple(shape, SH.property, age_prop))
        add!(shapes, Triple(age_prop, SH.path, EX("age")))
        add!(shapes, Triple(age_prop, SH.maxCount, Literal(1)))
        add!(shapes, Triple(age_prop, SH.datatype, URIRef("http://www.w3.org/2001/XMLSchema#integer")))
        add!(shapes, Triple(age_prop, SH.minInclusive, Literal(0)))
        add!(shapes, Triple(age_prop, SH.maxInclusive, Literal(150)))

        shapes
    end

    @testset "valid data" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(data, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(data, Triple(EX("alice"), EX("age"), Literal(30)))

        report = shacl_validate(data, shapes)
        @test report.conforms
        @test isempty(report.results)
    end

    @testset "missing required property" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        # Missing name!

        report = shacl_validate(data, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("alice"), report.results)
    end

    @testset "too many values" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(data, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(data, Triple(EX("alice"), EX("name"), Literal("Ali")))  # too many names

        report = shacl_validate(data, shapes)
        @test !report.conforms
    end

    @testset "wrong datatype" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(data, Triple(EX("alice"), EX("name"), Literal(42)))  # integer, not string

        report = shacl_validate(data, shapes)
        @test !report.conforms
    end

    @testset "value out of range" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(data, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(data, Triple(EX("alice"), EX("age"), Literal(200)))  # > 150

        report = shacl_validate(data, shapes)
        @test !report.conforms
    end

    @testset "nodeKind constraint" begin
        shapes = SGraph()
        shape = EX("IRIShape")
        add!(shapes, Triple(shape, RDF.type, SH.NodeShape))
        add!(shapes, Triple(shape, SH.targetClass, EX("Thing")))
        prop = BNode()
        add!(shapes, Triple(shape, SH.property, prop))
        add!(shapes, Triple(prop, SH.path, EX("ref")))
        add!(shapes, Triple(prop, SH.nodeKind, SH.IRI))

        data = SGraph()
        add!(data, Triple(EX("x"), RDF.type, EX("Thing")))
        add!(data, Triple(EX("x"), EX("ref"), EX("y")))  # IRI - ok
        report = shacl_validate(data, shapes)
        @test report.conforms

        data2 = SGraph()
        add!(data2, Triple(EX("x"), RDF.type, EX("Thing")))
        add!(data2, Triple(EX("x"), EX("ref"), Literal("not-an-iri")))  # Literal - fail
        report2 = shacl_validate(data2, shapes)
        @test !report2.conforms
    end

    @testset "pattern constraint" begin
        shapes = SGraph()
        shape = EX("EmailShape")
        add!(shapes, Triple(shape, RDF.type, SH.NodeShape))
        add!(shapes, Triple(shape, SH.targetClass, EX("Person")))
        prop = BNode()
        add!(shapes, Triple(shape, SH.property, prop))
        add!(shapes, Triple(prop, SH.path, EX("email")))
        add!(shapes, Triple(prop, SH.pattern, Literal(raw"^[^@]+@[^@]+$")))

        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(data, Triple(EX("alice"), EX("email"), Literal("alice@example.org")))
        report = shacl_validate(data, shapes)
        @test report.conforms

        data2 = SGraph()
        add!(data2, Triple(EX("bob"), RDF.type, EX("Person")))
        add!(data2, Triple(EX("bob"), EX("email"), Literal("not-an-email")))
        report2 = shacl_validate(data2, shapes)
        @test !report2.conforms
    end

    @testset "targetNode" begin
        shapes = SGraph()
        shape = EX("AliceShape")
        add!(shapes, Triple(shape, RDF.type, SH.NodeShape))
        add!(shapes, Triple(shape, SH.targetNode, EX("alice")))
        prop = BNode()
        add!(shapes, Triple(shape, SH.property, prop))
        add!(shapes, Triple(prop, SH.path, EX("name")))
        add!(shapes, Triple(prop, SH.minCount, Literal(1)))

        data = SGraph()
        add!(data, Triple(EX("alice"), EX("name"), Literal("Alice")))
        report = shacl_validate(data, shapes)
        @test report.conforms
    end

    @testset "validation report structure" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))

        report = shacl_validate(data, shapes)
        @test report isa ValidationReport
        @test !report.conforms
        @test length(report.results) >= 1
        r = report.results[1]
        @test r isa ValidationResult
        @test r.focus_node == EX("alice")
        @test r.severity == SH.Violation
    end

    @testset "multiple shapes" begin
        shapes = SGraph()

        s1 = EX("Shape1")
        add!(shapes, Triple(s1, RDF.type, SH.NodeShape))
        add!(shapes, Triple(s1, SH.targetClass, EX("Person")))
        p1 = BNode("p1")
        add!(shapes, Triple(s1, SH.property, p1))
        add!(shapes, Triple(p1, SH.path, EX("name")))
        add!(shapes, Triple(p1, SH.minCount, Literal(1)))

        s2 = EX("Shape2")
        add!(shapes, Triple(s2, RDF.type, SH.NodeShape))
        add!(shapes, Triple(s2, SH.targetClass, EX("Organization")))
        p2 = BNode("p2")
        add!(shapes, Triple(s2, SH.property, p2))
        add!(shapes, Triple(p2, SH.path, EX("name")))
        add!(shapes, Triple(p2, SH.minCount, Literal(1)))

        data = SGraph()
        add!(data, Triple(EX("alice"), RDF.type, EX("Person")))
        add!(data, Triple(EX("alice"), EX("name"), Literal("Alice")))
        add!(data, Triple(EX("acme"), RDF.type, EX("Organization")))
        # acme is missing name

        report = shacl_validate(data, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("acme"), report.results)
        @test !any(r -> r.focus_node == EX("alice"), report.results)
    end

    @testset "no targets - conforms" begin
        shapes = make_person_shape()
        data = SGraph()
        add!(data, Triple(EX("x"), EX("p"), Literal("no persons here")))
        report = shacl_validate(data, shapes)
        @test report.conforms
    end
end
