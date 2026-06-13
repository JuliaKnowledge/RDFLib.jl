using Test, RDFLib

const shacl_validate = RDFLib.validate
const SGraph = RDFLib.RDFGraph

# Helper: parse a Turtle snippet (with standard prefixes) into a graph
const _SHACL_TTL_PREFIXES = """
@prefix sh:   <http://www.w3.org/ns/shacl#> .
@prefix ex:   <http://example.org/> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
@prefix rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
"""
_shacl_ttl(s::AbstractString) = parse_rdf(_SHACL_TTL_PREFIXES * s, TurtleFormat())

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
        @test r.result_path == r.path  # compat accessor
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

@testset "SHACL Advanced" begin
    EX = Namespace("http://example.org/")

    # ─── Logical constraints ─────────────────────────────────────────

    @testset "sh:not" begin
        shapes = _shacl_ttl(raw"""
        ex:NotShape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:not [ sh:path ex:age ; sh:maxCount 0 ] .
        """)

        # has an age => does NOT conform to [maxCount 0] => sh:not satisfied
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:age 30 .
        """)
        @test shacl_validate(data, shapes).conforms

        # no age => conforms to [maxCount 0] => sh:not violated
        data2 = _shacl_ttl(raw"""
        ex:bob a ex:Person .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("bob"), report.results)
    end

    @testset "sh:not in property shape (per-value)" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Thing ;
            sh:property [
                sh:path ex:val ;
                sh:not [ sh:datatype xsd:integer ]
            ] .
        """)
        data = _shacl_ttl(raw"""ex:x a ex:Thing ; ex:val "text" .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:y a ex:Thing ; ex:val 5 .""")
        @test !shacl_validate(data2, shapes).conforms
    end

    @testset "sh:and" begin
        shapes = _shacl_ttl(raw"""
        ex:AndShape a sh:NodeShape ;
            sh:targetNode ex:x ;
            sh:and (
                [ sh:path ex:p ; sh:minCount 1 ]
                [ sh:path ex:q ; sh:minCount 1 ]
            ) .
        """)
        data = _shacl_ttl(raw"""ex:x ex:p 1 ; ex:q 2 .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:x ex:p 1 .""")
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> occursin("sh:and", r.message), report.results)
    end

    @testset "sh:or" begin
        shapes = _shacl_ttl(raw"""
        ex:OrShape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:or (
                [ sh:path ex:fullName ; sh:minCount 1 ]
                [ sh:path ex:firstName ; sh:minCount 1 ]
            ) .
        """)
        data = _shacl_ttl(raw"""
        ex:a a ex:Person ; ex:fullName "Alice A" .
        ex:b a ex:Person ; ex:firstName "Bob" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:c a ex:Person ; ex:nickname "C" .""")
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> occursin("sh:or", r.message), report.results)
    end

    @testset "sh:xone" begin
        shapes = _shacl_ttl(raw"""
        ex:XoneShape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:xone (
                [ sh:path ex:fullName ; sh:minCount 1 ]
                [ sh:path ex:firstName ; sh:minCount 1 ]
            ) .
        """)
        # exactly one alternative => conforms
        data = _shacl_ttl(raw"""ex:a a ex:Person ; ex:fullName "Alice A" .""")
        @test shacl_validate(data, shapes).conforms

        # both alternatives => violation
        data2 = _shacl_ttl(raw"""
        ex:b a ex:Person ; ex:fullName "Bob B" ; ex:firstName "Bob" .
        """)
        @test !shacl_validate(data2, shapes).conforms

        # neither => violation
        data3 = _shacl_ttl(raw"""ex:c a ex:Person .""")
        @test !shacl_validate(data3, shapes).conforms
    end

    # ─── Shape-based constraints ─────────────────────────────────────

    @testset "sh:node" begin
        shapes = _shacl_ttl(raw"""
        ex:AddressShape a sh:NodeShape ;
            sh:property [ sh:path ex:postalCode ; sh:minCount 1 ] .

        ex:PersonShape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [
                sh:path ex:address ;
                sh:node ex:AddressShape
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:address ex:addr1 .
        ex:addr1 ex:postalCode "12345" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""
        ex:bob a ex:Person ; ex:address ex:addr2 .
        ex:addr2 ex:city "Springfield" .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("bob") && r.value == EX("addr2"), report.results)
    end

    @testset "sh:qualifiedValueShape min/max" begin
        shapes = _shacl_ttl(raw"""
        ex:HandShape a sh:NodeShape ;
            sh:targetClass ex:Hand ;
            sh:property [
                sh:path ex:digit ;
                sh:qualifiedValueShape [ sh:class ex:Thumb ] ;
                sh:qualifiedMinCount 1 ;
                sh:qualifiedMaxCount 1
            ] .
        """)
        # exactly one thumb => conforms
        data = _shacl_ttl(raw"""
        ex:hand a ex:Hand ; ex:digit ex:t1, ex:f1 .
        ex:t1 a ex:Thumb . ex:f1 a ex:Finger .
        """)
        @test shacl_validate(data, shapes).conforms

        # no thumbs => qualifiedMinCount violated
        data2 = _shacl_ttl(raw"""
        ex:hand a ex:Hand ; ex:digit ex:f1 .
        ex:f1 a ex:Finger .
        """)
        @test !shacl_validate(data2, shapes).conforms

        # two thumbs => qualifiedMaxCount violated
        data3 = _shacl_ttl(raw"""
        ex:hand a ex:Hand ; ex:digit ex:t1, ex:t2 .
        ex:t1 a ex:Thumb . ex:t2 a ex:Thumb .
        """)
        @test !shacl_validate(data3, shapes).conforms
    end

    @testset "sh:qualifiedValueShapesDisjoint" begin
        shapes_disjoint = _shacl_ttl(raw"""
        ex:HandShape a sh:NodeShape ;
            sh:targetClass ex:Hand ;
            sh:property [
                sh:path ex:digit ;
                sh:qualifiedValueShape [ sh:class ex:Thumb ] ;
                sh:qualifiedValueShapesDisjoint true ;
                sh:qualifiedMinCount 1
            ] ;
            sh:property [
                sh:path ex:digit ;
                sh:qualifiedValueShape [ sh:class ex:Finger ] ;
                sh:qualifiedValueShapesDisjoint true ;
                sh:qualifiedMinCount 1
            ] .
        """)
        # one digit typed both Thumb AND Finger: with disjoint=true it counts
        # for neither sibling => both qualifiedMinCounts fail
        data = _shacl_ttl(raw"""
        ex:hand a ex:Hand ; ex:digit ex:d1 .
        ex:d1 a ex:Thumb, ex:Finger .
        """)
        @test !shacl_validate(data, shapes_disjoint).conforms

        # distinct thumb and finger => conforms
        data2 = _shacl_ttl(raw"""
        ex:hand a ex:Hand ; ex:digit ex:t1, ex:f1 .
        ex:t1 a ex:Thumb . ex:f1 a ex:Finger .
        """)
        @test shacl_validate(data2, shapes_disjoint).conforms
    end

    # ─── sh:closed ───────────────────────────────────────────────────

    @testset "sh:closed with sh:ignoredProperties" begin
        shapes = _shacl_ttl(raw"""
        ex:ClosedShape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:closed true ;
            sh:ignoredProperties ( rdf:type ) ;
            sh:property [ sh:path ex:name ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:name "Alice" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""
        ex:bob a ex:Person ; ex:name "Bob" ; ex:age 30 .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        r = only(report.results)
        @test r.path == EX("age")
        @test r.value == Literal(30)
    end

    @testset "sh:closed without ignoredProperties flags rdf:type" begin
        shapes = _shacl_ttl(raw"""
        ex:ClosedShape a sh:NodeShape ;
            sh:targetNode ex:x ;
            sh:closed true ;
            sh:property [ sh:path ex:name ] .
        """)
        data = _shacl_ttl(raw"""ex:x a ex:Thing ; ex:name "X" .""")
        report = shacl_validate(data, shapes)
        @test !report.conforms
        @test any(r -> r.path == RDF.type, report.results)
    end

    # ─── Property paths ──────────────────────────────────────────────

    @testset "sequence path" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [
                sh:path ( ex:knows ex:name ) ;
                sh:minCount 1
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:knows ex:bob .
        ex:bob ex:name "Bob" .
        """)
        @test shacl_validate(data, shapes).conforms

        # bob has no name => no values via the sequence path
        data2 = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:knows ex:bob .
        """)
        @test !shacl_validate(data2, shapes).conforms
    end

    @testset "inverse path" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetNode ex:bob ;
            sh:property [
                sh:path [ sh:inversePath ex:knows ] ;
                sh:minCount 1
            ] .
        """)
        data = _shacl_ttl(raw"""ex:alice ex:knows ex:bob .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:bob ex:knows ex:alice .""")
        @test !shacl_validate(data2, shapes).conforms
    end

    @testset "alternative path" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [
                sh:path [ sh:alternativePath ( ex:firstName ex:givenName ) ] ;
                sh:minCount 1
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:a a ex:Person ; ex:firstName "Alice" .
        ex:b a ex:Person ; ex:givenName "Bob" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:c a ex:Person ; ex:surname "Carol" .""")
        @test !shacl_validate(data2, shapes).conforms
    end

    @testset "zeroOrMorePath" begin
        # everyone reachable via knows* (including the focus node) must be a Person
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetNode ex:alice ;
            sh:property [
                sh:path [ sh:zeroOrMorePath ex:knows ] ;
                sh:class ex:Person
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:knows ex:bob .
        ex:bob a ex:Person ; ex:knows ex:carol .
        ex:carol a ex:Person .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:knows ex:bob .
        ex:bob a ex:Person ; ex:knows ex:robot .
        ex:robot a ex:Machine .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> r.value == EX("robot"), report.results)
    end

    @testset "zeroOrMorePath terminates on cycles" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetNode ex:a ;
            sh:property [
                sh:path [ sh:zeroOrMorePath ex:next ] ;
                sh:nodeKind sh:IRI
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:a ex:next ex:b . ex:b ex:next ex:a .
        """)
        @test shacl_validate(data, shapes).conforms
    end

    @testset "oneOrMorePath" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [
                sh:path [ sh:oneOrMorePath ex:knows ] ;
                sh:minCount 1
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:knows ex:bob .
        """)
        # bob is also reached via knows+ from alice, but bob is not a Person target
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:loner a ex:Person .""")
        @test !shacl_validate(data2, shapes).conforms
    end

    @testset "zeroOrOnePath" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetNode ex:alice ;
            sh:property [
                sh:path [ sh:zeroOrOnePath ex:spouse ] ;
                sh:nodeKind sh:IRI
            ] .
        """)
        # values = {alice} ∪ {direct spouse values}; all IRIs => conforms
        data = _shacl_ttl(raw"""ex:alice ex:spouse ex:bob .""")
        @test shacl_validate(data, shapes).conforms

        # a literal spouse value violates nodeKind (focus itself is an IRI)
        data2 = _shacl_ttl(raw"""ex:alice ex:spouse "bob" .""")
        @test !shacl_validate(data2, shapes).conforms
    end

    @testset "nested complex path (inverse of sequence)" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetNode ex:bobName ;
            sh:property [
                sh:path [ sh:inversePath ( ex:knows ex:name ) ] ;
                sh:minCount 1
            ] .
        """)
        # alice -knows-> bob -name-> bobName ; inverse sequence from the
        # name leads back to alice
        data = SGraph()
        add!(data, Triple(EX("alice"), EX("knows"), EX("bob")))
        add!(data, Triple(EX("bob"), EX("name"), EX("bobName")))
        @test shacl_validate(data, shapes).conforms

        data2 = SGraph()
        add!(data2, Triple(EX("bob"), EX("name"), EX("bobName")))
        @test !shacl_validate(data2, shapes).conforms
    end

    # ─── Property-pair constraints ───────────────────────────────────

    @testset "sh:equals" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [ sh:path ex:firstName ; sh:equals ex:givenName ] .
        """)
        data = _shacl_ttl(raw"""
        ex:a a ex:Person ; ex:firstName "Alice" ; ex:givenName "Alice" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""
        ex:b a ex:Person ; ex:firstName "Bob" ; ex:givenName "Robert" .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test length(report.results) == 2  # both directions of the set difference

        # missing on one side also violates
        data3 = _shacl_ttl(raw"""ex:c a ex:Person ; ex:givenName "Carol" .""")
        @test !shacl_validate(data3, shapes).conforms
    end

    @testset "sh:disjoint" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [ sh:path ex:nickname ; sh:disjoint ex:name ] .
        """)
        data = _shacl_ttl(raw"""
        ex:a a ex:Person ; ex:name "Alice" ; ex:nickname "Ali" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""
        ex:b a ex:Person ; ex:name "Bob" ; ex:nickname "Bob" .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> r.value == Literal("Bob"), report.results)
    end

    @testset "sh:lessThan" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Event ;
            sh:property [ sh:path ex:start ; sh:lessThan ex:end ] .
        """)
        data = _shacl_ttl(raw"""ex:e a ex:Event ; ex:start 1 ; ex:end 5 .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:e a ex:Event ; ex:start 5 ; ex:end 5 .""")
        @test !shacl_validate(data2, shapes).conforms

        data3 = _shacl_ttl(raw"""ex:e a ex:Event ; ex:start 9 ; ex:end 5 .""")
        @test !shacl_validate(data3, shapes).conforms

        # incomparable values are violations
        data4 = _shacl_ttl(raw"""ex:e a ex:Event ; ex:start 1 ; ex:end ex:thing .""")
        @test !shacl_validate(data4, shapes).conforms
    end

    @testset "sh:lessThanOrEquals" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Event ;
            sh:property [ sh:path ex:start ; sh:lessThanOrEquals ex:end ] .
        """)
        data = _shacl_ttl(raw"""ex:e a ex:Event ; ex:start 5 ; ex:end 5 .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:e a ex:Event ; ex:start 6 ; ex:end 5 .""")
        @test !shacl_validate(data2, shapes).conforms
    end

    # ─── Language constraints ────────────────────────────────────────

    @testset "sh:languageIn" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Country ;
            sh:property [ sh:path ex:label ; sh:languageIn ( "en" "fr" ) ] .
        """)
        data = _shacl_ttl(raw"""
        ex:fr a ex:Country ; ex:label "France"@en, "La France"@fr .
        """)
        @test shacl_validate(data, shapes).conforms

        # extended language ranges match: en-GB matches "en"
        data_gb = _shacl_ttl(raw"""
        ex:uk a ex:Country ; ex:label "United Kingdom"@en-GB .
        """)
        @test shacl_validate(data_gb, shapes).conforms

        # wrong language
        data2 = _shacl_ttl(raw"""
        ex:de a ex:Country ; ex:label "Deutschland"@de .
        """)
        @test !shacl_validate(data2, shapes).conforms

        # plain literal without language tag
        data3 = _shacl_ttl(raw"""
        ex:us a ex:Country ; ex:label "USA" .
        """)
        @test !shacl_validate(data3, shapes).conforms
    end

    @testset "sh:uniqueLang" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Country ;
            sh:property [ sh:path ex:label ; sh:uniqueLang true ] .
        """)
        data = _shacl_ttl(raw"""
        ex:fr a ex:Country ; ex:label "France"@en, "La France"@fr .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""
        ex:fr a ex:Country ; ex:label "France"@en, "Frenchland"@en .
        """)
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> occursin("en", r.message), report.results)
    end

    # ─── Targets ─────────────────────────────────────────────────────

    @testset "sh:targetSubjectsOf" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetSubjectsOf ex:knows ;
            sh:property [ sh:path ex:name ; sh:minCount 1 ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice ex:knows ex:bob ; ex:name "Alice" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:alice ex:knows ex:bob .""")
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("alice"), report.results)
        # bob is not a subject of ex:knows, so not a target
        @test !any(r -> r.focus_node == EX("bob"), report.results)
    end

    @testset "sh:targetObjectsOf" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetObjectsOf ex:knows ;
            sh:property [ sh:path ex:name ; sh:minCount 1 ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice ex:knows ex:bob .
        ex:bob ex:name "Bob" .
        """)
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:alice ex:knows ex:bob .""")
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("bob"), report.results)
    end

    @testset "sh:targetClass with rdfs:subClassOf closure" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Agent ;
            sh:property [ sh:path ex:name ; sh:minCount 1 ] .
        """)
        data = _shacl_ttl(raw"""
        ex:Person rdfs:subClassOf ex:Agent .
        ex:alice a ex:Person .
        """)
        report = shacl_validate(data, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("alice"), report.results)
    end

    @testset "implicit class target" begin
        shapes = _shacl_ttl(raw"""
        ex:Person a rdfs:Class, sh:NodeShape ;
            sh:property [ sh:path ex:name ; sh:minCount 1 ] .
        """)
        data = _shacl_ttl(raw"""ex:alice a ex:Person .""")
        report = shacl_validate(data, shapes)
        @test !report.conforms
        @test any(r -> r.focus_node == EX("alice"), report.results)
    end

    # ─── Severity and message ────────────────────────────────────────

    @testset "sh:severity and sh:message" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [
                sh:path ex:name ;
                sh:minCount 1 ;
                sh:severity sh:Warning ;
                sh:message "Person should have a name"
            ] .
        """)
        data = _shacl_ttl(raw"""ex:alice a ex:Person .""")
        report = shacl_validate(data, shapes)
        @test !report.conforms
        r = only(report.results)
        @test r.severity == SH.Warning
        @test r.message == "Person should have a name"
    end

    # ─── sh:deactivated ──────────────────────────────────────────────

    @testset "sh:deactivated" begin
        shapes = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:deactivated true ;
            sh:targetClass ex:Person ;
            sh:property [ sh:path ex:name ; sh:minCount 1 ] .
        """)
        data = _shacl_ttl(raw"""ex:alice a ex:Person .""")
        @test shacl_validate(data, shapes).conforms

        # deactivated property shape inside an active node shape
        shapes2 = _shacl_ttl(raw"""
        ex:Shape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [ sh:path ex:name ; sh:minCount 1 ; sh:deactivated true ] .
        """)
        @test shacl_validate(data, shapes2).conforms
    end

    # ─── Recursion safety ────────────────────────────────────────────

    @testset "cyclic shape references terminate" begin
        shapes = _shacl_ttl(raw"""
        ex:PersonShape a sh:NodeShape ;
            sh:targetClass ex:Person ;
            sh:property [
                sh:path ex:friend ;
                sh:node ex:PersonShape
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:alice a ex:Person ; ex:friend ex:bob .
        ex:bob a ex:Person ; ex:friend ex:alice .
        """)
        report = shacl_validate(data, shapes)
        @test report isa ValidationReport
        @test report.conforms
    end

    @testset "self-referential sh:not terminates" begin
        shapes = _shacl_ttl(raw"""
        ex:Paradox a sh:NodeShape ;
            sh:targetNode ex:x ;
            sh:not ex:Paradox .
        """)
        data = _shacl_ttl(raw"""ex:x ex:p 1 .""")
        # Must terminate; cycles are treated as conforming, so sh:not fires.
        report = shacl_validate(data, shapes)
        @test report isa ValidationReport
        @test !report.conforms
    end

    # ─── SPARQL-based constraints ────────────────────────────────────

    @testset "sh:sparql basic" begin
        shapes = _shacl_ttl(raw"""
        ex:CostShape a sh:NodeShape ;
            sh:targetClass ex:Product ;
            sh:sparql [
                sh:message "Cost must not exceed 100" ;
                sh:prefixes [
                    sh:declare [
                        sh:prefix "ex" ;
                        sh:namespace "http://example.org/"^^xsd:anyURI
                    ]
                ] ;
                sh:select "SELECT $this ?value WHERE { $this ex:cost ?value . FILTER (?value > 100) }"
            ] .
        """)
        data = _shacl_ttl(raw"""ex:cheap a ex:Product ; ex:cost 50 .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:pricey a ex:Product ; ex:cost 500 .""")
        report = shacl_validate(data2, shapes)
        @test !report.conforms
        r = only(report.results)
        @test r.focus_node == EX("pricey")
        @test r.value == Literal(500)
        @test r.message == "Cost must not exceed 100"
    end

    @testset "sh:sparql only flags the focus node" begin
        shapes = _shacl_ttl(raw"""
        ex:CostShape a sh:NodeShape ;
            sh:targetClass ex:Product ;
            sh:sparql [
                sh:prefixes [
                    sh:declare [
                        sh:prefix "ex" ;
                        sh:namespace "http://example.org/"^^xsd:anyURI
                    ]
                ] ;
                sh:select "SELECT $this ?value WHERE { $this ex:cost ?value . FILTER (?value > 100) }"
            ] .
        """)
        data = _shacl_ttl(raw"""
        ex:cheap a ex:Product ; ex:cost 50 .
        ex:pricey a ex:Product ; ex:cost 500 .
        """)
        report = shacl_validate(data, shapes)
        @test !report.conforms
        @test all(r -> r.focus_node == EX("pricey"), report.results)
        @test any(r -> r.message == "SPARQL constraint violated", report.results)
    end

    # ─── Inline shapes referencing named property shapes ─────────────

    @testset "standalone property shape with target" begin
        shapes = _shacl_ttl(raw"""
        ex:NamePropShape a sh:PropertyShape ;
            sh:targetClass ex:Person ;
            sh:path ex:name ;
            sh:minCount 1 .
        """)
        data = _shacl_ttl(raw"""ex:alice a ex:Person ; ex:name "Alice" .""")
        @test shacl_validate(data, shapes).conforms

        data2 = _shacl_ttl(raw"""ex:bob a ex:Person .""")
        @test !shacl_validate(data2, shapes).conforms
    end
end
