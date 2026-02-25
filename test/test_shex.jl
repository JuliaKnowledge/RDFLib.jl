@testset "ShEx Validation" begin
    EX = Namespace("http://example.org/")
    XSD_STR = URIRef("http://www.w3.org/2001/XMLSchema#string")
    XSD_INT = URIRef("http://www.w3.org/2001/XMLSchema#integer")
    XSD_DEC = URIRef("http://www.w3.org/2001/XMLSchema#decimal")

    @testset "Simple NodeConstraint — datatype xsd:string" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:NameShape xsd:string
        """)
        @test haskey(schema.shapes, EX("NameShape"))

        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))

        # Validate the literal object directly
        report = validate_shex(g, schema,
            [(Literal("Alice", datatype=XSD_STR), EX("NameShape"))])
        @test report.conforms

        # Non-matching datatype
        report2 = validate_shex(g, schema,
            [(Literal("42", datatype=XSD_INT), EX("NameShape"))])
        @test !report2.conforms
    end

    @testset "TripleConstraint with cardinality" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:PersonShape {
                ex:name xsd:string {1,3}
            }
        """)

        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        report = validate_shex(g, schema, [(EX("alice"), EX("PersonShape"))])
        @test report.conforms

        # Too many names
        g2 = RDFGraph()
        for n in ["A", "B", "C", "D"]
            add!(g2, Triple(EX("bob"), EX("name"), Literal(n, datatype=XSD_STR)))
        end
        report2 = validate_shex(g2, schema, [(EX("bob"), EX("PersonShape"))])
        @test !report2.conforms

        # Zero names (below min)
        g3 = RDFGraph()
        add!(g3, Triple(EX("carol"), EX("age"), Literal("30", datatype=XSD_INT)))
        report3 = validate_shex(g3, schema, [(EX("carol"), EX("PersonShape"))])
        @test !report3.conforms
    end

    @testset "Shape with multiple triple constraints" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:PersonShape {
                ex:name xsd:string ;
                ex:age xsd:integer
            }
        """)

        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g, Triple(EX("alice"), EX("age"), Literal("30", datatype=XSD_INT)))
        report = validate_shex(g, schema, [(EX("alice"), EX("PersonShape"))])
        @test report.conforms

        # Missing age
        g2 = RDFGraph()
        add!(g2, Triple(EX("bob"), EX("name"), Literal("Bob", datatype=XSD_STR)))
        report2 = validate_shex(g2, schema, [(EX("bob"), EX("PersonShape"))])
        @test !report2.conforms
    end

    @testset "Value set constraints" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            ex:StatusShape {
                ex:status [ex:active ex:inactive ex:pending]
            }
        """)

        g = RDFGraph()
        add!(g, Triple(EX("item1"), EX("status"), EX("active")))
        report = validate_shex(g, schema, [(EX("item1"), EX("StatusShape"))])
        @test report.conforms

        g2 = RDFGraph()
        add!(g2, Triple(EX("item2"), EX("status"), EX("deleted")))
        report2 = validate_shex(g2, schema, [(EX("item2"), EX("StatusShape"))])
        @test !report2.conforms
    end

    @testset "Nested shapes (ShapeRef)" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:PersonShape {
                ex:name xsd:string ;
                ex:address @ex:AddressShape
            }
            ex:AddressShape {
                ex:street xsd:string ;
                ex:city xsd:string
            }
        """)

        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g, Triple(EX("alice"), EX("address"), EX("addr1")))
        add!(g, Triple(EX("addr1"), EX("street"), Literal("123 Main St", datatype=XSD_STR)))
        add!(g, Triple(EX("addr1"), EX("city"), Literal("Springfield", datatype=XSD_STR)))

        report = validate_shex(g, schema, [(EX("alice"), EX("PersonShape"))])
        @test report.conforms

        # Missing city in address
        g2 = RDFGraph()
        add!(g2, Triple(EX("bob"), EX("name"), Literal("Bob", datatype=XSD_STR)))
        add!(g2, Triple(EX("bob"), EX("address"), EX("addr2")))
        add!(g2, Triple(EX("addr2"), EX("street"), Literal("456 Oak Ave", datatype=XSD_STR)))
        report2 = validate_shex(g2, schema, [(EX("bob"), EX("PersonShape"))])
        @test !report2.conforms
    end

    @testset "AND shape expressions" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:NamedPersonShape {
                ex:name xsd:string
            }
            ex:AgedPersonShape {
                ex:age xsd:integer
            }
            ex:FullPersonShape @ex:NamedPersonShape AND @ex:AgedPersonShape
        """)

        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g, Triple(EX("alice"), EX("age"), Literal("30", datatype=XSD_INT)))
        report = validate_shex(g, schema, [(EX("alice"), EX("FullPersonShape"))])
        @test report.conforms

        # Missing age — fails AgedPersonShape
        g2 = RDFGraph()
        add!(g2, Triple(EX("bob"), EX("name"), Literal("Bob", datatype=XSD_STR)))
        report2 = validate_shex(g2, schema, [(EX("bob"), EX("FullPersonShape"))])
        @test !report2.conforms
    end

    @testset "OR shape expressions" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:StringShape xsd:string
            ex:IntShape xsd:integer
            ex:StringOrIntShape @ex:StringShape OR @ex:IntShape
        """)

        report1 = validate_shex(RDFGraph(), schema,
            [(Literal("hello", datatype=XSD_STR), EX("StringOrIntShape"))])
        @test report1.conforms

        report2 = validate_shex(RDFGraph(), schema,
            [(Literal("42", datatype=XSD_INT), EX("StringOrIntShape"))])
        @test report2.conforms

        report3 = validate_shex(RDFGraph(), schema,
            [(Literal("3.14", datatype=XSD_DEC), EX("StringOrIntShape"))])
        @test !report3.conforms
    end

    @testset "NOT shape expression" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:NotIntShape NOT xsd:integer
        """)

        report1 = validate_shex(RDFGraph(), schema,
            [(Literal("hello", datatype=XSD_STR), EX("NotIntShape"))])
        @test report1.conforms

        report2 = validate_shex(RDFGraph(), schema,
            [(Literal("42", datatype=XSD_INT), EX("NotIntShape"))])
        @test !report2.conforms
    end

    @testset "Optional (?) constraint" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:PersonShape {
                ex:name xsd:string ;
                ex:nickname xsd:string ?
            }
        """)

        # With nickname
        g1 = RDFGraph()
        add!(g1, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g1, Triple(EX("alice"), EX("nickname"), Literal("Ali", datatype=XSD_STR)))
        report1 = validate_shex(g1, schema, [(EX("alice"), EX("PersonShape"))])
        @test report1.conforms

        # Without nickname — should still pass
        g2 = RDFGraph()
        add!(g2, Triple(EX("bob"), EX("name"), Literal("Bob", datatype=XSD_STR)))
        report2 = validate_shex(g2, schema, [(EX("bob"), EX("PersonShape"))])
        @test report2.conforms
    end

    @testset "Repeating (* and +) constraints" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:PersonShape {
                ex:name xsd:string ;
                ex:email xsd:string + ;
                ex:hobby xsd:string *
            }
        """)

        # Has name and one email, no hobbies
        g1 = RDFGraph()
        add!(g1, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g1, Triple(EX("alice"), EX("email"), Literal("alice@example.org", datatype=XSD_STR)))
        report1 = validate_shex(g1, schema, [(EX("alice"), EX("PersonShape"))])
        @test report1.conforms

        # Has name and multiple emails and hobbies
        g2 = RDFGraph()
        add!(g2, Triple(EX("bob"), EX("name"), Literal("Bob", datatype=XSD_STR)))
        add!(g2, Triple(EX("bob"), EX("email"), Literal("bob@a.com", datatype=XSD_STR)))
        add!(g2, Triple(EX("bob"), EX("email"), Literal("bob@b.com", datatype=XSD_STR)))
        add!(g2, Triple(EX("bob"), EX("hobby"), Literal("chess", datatype=XSD_STR)))
        report2 = validate_shex(g2, schema, [(EX("bob"), EX("PersonShape"))])
        @test report2.conforms

        # Missing email (+ requires at least 1) — should fail
        g3 = RDFGraph()
        add!(g3, Triple(EX("carol"), EX("name"), Literal("Carol", datatype=XSD_STR)))
        report3 = validate_shex(g3, schema, [(EX("carol"), EX("PersonShape"))])
        @test !report3.conforms
    end

    @testset "Failing validations — detailed checks" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:PersonShape {
                ex:name xsd:string ;
                ex:age xsd:integer
            }
        """)

        # Wrong datatype for age
        g = RDFGraph()
        add!(g, Triple(EX("alice"), EX("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g, Triple(EX("alice"), EX("age"), Literal("thirty", datatype=XSD_STR)))
        report = validate_shex(g, schema, [(EX("alice"), EX("PersonShape"))])
        @test !report.conforms
        @test length(report.results) == 1
        @test report.results[1].status == :fail

        # Non-existent shape
        report2 = validate_shex(g, schema, [(EX("alice"), EX("NonExistentShape"))])
        @test !report2.conforms
        @test occursin("not found", report2.results[1].reason)
    end

    @testset "Schema with prefix parsing" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            PREFIX foaf: <http://xmlns.com/foaf/0.1/>

            ex:PersonShape {
                foaf:name xsd:string ;
                foaf:mbox IRI ?
            }
        """)
        @test haskey(schema.shapes, EX("PersonShape"))
        @test schema.prefixes["foaf"] == "http://xmlns.com/foaf/0.1/"

        g = RDFGraph()
        foaf = Namespace("http://xmlns.com/foaf/0.1/")
        add!(g, Triple(EX("alice"), foaf("name"), Literal("Alice", datatype=XSD_STR)))
        add!(g, Triple(EX("alice"), foaf("mbox"), URIRef("mailto:alice@example.org")))
        report = validate_shex(g, schema, [(EX("alice"), EX("PersonShape"))])
        @test report.conforms
    end

    @testset "NodeConstraint — IRI node kind" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            ex:IRIShape IRI
        """)

        report1 = validate_shex(RDFGraph(), schema,
            [(URIRef("http://example.org/x"), EX("IRIShape"))])
        @test report1.conforms

        report2 = validate_shex(RDFGraph(), schema,
            [(Literal("hello"), EX("IRIShape"))])
        @test !report2.conforms
    end

    @testset "NodeConstraint — string facets" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:ShortStringShape xsd:string MinLength 2 MaxLength 10
        """)

        report1 = validate_shex(RDFGraph(), schema,
            [(Literal("hello", datatype=XSD_STR), EX("ShortStringShape"))])
        @test report1.conforms

        # Too short
        report2 = validate_shex(RDFGraph(), schema,
            [(Literal("a", datatype=XSD_STR), EX("ShortStringShape"))])
        @test !report2.conforms

        # Too long
        report3 = validate_shex(RDFGraph(), schema,
            [(Literal("abcdefghijk", datatype=XSD_STR), EX("ShortStringShape"))])
        @test !report3.conforms
    end

    @testset "Empty shape" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            ex:AnyShape {}
        """)

        g = RDFGraph()
        add!(g, Triple(EX("x"), EX("p"), Literal("v")))
        report = validate_shex(g, schema, [(EX("x"), EX("AnyShape"))])
        @test report.conforms
    end

    @testset "ShExValidationReport structure" begin
        schema = parse_shex("""
            PREFIX ex: <http://example.org/>
            PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
            ex:S { ex:p xsd:string }
        """)

        g = RDFGraph()
        add!(g, Triple(EX("x"), EX("p"), Literal("hello", datatype=XSD_STR)))
        report = validate_shex(g, schema, [(EX("x"), EX("S"))])

        @test report isa ShExValidationReport
        @test report.conforms == true
        @test length(report.results) == 1
        @test report.results[1].node == EX("x")
        @test report.results[1].shape == EX("S")
        @test report.results[1].status == :pass
    end
end
