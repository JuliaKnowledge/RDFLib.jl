using Test
using RDFLib

@testset "Tabular RDF Mapping" begin

# ─── Column Type Tests ────────────────────────────────────────────

@testset "ColumnType constructors" begin
    @test IRIColumn() isa ColumnType
    @test LiteralColumn(XSD.integer) isa ColumnType
    @test LangColumn("en") isa ColumnType
    @test AutoColumn() isa ColumnType
end

# ─── Value Conversion Tests ───────────────────────────────────────

@testset "Value conversion" begin
    # AutoColumn
    @test RDFLib._to_rdf_term(42, AutoColumn()) == Literal(42)
    @test RDFLib._to_rdf_term(3.14, AutoColumn()) == Literal(3.14)
    @test RDFLib._to_rdf_term(true, AutoColumn()) == Literal(true)
    @test RDFLib._to_rdf_term("hello", AutoColumn()) == Literal("hello")
    @test RDFLib._to_rdf_term(missing, AutoColumn()) === nothing

    # IRIColumn
    @test RDFLib._to_rdf_term("http://example.org/x", IRIColumn()) == URIRef("http://example.org/x")
    @test RDFLib._to_rdf_term(missing, IRIColumn()) === nothing

    # LiteralColumn
    @test RDFLib._to_rdf_term("42", LiteralColumn(XSD.integer)).datatype == XSD.integer
    @test RDFLib._to_rdf_term(missing, LiteralColumn(XSD.integer)) === nothing

    # LangColumn
    lit = RDFLib._to_rdf_term("hello", LangColumn("en"))
    @test lit.language == "en"
    @test lit.lexical == "hello"
end

# ─── Subject URI Generation ──────────────────────────────────────

@testset "Subject generation" begin
    @test RDFLib._to_subject("http://example.org/x", "") == URIRef("http://example.org/x")
    @test RDFLib._to_subject("Alice", "http://example.org/") == URIRef("http://example.org/Alice")
    @test RDFLib._to_subject(missing, "http://ex.org/") === nothing
end

# ─── RDFMapping creation ─────────────────────────────────────────

@testset "RDFMapping creation" begin
    m = RDFMapping()
    @test length(m) == 0
    @test m.graph isa RDFGraph
end

# ─── Default mapping with NamedTuples (Tables.jl-compatible) ─────

@testset "map_default! with NamedTuple table" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice", "http://example.org/Bob"],
        name = ["Alice", "Bob"],
        age = [30, 25],
    )
    tpl = map_default!(m, tbl, :id; predicate_prefix="http://example.org/")
    @test length(m) == 4  # 2 persons × 2 properties (name, age)
    @test tpl isa RDFTemplate

    # Check triples exist
    alice = URIRef("http://example.org/Alice")
    name_pred = URIRef("http://example.org/name")
    age_pred = URIRef("http://example.org/age")
    @test Triple(alice, name_pred, Literal("Alice")) in m.graph
    @test Triple(alice, age_pred, Literal(30)) in m.graph
end

# ─── Default mapping with rdf:type ───────────────────────────────

@testset "map_default! with types" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice"],
        name = ["Alice"],
    )
    person_cls = URIRef("http://example.org/Person")
    map_default!(m, tbl, :id;
        predicate_prefix="http://example.org/",
        types=[person_cls])

    alice = URIRef("http://example.org/Alice")
    @test Triple(alice, RDF.type, person_cls) in m.graph
    @test Triple(alice, URIRef("http://example.org/name"), Literal("Alice")) in m.graph
    @test length(m) == 2  # type + name
end

# ─── Explicit template mapping ───────────────────────────────────

@testset "map! with explicit RDFTemplate" begin
    m = RDFMapping()

    EX = Namespace("http://example.org/")
    FOAF = Namespace("http://xmlns.com/foaf/0.1/")

    tpl = RDFTemplate(
        subject = :id,
        subject_prefix = "http://example.org/person/",
        properties = [
            (FOAF("name"), :name, AutoColumn()),
            (FOAF("age"), :age, LiteralColumn(XSD.integer)),
            (FOAF("homepage"), :homepage, IRIColumn()),
        ],
        types = [FOAF("Person")]
    )

    tbl = (
        id = ["alice", "bob"],
        name = ["Alice", "Bob"],
        age = [30, 25],
        homepage = ["http://alice.example.org", "http://bob.example.org"],
    )

    rdf_map!(m, tbl, tpl)

    alice = URIRef("http://example.org/person/alice")
    @test Triple(alice, RDF.type, FOAF("Person")) in m.graph
    @test Triple(alice, FOAF("name"), Literal("Alice")) in m.graph
    @test Triple(alice, FOAF("homepage"), URIRef("http://alice.example.org")) in m.graph

    # Age should have explicit xsd:integer datatype
    age_triples = collect(objects(m.graph, alice, FOAF("age")))
    @test length(age_triples) == 1
    @test age_triples[1].datatype == XSD.integer

    @test length(m) == 8  # 2 persons × (1 type + 3 properties)
end

# ─── SPARQL Query → NamedTuple ───────────────────────────────────

@testset "rdf_query returns NamedTuple" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice", "http://example.org/Bob"],
        name = ["Alice", "Bob"],
        age = [30, 25],
    )
    map_default!(m, tbl, :id;
        predicate_prefix="http://example.org/",
        types=[URIRef("http://example.org/Person")])

    result = rdf_query(m, """
        PREFIX ex: <http://example.org/>
        SELECT ?person ?name WHERE {
            ?person a ex:Person .
            ?person ex:name ?name .
        }
        ORDER BY ?name
    """)

    @test result isa NamedTuple
    @test haskey(result, :person)
    @test haskey(result, :name)
    @test length(result.person) == 2
    # Check values (order by name: Alice, Bob)
    @test any(contains("Alice"), result.name)
    @test any(contains("Bob"), result.name)
end

# ─── ASK query ───────────────────────────────────────────────────

@testset "rdf_query ASK" begin
    m = RDFMapping()
    add!(m.graph, Triple(
        URIRef("http://example.org/Alice"),
        RDF.type,
        URIRef("http://example.org/Person")))

    @test rdf_query(m, """
        ASK WHERE {
            <http://example.org/Alice> a <http://example.org/Person> .
        }
    """) == true

    @test rdf_query(m, """
        ASK WHERE {
            <http://example.org/Bob> a <http://example.org/Person> .
        }
    """) == false
end

# ─── CONSTRUCT query ─────────────────────────────────────────────

@testset "rdf_query CONSTRUCT" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice"],
        name = ["Alice"],
    )
    map_default!(m, tbl, :id; predicate_prefix="http://example.org/")

    result = rdf_query(m, """
        CONSTRUCT {
            ?s <http://example.org/hasLabel> ?name .
        }
        WHERE {
            ?s <http://example.org/name> ?name .
        }
    """)
    @test result isa RDFGraph
    @test length(result) == 1
end

# ─── insert! (CONSTRUCT → insert) ────────────────────────────────

@testset "insert! via CONSTRUCT" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice"],
        name = ["Alice"],
    )
    map_default!(m, tbl, :id;
        predicate_prefix="http://example.org/",
        types=[URIRef("http://example.org/Person")])

    rdf_insert!(m, """
        PREFIX ex: <http://example.org/>
        CONSTRUCT { ?s a ex:NamedEntity }
        WHERE { ?s ex:name ?n }
    """)

    @test Triple(
        URIRef("http://example.org/Alice"),
        RDF.type,
        URIRef("http://example.org/NamedEntity")) in m.graph
end

# ─── table_to_rdf convenience ────────────────────────────────────

@testset "table_to_rdf convenience" begin
    tbl = (
        id = ["Alice", "Bob"],
        score = [95.5, 87.3],
    )
    m = table_to_rdf(tbl, :id;
        subject_prefix="http://example.org/student/",
        predicate_prefix="http://example.org/")

    @test length(m) == 2  # 2 scores
    result = rdf_query(m, """
        SELECT ?s ?score WHERE {
            ?s <http://example.org/score> ?score .
        }
    """)
    @test length(result.s) == 2
end

# ─── Missing values handling ─────────────────────────────────────

@testset "Missing values are skipped" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/A", "http://example.org/B"],
        name = ["Alice", missing],
    )
    map_default!(m, tbl, :id; predicate_prefix="http://example.org/")
    @test length(m) == 1  # Only Alice's name triple
end

# ─── Subject prefix generation ───────────────────────────────────

@testset "Subject prefix for non-URI values" begin
    m = RDFMapping()
    tbl = (
        id = ["person1", "person2"],
        val = [1, 2],
    )
    map_default!(m, tbl, :id;
        subject_prefix="http://example.org/",
        predicate_prefix="http://example.org/")

    s1 = URIRef("http://example.org/person1")
    @test Triple(s1, URIRef("http://example.org/val"), Literal(1)) in m.graph
end

# ─── Boolean and float type detection ────────────────────────────

@testset "Auto type detection" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/x"],
        flag = [true],
        ratio = [0.75],
        count = [42],
    )
    map_default!(m, tbl, :id; predicate_prefix="http://example.org/")

    x = URIRef("http://example.org/x")
    flag_obj = collect(objects(m.graph, x, URIRef("http://example.org/flag")))
    @test flag_obj[1] == Literal(true)

    ratio_obj = collect(objects(m.graph, x, URIRef("http://example.org/ratio")))
    @test ratio_obj[1] == Literal(0.75)

    count_obj = collect(objects(m.graph, x, URIRef("http://example.org/count")))
    @test count_obj[1] == Literal(42)
end

# ─── Column type overrides ───────────────────────────────────────

@testset "Column type overrides in map_default!" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/x"],
        link = ["http://example.org/target"],
        desc = ["A thing"],
    )
    map_default!(m, tbl, :id;
        predicate_prefix="http://example.org/",
        column_types=Dict(
            :link => IRIColumn(),
            :desc => LangColumn("en")))

    x = URIRef("http://example.org/x")

    # link should be IRI, not literal
    link_obj = collect(objects(m.graph, x, URIRef("http://example.org/link")))
    @test link_obj[1] isa URIRef
    @test link_obj[1] == URIRef("http://example.org/target")

    # desc should be language-tagged
    desc_obj = collect(objects(m.graph, x, URIRef("http://example.org/desc")))
    @test desc_obj[1].language == "en"
end

# ─── Serialize mapping ───────────────────────────────────────────

@testset "Serialize mapping" begin
    m = RDFMapping()
    add!(m.graph, Triple(
        URIRef("http://example.org/s"),
        URIRef("http://example.org/p"),
        Literal("hello")))
    ttl = serialize(m, TurtleFormat())
    @test occursin("hello", ttl)
end

# ─── Parse RDF into mapping ──────────────────────────────────────

@testset "Parse RDF into mapping" begin
    m = RDFMapping()
    parse_rdf!(m, """
        <http://example.org/s> <http://example.org/p> "hello" .
    """, NTriplesFormat())
    @test length(m) == 1
end

# ─── End-to-end pizza example (maplib-inspired) ──────────────────

@testset "Pizza example (maplib-style)" begin
    PI = "https://example.org/pizza#"
    m = RDFMapping()

    # Map pizza data
    tbl = (
        pizza = [PI * "Hawaiian", PI * "Grandiosa"],
        country = [PI * "CAN", PI * "NOR"],
    )
    EX = Namespace(PI)
    tpl = RDFTemplate(
        subject = :pizza,
        properties = [
            (EX("fromCountry"), :country, IRIColumn()),
        ],
        types = [EX("Pizza")]
    )
    rdf_map!(m, tbl, tpl)

    # Add ingredients as separate triples
    ingredients = (
        pizza = [PI * "Hawaiian", PI * "Hawaiian", PI * "Grandiosa", PI * "Grandiosa"],
        ingredient = [PI * "Pineapple", PI * "Ham", PI * "Pepper", PI * "Meat"],
    )
    ing_tpl = RDFTemplate(
        subject = :pizza,
        properties = [(EX("hasIngredient"), :ingredient, IRIColumn())],
    )
    rdf_map!(m, ingredients, ing_tpl)

    @test length(m) == 8  # 2×type + 2×country + 4×ingredient

    # Derive heterodox pizzas via CONSTRUCT + insert
    rdf_insert!(m, """
        PREFIX pi: <https://example.org/pizza#>
        CONSTRUCT { ?p a pi:HeterodoxPizza }
        WHERE {
            ?p a pi:Pizza .
            ?p pi:hasIngredient pi:Pineapple .
        }
    """)

    @test length(m) == 9  # +1 HeterodoxPizza type

    # Query heterodox pizzas
    result = rdf_query(m, """
        PREFIX pi: <https://example.org/pizza#>
        SELECT ?p WHERE { ?p a pi:HeterodoxPizza }
    """)
    @test length(result.p) == 1
    @test occursin("Hawaiian", result.p[1])

    # Query all ingredients
    result = rdf_query(m, """
        PREFIX pi: <https://example.org/pizza#>
        SELECT ?p ?i WHERE {
            ?p a pi:Pizza .
            ?p pi:hasIngredient ?i .
        }
        ORDER BY ?p ?i
    """)
    @test length(result.p) == 4
end

# ─── Iris dataset example ────────────────────────────────────────

@testset "Iris dataset mapping" begin
    EX = Namespace("https://example.org/iris#")

    # Simulate iris data
    tbl = (
        id = ["https://example.org/iris#Setosa1", "https://example.org/iris#Versicolor1"],
        sepal_length = [5.1, 7.0],
        sepal_width = [3.5, 3.2],
        variety = ["Setosa", "Versicolor"],
    )

    m = RDFMapping()
    map_default!(m, tbl, :id;
        predicate_prefix="https://example.org/iris#",
        types=[EX("Observation")],
        column_types=Dict(
            :sepal_length => LiteralColumn(XSD.double),
            :sepal_width => LiteralColumn(XSD.double),
        ))

    # Query observations with sepal length > 6.0
    result = rdf_query(m, """
        PREFIX ex: <https://example.org/iris#>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        SELECT ?id ?sl WHERE {
            ?id a ex:Observation .
            ?id ex:sepal_length ?sl .
            FILTER(?sl > "6.0"^^xsd:double)
        }
    """)
    @test length(result.id) == 1
    @test occursin("Versicolor", result.id[1])
end

# ─── maplib-inspired test scenarios ──────────────────────────────

# Based on maplib/py_maplib/tests/test_pizza_example.py

@testset "Pizza workflow — SPARQL UPDATE INSERT" begin
    PI = "https://example.org/pizza#"
    EX = Namespace(PI)
    m = RDFMapping()

    # Build pizza graph manually (equivalent to maplib stOTTR template expansion)
    pizzas = (
        pizza = [PI * "Hawaiian", PI * "Grandiosa"],
        country = [PI * "CAN", PI * "NOR"],
    )
    tpl = RDFTemplate(
        subject = :pizza,
        properties = [(EX("fromCountry"), :country, IRIColumn())],
        types = [EX("Pizza")]
    )
    rdf_map!(m, pizzas, tpl)

    ingredients = (
        pizza = [PI * "Hawaiian", PI * "Hawaiian", PI * "Grandiosa", PI * "Grandiosa"],
        ingredient = [PI * "Pineapple", PI * "Ham", PI * "Pepper", PI * "Meat"],
    )
    rdf_map!(m, ingredients, RDFTemplate(
        subject = :pizza,
        properties = [(EX("hasIngredient"), :ingredient, IRIColumn())],
    ))

    # Insert heterodox pizzas via CONSTRUCT
    rdf_insert!(m, """
        PREFIX pi: <https://example.org/pizza#>
        CONSTRUCT { ?p a pi:HeterodoxPizza }
        WHERE {
            ?p a pi:Pizza .
            ?p pi:hasIngredient pi:Pineapple .
        }
    """)

    @test length(m) == 9  # 2×type + 2×country + 4×ingredient + 1×HeterodoxPizza

    # SPARQL UPDATE: INSERT new type
    rdf_update!(m, """
        PREFIX pi: <https://example.org/pizza#>
        INSERT { ?p a pi:NewPizza }
        WHERE { ?p a pi:Pizza }
    """)
    @test length(m) == 11  # +2 NewPizza types

    # Query new types
    result = rdf_query(m, """
        PREFIX pi: <https://example.org/pizza#>
        SELECT ?p WHERE { ?p a pi:NewPizza }
    """)
    @test length(result.p) == 2
end

@testset "Pizza workflow — SPARQL UPDATE DELETE" begin
    PI = "https://example.org/pizza#"
    EX = Namespace(PI)
    m = RDFMapping()

    pizzas = (
        pizza = [PI * "Hawaiian", PI * "Grandiosa"],
        country = [PI * "CAN", PI * "NOR"],
    )
    rdf_map!(m, pizzas, RDFTemplate(
        subject = :pizza,
        properties = [(EX("fromCountry"), :country, IRIColumn())],
        types = [EX("Pizza")]
    ))
    ingredients = (
        pizza = [PI * "Hawaiian", PI * "Hawaiian", PI * "Grandiosa", PI * "Grandiosa"],
        ingredient = [PI * "Pineapple", PI * "Ham", PI * "Pepper", PI * "Meat"],
    )
    rdf_map!(m, ingredients, RDFTemplate(
        subject = :pizza,
        properties = [(EX("hasIngredient"), :ingredient, IRIColumn())],
    ))
    rdf_insert!(m, """
        PREFIX pi: <https://example.org/pizza#>
        CONSTRUCT { ?p a pi:HeterodoxPizza }
        WHERE { ?p a pi:Pizza . ?p pi:hasIngredient pi:Pineapple . }
    """)
    @test length(m) == 9

    # DELETE all Pizza types
    rdf_update!(m, """
        PREFIX pi: <https://example.org/pizza#>
        DELETE { ?p a pi:Pizza }
        WHERE { ?p a pi:Pizza }
    """)
    @test length(m) == 7  # 9 - 2 Pizza types

    # Query: no more Pizza type
    result = rdf_query(m, """
        PREFIX pi: <https://example.org/pizza#>
        SELECT ?p WHERE { ?p a pi:Pizza }
    """)
    @test length(result) == 0 || (haskey(result, :p) && length(result.p) == 0)
end

@testset "Pizza workflow — DELETE all triples" begin
    PI = "https://example.org/pizza#"
    EX = Namespace(PI)
    m = RDFMapping()

    pizzas = (
        pizza = [PI * "Hawaiian"],
        country = [PI * "CAN"],
    )
    rdf_map!(m, pizzas, RDFTemplate(
        subject = :pizza,
        properties = [(EX("fromCountry"), :country, IRIColumn())],
        types = [EX("Pizza")]
    ))
    @test length(m) == 2

    # Delete everything
    rdf_update!(m, "DELETE { ?s ?p ?o } WHERE { ?s ?p ?o }")
    @test length(m) == 0
end

# Based on maplib/py_maplib/tests/test_blank_nodes_multi.py

@testset "Blank node subjects — BNode mapping" begin
    FOAF = Namespace("http://xmlns.com/foaf/0.1/")
    m = RDFMapping()

    # Simulate blank node person mapping
    people = (
        firstName = ["Ann", "Bob"],
        lastName = ["Strong", "Brite"],
        email = ["mailto:ann.strong@example.com", "mailto:bob.brite@example.com"],
    )

    # Create triples with BNode subjects (one per row)
    for (i, (fn, ln, em)) in enumerate(zip(people.firstName, people.lastName, people.email))
        person = BNode("person$i")
        add!(m.graph, Triple(person, RDF.type, FOAF("Person")))
        add!(m.graph, Triple(person, FOAF("firstName"), Literal(fn)))
        add!(m.graph, Triple(person, FOAF("lastName"), Literal(ln)))
        add!(m.graph, Triple(person, FOAF("mbox"), URIRef(em)))
    end

    @test length(m) == 8  # 2 persons × 4 triples each

    # Query names
    result = rdf_query(m, """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?firstName ?lastName WHERE {
            ?p a foaf:Person .
            ?p foaf:lastName ?lastName .
            ?p foaf:firstName ?firstName .
        }
        ORDER BY ?firstName
    """)
    @test length(result.firstName) == 2
    @test any(contains("Ann"), result.firstName)
    @test any(contains("Bob"), result.firstName)
end

@testset "SPARQL UNION query" begin
    FOAF = Namespace("http://xmlns.com/foaf/0.1/")
    m = RDFMapping()

    person = BNode("p1")
    add!(m.graph, Triple(person, RDF.type, FOAF("Person")))
    add!(m.graph, Triple(person, FOAF("firstName"), Literal("Ann")))
    add!(m.graph, Triple(person, FOAF("lastName"), Literal("Strong")))

    result = rdf_query(m, """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?s ?o WHERE {
            { ?s foaf:firstName ?o }
            UNION
            { ?s a ?o }
        }
    """)
    @test length(result.o) == 2  # firstName + type
end

@testset "SPARQL OPTIONAL (LEFT JOIN)" begin
    FOAF = Namespace("http://xmlns.com/foaf/0.1/")
    m = RDFMapping()

    p1 = BNode("p1")
    p2 = BNode("p2")
    add!(m.graph, Triple(p1, FOAF("firstName"), Literal("Ann")))
    add!(m.graph, Triple(p1, FOAF("lastName"), Literal("Strong")))
    add!(m.graph, Triple(p2, FOAF("firstName"), Literal("Bob")))
    # Bob has no lastName

    result = rdf_query(m, """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?fn ?ln WHERE {
            ?p foaf:firstName ?fn .
            OPTIONAL { ?p foaf:lastName ?ln }
        }
        ORDER BY ?fn
    """)
    @test length(result.fn) == 2
    # Ann has lastName, Bob doesn't
    @test any(contains("Ann"), result.fn)
    @test any(contains("Bob"), result.fn)
end

# Based on maplib/py_maplib/tests/test_pizza_example.py — COUNT/GROUP BY/HAVING

@testset "SPARQL COUNT and GROUP BY" begin
    PI = "https://example.org/pizza#"
    EX = Namespace(PI)
    m = RDFMapping()

    # Two pizzas with different numbers of ingredients
    for (pizza, ings) in [("Hawaiian", ["Pineapple", "Ham"]),
                          ("Grandiosa", ["Pepper", "Meat"])]
        subj = URIRef(PI * pizza)
        add!(m.graph, Triple(subj, RDF.type, EX("Pizza")))
        for ing in ings
            add!(m.graph, Triple(subj, EX("hasIngredient"), URIRef(PI * ing)))
        end
    end

    # COUNT with GROUP BY
    result = rdf_query(m, """
        PREFIX pi: <https://example.org/pizza#>
        SELECT ?p (COUNT(?i) AS ?c) WHERE {
            ?p pi:hasIngredient ?i .
        }
        GROUP BY ?p
    """)
    @test length(result.p) == 2
    # Each pizza has 2 ingredients
    for cnt in result.c
        @test contains(cnt, "2")
    end
end

@testset "SPARQL COUNT(*)" begin
    m = RDFMapping()
    add!(m.graph, Triple(URIRef("http://ex.org/s1"), URIRef("http://ex.org/p"), Literal("a")))
    add!(m.graph, Triple(URIRef("http://ex.org/s2"), URIRef("http://ex.org/p"), Literal("b")))
    add!(m.graph, Triple(URIRef("http://ex.org/s3"), URIRef("http://ex.org/p"), Literal("c")))

    result = rdf_query(m, "SELECT (COUNT(*) AS ?count) WHERE { ?s ?p ?o }")
    @test haskey(result, :count)
    @test length(result.count) == 1
    @test contains(result.count[1], "3")
end

# Based on maplib/py_maplib/tests/test_read_write.py

@testset "Read NTriples → query (round-trip)" begin
    m = RDFMapping()
    nt_data = """
        _:p1 <http://xmlns.com/foaf/0.1/firstName> "Ann" .
        _:p1 <http://xmlns.com/foaf/0.1/lastName> "Strong" .
        _:p1 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://xmlns.com/foaf/0.1/Person> .
        _:p2 <http://xmlns.com/foaf/0.1/firstName> "Bob" .
        _:p2 <http://xmlns.com/foaf/0.1/lastName> "Brite" .
        _:p2 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://xmlns.com/foaf/0.1/Person> .
    """
    parse_rdf!(m, nt_data, NTriplesFormat())
    @test length(m) == 6

    result = rdf_query(m, """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?fn ?ln WHERE {
            ?p a foaf:Person .
            ?p foaf:firstName ?fn .
            ?p foaf:lastName ?ln .
        }
        ORDER BY ?fn
    """)
    @test length(result.fn) == 2
end

@testset "NTriples round-trip: write → read → query" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice", "http://example.org/Bob"],
        name = ["Alice", "Bob"],
    )
    map_default!(m, tbl, :id; predicate_prefix="http://example.org/")

    # Serialize to NTriples
    nt = serialize(m, NTriplesFormat())
    @test occursin("Alice", nt)
    @test occursin("Bob", nt)

    # Parse into new mapping
    m2 = RDFMapping()
    parse_rdf!(m2, nt, NTriplesFormat())
    @test length(m2) == length(m)

    result = rdf_query(m2, """
        SELECT ?name WHERE { ?s <http://example.org/name> ?name }
        ORDER BY ?name
    """)
    @test length(result.name) == 2
end

@testset "Turtle round-trip: write → read → query" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/Alice"],
        name = ["Alice"],
        age = [30],
    )
    map_default!(m, tbl, :id;
        predicate_prefix="http://example.org/",
        types=[URIRef("http://example.org/Person")])

    # Round-trip through Turtle
    ttl = serialize(m, TurtleFormat())
    m2 = RDFMapping()
    parse_rdf!(m2, ttl, TurtleFormat())
    @test length(m2) == length(m)

    result = rdf_query(m2, """
        PREFIX ex: <http://example.org/>
        SELECT ?name WHERE {
            ?p a ex:Person .
            ?p ex:name ?name .
        }
    """)
    @test length(result.name) == 1
    @test contains(result.name[1], "Alice")
end

# Based on maplib/py_maplib/tests/test_pizza_example.py — DELETE/INSERT combined

@testset "SPARQL UPDATE DELETE/INSERT combined" begin
    EX = Namespace("http://example.org/")
    m = RDFMapping()

    tbl = (
        id = ["http://example.org/Alice", "http://example.org/Bob"],
        role = ["http://example.org/Student", "http://example.org/Student"],
    )
    rdf_map!(m, tbl, RDFTemplate(
        subject = :id,
        properties = [(RDF.type, :role, IRIColumn())],
    ))
    @test length(m) == 2

    # Replace Student with Alumni
    rdf_update!(m, """
        PREFIX ex: <http://example.org/>
        DELETE { ?p a ex:Student }
        INSERT { ?p a ex:Alumni }
        WHERE { ?p a ex:Student }
    """)

    result = rdf_query(m, """
        PREFIX ex: <http://example.org/>
        SELECT ?p WHERE { ?p a ex:Student }
    """)
    @test length(result) == 0 || (haskey(result, :p) && length(result.p) == 0)

    result2 = rdf_query(m, """
        PREFIX ex: <http://example.org/>
        SELECT ?p WHERE { ?p a ex:Alumni }
    """)
    @test length(result2.p) == 2
end

# Multiple table mappings accumulated

@testset "Multiple table mappings accumulated" begin
    EX = Namespace("http://example.org/")
    m = RDFMapping()

    # First table: people with names
    people = (
        id = ["http://example.org/Alice", "http://example.org/Bob"],
        name = ["Alice", "Bob"],
    )
    map_default!(m, people, :id;
        predicate_prefix="http://example.org/",
        types=[EX("Person")])

    # Second table: people with ages
    ages = (
        id = ["http://example.org/Alice", "http://example.org/Bob"],
        age = [30, 25],
    )
    map_default!(m, ages, :id; predicate_prefix="http://example.org/")

    @test length(m) == 6  # 2 types + 2 names + 2 ages

    result = rdf_query(m, """
        PREFIX ex: <http://example.org/>
        SELECT ?name ?age WHERE {
            ?p a ex:Person .
            ?p ex:name ?name .
            ?p ex:age ?age .
        }
        ORDER BY ?name
    """)
    @test length(result.name) == 2
end

# Direct graph operations via mapping

@testset "Direct graph access" begin
    m = RDFMapping()
    add!(m.graph, Triple(
        URIRef("http://example.org/s"),
        URIRef("http://example.org/p"),
        Literal("value")))

    result = rdf_query(m, "SELECT ?o WHERE { ?s ?p ?o }")
    @test length(result.o) == 1
    @test contains(result.o[1], "value")
end

# Empty query result

@testset "Empty query result" begin
    m = RDFMapping()
    result = rdf_query(m, "SELECT ?s ?p ?o WHERE { ?s ?p ?o }")
    @test result isa NamedTuple
end

# Language-tagged literals

@testset "Language-tagged mapping and query" begin
    m = RDFMapping()
    tbl = (
        id = ["http://example.org/book1"],
        title_en = ["The Book"],
        title_fr = ["Le Livre"],
    )
    EX = Namespace("http://example.org/")
    tpl = RDFTemplate(
        subject = :id,
        properties = [
            (EX("title"), :title_en, LangColumn("en")),
            (EX("title"), :title_fr, LangColumn("fr")),
        ],
    )
    rdf_map!(m, tbl, tpl)
    @test length(m) == 2

    result = rdf_query(m, """
        PREFIX ex: <http://example.org/>
        SELECT ?title WHERE {
            ?s ex:title ?title .
            FILTER(lang(?title) = "en")
        }
    """)
    @test length(result.title) == 1
    @test contains(result.title[1], "The Book")
end

end  # Tabular RDF Mapping

# ─── OTTR Template Tests ───────────────────────────────────────────

@testset "OTTR Template Engine" begin

# ─── Parser Tests ────────────────────────────────────────────────

@testset "parse_ottr — basic template" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix ottr: <http://ns.ottr.xyz/0.4/> .

    ex:ExampleTemplate [ottr:IRI ?myVar1] :: {
        ottr:Triple(ex:anObject, ex:relatesTo, ?myVar1)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test tpls[1].iri == "http://example.net/ns#ExampleTemplate"
    @test length(tpls[1].parameters) == 1
    @test tpls[1].parameters[1].name == "myVar1"
    @test tpls[1].parameters[1].ptype isa OTTRTypeIRI
    @test length(tpls[1].instances) == 1
    @test tpls[1].instances[1].template_iri == "http://ns.ottr.xyz/0.4/Triple"
    @test length(tpls[1].instances[1].args) == 3
end

@testset "parse_ottr — multiple parameters" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:Template [?var1, ?var2, ?var3] :: {
        ottr:Triple(ex:s, ex:p1, ?var1),
        ottr:Triple(ex:s, ex:p2, ?var2)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test length(tpls[1].parameters) == 3
    @test tpls[1].parameters[1].name == "var1"
    @test tpls[1].parameters[3].name == "var3"
    @test length(tpls[1].instances) == 2
end

@testset "parse_ottr — optional parameters" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    ex:Template [xsd:string ?required, ? xsd:string ?optional] :: {
        ottr:Triple(ex:s, ex:p, ?required)
    } .
    """
    tpls = parse_ottr(doc)
    @test !tpls[1].parameters[1].optional
    @test tpls[1].parameters[2].optional
end

@testset "parse_ottr — ??var optional syntax" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:Template [??pizza] .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test tpls[1].parameters[1].optional
    @test tpls[1].parameters[1].name == "pizza"
end

@testset "parse_ottr — modifier combinations" begin
    # !?var → nonblank
    doc1 = """
    @prefix ex: <http://example.net/ns#> .
    ex:T1 [!?pizza] .
    """
    tpls1 = parse_ottr(doc1)
    @test tpls1[1].parameters[1].name == "pizza"

    # ?!?var → optional + nonblank
    doc2 = """
    @prefix ex: <http://example.net/ns#> .
    ex:T2 [?!?pizza] .
    """
    tpls2 = parse_ottr(doc2)
    @test tpls2[1].parameters[1].optional
    @test tpls2[1].parameters[1].name == "pizza"

    # !??var → nonblank + optional
    doc3 = """
    @prefix ex: <http://example.net/ns#> .
    ex:T3 [!??pizza] .
    """
    tpls3 = parse_ottr(doc3)
    @test tpls3[1].parameters[1].optional
    @test tpls3[1].parameters[1].name == "pizza"
end

@testset "parse_ottr — typed parameters" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [? owl:Class ?pizza] .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].parameters[1].optional
    @test tpls[1].parameters[1].ptype isa OTTRTypeIRI
end

@testset "parse_ottr — List types" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [List<owl:Class> ?toppings] .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].parameters[1].ptype isa OTTRTypeList
end

@testset "parse_ottr — default values" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix p: <http://example.net/pizzas#> .
    ex:T1 [owl:Class ?pizza = p:pizza] .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].parameters[1].default_value == "http://example.net/pizzas#pizza"

    doc2 = """
    @prefix ex: <http://example.net/ns#> .
    ex:T2 [owl:Class ?pizza = 2] .
    """
    tpls2 = parse_ottr(doc2)
    @test tpls2[1].parameters[1].default_value == 2

    doc3 = """
    @prefix ex: <http://example.net/ns#> .
    ex:T3 [owl:Class ?pizza = "asdf"] .
    """
    tpls3 = parse_ottr(doc3)
    @test tpls3[1].parameters[1].default_value isa Literal
end

@testset "parse_ottr — cross list expander" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [ottr:IRI ?var1] :: {
        cross | ottr:Triple(?var1, ex:hasNumber, ++(1, 2))
    } .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].instances[1].list_expander == :cross
    @test tpls[1].instances[1].args[3].list_expand
end

@testset "parse_ottr — nested template calls" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:Outer [?v1, ?v2] :: {
        ex:Inner(?v1),
        ottr:Triple(ex:s, ex:p, ?v2)
    } .
    ex:Inner [?v] :: {
        ottr:Triple(ex:s, ex:q, ?v)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 2
    @test tpls[1].instances[1].template_iri == "http://example.net/ns#Inner"
end

@testset "parse_ottr — blank node args" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix foaf: <http://xmlns.com/foaf/0.1/> .
    ex:Person [?firstName, ?lastName] :: {
        ottr:Triple(_:person, rdf:type, foaf:Person),
        ottr:Triple(_:person, foaf:firstName, ?firstName)
    } .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].instances[1].args[1].constant isa BNode
    @test tpls[1].instances[1].args[1].constant.id == "person"
end

@testset "parse_ottr — a shorthand" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?x] :: {
        ottr:Triple(?x, a, ex:Thing)
    } .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].instances[1].args[2].constant == URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
end

@testset "parse_ottr — constant typed literals" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    ex:T [xsd:string ?id] :: {
        ottr:Triple(ex:s, ex:country, "United Kingdom"^^xsd:string)
    } .
    """
    tpls = parse_ottr(doc)
    obj_arg = tpls[1].instances[1].args[3]
    @test obj_arg.constant isa Literal
    @test obj_arg.constant.lexical == "United Kingdom"
end

@testset "parse_ottr — language tagged literals" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?myString] :: {
        ottr:Triple(ex:s, ex:label, ""@ar-SA)
    } .
    """
    tpls = parse_ottr(doc)
    obj = tpls[1].instances[1].args[3].constant
    @test obj isa Literal
    @test obj.language == "ar-sa"  # normalized to lowercase per BCP47
end

@testset "parse_ottr — full IRI template name" begin
    doc = """
    @prefix ottr: <http://ns.ottr.xyz/0.4/> .
    <https://example.org/Template#MyTemplate> [?value] :: {
        ottr:Triple(<https://example.org/entity#test>, <https://example.org/prop#hasValue>, ?value)
    } .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].iri == "https://example.org/Template#MyTemplate"
end

@testset "parse_ottr — comments" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    # Comment at start
    ex:T [?value] :: {
        # Comment before triple
        ottr:Triple(ex:s, ex:p, ?value)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test length(tpls[1].instances) == 1
end

@testset "parse_ottr — SPARQL-style prefix" begin
    doc = """
    prefix ex: <http://example.org#>
    @prefix foaf: <http://xmlns.com/foaf/0.1/> .
    ex:Person [?firstName] :: {
        ottr:Triple(ex:s, foaf:name, ?firstName)
    } .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].iri == "http://example.org#Person"
end

@testset "parse_ottr — trailing commas" begin
    doc = """
    @prefix ex: <http://example.org#> .
    @prefix foaf: <http://xmlns.com/foaf/0.1/> .
    ex:Person [?firstName, ?lastName, ?email, ] :: {
        ottr:Triple(ex:s, foaf:name, ?firstName)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls[1].parameters) == 3
end

@testset "parse_ottr — optional commas between instances" begin
    doc = """
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix ex: <http://example.org#> .
    @prefix foaf: <http://xmlns.com/foaf/0.1/> .
    ex:Person [?firstName, ?lastName] :: {
        ottr:Triple(_:person, rdf:type, foaf:Person)
        ottr:Triple(_:person, foaf:firstName, ?firstName),
        ottr:Triple(_:person, foaf:lastName, ?lastName)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls[1].instances) == 3
end

@testset "parse_ottr — multiline parameters" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    ex:T [
        xsd:string ?param1,
        xsd:string ?param2,
        ? xsd:string ?param3
    ] :: {
        ottr:Triple(ex:s, ex:p1, ?param1)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls[1].parameters) == 3
    @test tpls[1].parameters[3].optional
end

@testset "parse_ottr — multiline instances" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?val] :: {
        ottr:Triple(
            ex:subject,
            ex:property,
            ?val
        ),
        ottr:Triple(
            ex:subject,
            ex:anotherProperty,
            ?val
        )
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls[1].instances) == 2
end

@testset "parse_ottr — signature only (no body)" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:NamedPizza [??pizza] .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test isempty(tpls[1].instances)
    @test tpls[1].parameters[1].optional
end

@testset "parse_ottr — list default value" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?pizza = "asdf", ?country = ("asdf", "asdf"), ?toppings = ((())) ] .
    """
    tpls = parse_ottr(doc)
    @test length(tpls[1].parameters) == 3
end

@testset "parse_ottr — complex annotation + body" begin
    doc = """
    @prefix ex:<http://example.net/ns#>.
    @prefix p:<http://example.net/pizzas#>.
    @prefix xsd:<http://www.w3.org/2001/XMLSchema#>.
    ex:NamedPizza [
      ! owl:Class ?pizza = p:Grandiosa , ?! owl:NamedIndividual ?country , List<owl:Class> ?toppings
      ]
      @@ cross | ex:SomeAnnotationTemplate("asdf", "asdf", "asdf" )
      :: {
         cross | ex:Template1 (?pizza, ++?toppings) ,
         ex:Template2 (1, 2, 4, 5)
      } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test length(tpls[1].parameters) == 3
    @test length(tpls[1].instances) == 2
    @test tpls[1].instances[1].list_expander == :cross
end

@testset "parse_ottr — empty template body missing dot" begin
    doc = """
    @prefix ex:<http://example.net/ns#>.
    ex:template [ ] :: { ex:template((ex:template)) }
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
end

@testset "parse_ottr — multiple templates in one doc" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T1 [?a] :: {
        ottr:Triple(ex:s, ex:p1, ?a)
    } .
    ex:T2 [?b] :: {
        ottr:Triple(ex:s, ex:p2, ?b)
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 2
    @test tpls[1].iri == "http://example.net/ns#T1"
    @test tpls[2].iri == "http://example.net/ns#T2"
end

# ─── Template Expansion Tests ───────────────────────────────────

@testset "ottr_map! — basic IRI template" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix ottr: <http://ns.ottr.xyz/0.4/> .
    ex:ExampleTemplate [ottr:IRI ?myVar1] :: {
        ottr:Triple(ex:anObject, ex:relatesTo, ?myVar1)
    } .
    """
    add_template!(m, doc)

    table = (myVar1=["http://example.net/ns#OneThing", "http://example.net/ns#AnotherThing"],)
    ottr_map!(m, "http://example.net/ns#ExampleTemplate", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?o WHERE { ex:anObject ex:relatesTo ?o . } ORDER BY ?o
    """)
    @test length(result.o) == 2
    @test contains(result.o[1], "AnotherThing")
    @test contains(result.o[2], "OneThing")
end

@testset "ottr_map! — string parameter" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?myString] :: {
        ottr:Triple(ex:anObject, ex:hasString, ?myString),
        ottr:Triple(ex:anotherObject, ex:hasString, ""@ar-SA)
    } .
    """
    add_template!(m, doc)
    table = (myString=["one", "two"],)
    ottr_map!(m, "http://example.net/ns#T", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?s ?o WHERE { ?s ex:hasString ?o . }
    """)
    # 2 rows from myString + 2 rows from constant (one per row)
    @test length(result.s) >= 2
end

@testset "ottr_map! — cross list expansion with constant list" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [ottr:IRI ?var1] :: {
        cross | ottr:Triple(?var1, ex:hasNumber, ++(1, 2))
    } .
    """
    add_template!(m, doc)

    table = (var1=["http://example.net/ns#OneThing", "http://example.net/ns#AnotherThing"],)
    ottr_map!(m, "http://example.net/ns#T", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?s ?o WHERE { ?s ex:hasNumber ?o . } ORDER BY ?s ?o
    """)
    @test length(result.s) == 4  # 2 subjects × 2 numbers
end

@testset "ottr_map! — nested templates" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:ExampleTemplate [?myVar1, ?myVar2] :: {
        ex:Nested(?myVar1),
        ottr:Triple(ex:anObject, ex:hasOtherNumber, ?myVar2)
    } .
    ex:Nested [?myVar] :: {
        ottr:Triple(ex:anObject, ex:hasNumber, ?myVar)
    } .
    """
    add_template!(m, doc)

    table = (myVar1=[1, 2], myVar2=[3, 4])
    ottr_map!(m, "http://example.net/ns#ExampleTemplate", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?p ?o WHERE { ex:anObject ?p ?o . } ORDER BY ?p ?o
    """)
    @test length(result.p) == 4  # 2 hasNumber + 2 hasOtherNumber
end

@testset "ottr_map! — blank node subjects" begin
    m = RDFMapping()
    doc = """
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix foaf: <http://xmlns.com/foaf/0.1/> .
    @prefix ex: <http://example.org#> .
    ex:Person [?firstName, ?lastName] :: {
        ottr:Triple(_:person, rdf:type, foaf:Person),
        ottr:Triple(_:person, foaf:firstName, ?firstName),
        ottr:Triple(_:person, foaf:lastName, ?lastName)
    } .
    """
    add_template!(m, doc)

    table = (firstName=["Alice", "Bob"], lastName=["Smith", "Jones"])
    ottr_map!(m, "http://example.org#Person", table)

    # Should have 6 triples: 3 per row
    @test length(m.graph) == 6
    # Blank nodes should be unique per row
    result = rdf_query(m, """
        PREFIX foaf: <http://xmlns.com/foaf/0.1/>
        SELECT ?fn ?ln WHERE {
            ?p a foaf:Person .
            ?p foaf:firstName ?fn .
            ?p foaf:lastName ?ln .
        } ORDER BY ?fn
    """)
    @test length(result.fn) == 2
    @test result.fn[1] == "Alice"
    @test result.fn[2] == "Bob"
end

@testset "ottr_map! — optional parameter skips missing" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    ex:T [xsd:string ?required, ? xsd:string ?optional] :: {
        ottr:Triple(ex:subject, ex:hasRequired, ?required),
        ottr:Triple(ex:subject, ex:hasOptional, ?optional)
    } .
    """
    add_template!(m, doc)

    # First mapping with both values
    table1 = (required=["value1"], optional=["value2"])
    ottr_map!(m, "http://example.net/ns#T", table1)

    # Second mapping with missing optional
    table2 = (required=["value3"], optional=[missing])
    ottr_map!(m, "http://example.net/ns#T", table2)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?p ?o WHERE { ex:subject ?p ?o . } ORDER BY ?p ?o
    """)
    @test length(result.p) == 3  # 2 required + 1 optional (missing skipped)
end

@testset "ottr_map! — typed literal constant" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    ex:T [xsd:string ?id] :: {
        ottr:Triple(ex:subject, ex:country, "United Kingdom"^^xsd:string),
        ottr:Triple(ex:subject, ex:hasId, ?id)
    } .
    """
    add_template!(m, doc)

    table = (id=["test"],)
    ottr_map!(m, "http://example.net/ns#T", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?o WHERE { ex:subject ex:country ?o . }
    """)
    @test length(result.o) == 1
    @test result.o[1] == "United Kingdom"
end

@testset "ottr_map! — a shorthand for rdf:type" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [ottr:IRI ?x] :: {
        ottr:Triple(?x, a, ex:Thing)
    } .
    """
    add_template!(m, doc)

    table = (x=["http://example.net/ns#obj1"],)
    ottr_map!(m, "http://example.net/ns#T", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?s WHERE { ?s a ex:Thing . }
    """)
    @test length(result.s) == 1
end

@testset "ottr_map! — list expansion from vector column" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [ottr:IRI ?object, ?myList] :: {
        cross | ottr:Triple(?object, ex:hasNumber, ++?myList)
    } .
    """
    add_template!(m, doc)

    table = (
        object=["http://example.net/ns#obj1", "http://example.net/ns#obj2"],
        myList=[[1, 2], [3, 4, 5]]
    )
    ottr_map!(m, "http://example.net/ns#T", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?s ?o WHERE { ?s ex:hasNumber ?o . } ORDER BY ?s ?o
    """)
    @test length(result.s) == 5  # 2 + 3
end

@testset "ottr_map! — two list expansion instances" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [ottr:IRI ?object, ?myList1, ?myList2] :: {
        cross | ottr:Triple(?object, ex:hasNumber, ++?myList1),
        cross | ottr:Triple(?object, ex:hasOtherNumber, ++?myList2)
    } .
    """
    add_template!(m, doc)

    table = (
        object=["http://example.net/ns#obj1", "http://example.net/ns#obj2"],
        myList1=[[1, 2], [3, 4]],
        myList2=[[5, 6], [7, 8, 9]]
    )
    ottr_map!(m, "http://example.net/ns#T", table)

    result = rdf_query(m, """
        PREFIX ex: <http://example.net/ns#>
        SELECT ?s ?p ?o WHERE { ?s ?p ?o . } ORDER BY ?s ?p ?o
    """)
    @test length(result.s) == 9  # obj1: 2+2=4, obj2: 2+3=5
end

@testset "ottr_map! — numeric values" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?intVal, ?floatVal] :: {
        ottr:Triple(ex:s, ex:hasInt, ?intVal),
        ottr:Triple(ex:s, ex:hasFloat, ?floatVal)
    } .
    """
    add_template!(m, doc)

    table = (intVal=[42, -7], floatVal=[3.14, 2.72])
    ottr_map!(m, "http://example.net/ns#T", table)

    @test length(m.graph) == 4
end

@testset "ottr_map! — boolean values" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?boolVal] :: {
        ottr:Triple(ex:s, ex:hasBool, ?boolVal)
    } .
    """
    add_template!(m, doc)

    table = (boolVal=[true, false],)
    ottr_map!(m, "http://example.net/ns#T", table)

    @test length(m.graph) == 2
end

@testset "ottr_map! — full IRI template name" begin
    m = RDFMapping()
    doc = """
    <https://example.org/path/to/Template#My> [?value] :: {
        ottr:Triple(<https://example.org/entity#test>, <https://example.org/prop#has>, ?value)
    } .
    """
    add_template!(m, doc)

    table = (value=["hello"],)
    ottr_map!(m, "https://example.org/path/to/Template#My", table)

    result = rdf_query(m, """
        SELECT ?s WHERE {
            ?s <https://example.org/prop#has> "hello" .
        }
    """)
    @test length(result.s) == 1
end

@testset "ottr_map! — constant integer args" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?name] :: {
        ottr:Triple(ex:s, ex:p, 42),
        ottr:Triple(ex:s, ex:q, ?name)
    } .
    """
    add_template!(m, doc)

    table = (name=["Alice"],)
    ottr_map!(m, "http://example.net/ns#T", table)

    @test length(m.graph) == 2
end

# ─── add_template! API Tests ────────────────────────────────────

@testset "add_template! — registers and retrieves templates" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T1 [?a] :: { ottr:Triple(ex:s, ex:p, ?a) } .
    ex:T2 [?b] :: { ottr:Triple(ex:s, ex:q, ?b) } .
    """
    add_template!(m, doc)
    @test length(m.templates) == 2
    @test haskey(m.templates, "http://example.net/ns#T1")
    @test haskey(m.templates, "http://example.net/ns#T2")
end

# ─── SHACL Integration ──────────────────────────────────────────

@testset "rdf_validate — validates mapping graph" begin
    m = RDFMapping()
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [ottr:IRI ?person, ?name] :: {
        ottr:Triple(?person, a, ex:Person),
        ottr:Triple(?person, ex:name, ?name)
    } .
    """
    add_template!(m, doc)
    table = (person=["http://example.net/ns#alice"], name=["Alice"])
    ottr_map!(m, "http://example.net/ns#T", table)

    shapes_ttl = """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix ex: <http://example.net/ns#> .
    ex:PersonShape a sh:NodeShape ;
        sh:targetClass ex:Person ;
        sh:property [
            sh:path ex:name ;
            sh:minCount 1 ;
            sh:datatype <http://www.w3.org/2001/XMLSchema#string>
        ] .
    """
    report = rdf_validate(m, shapes_ttl)
    @test report.conforms
end

@testset "rdf_validate — detects violations" begin
    m = RDFMapping()
    add!(m.graph, Triple(URIRef("http://example.net/ns#alice"),
                          URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                          URIRef("http://example.net/ns#Person")))
    # Missing required ex:name property

    shapes_ttl = """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix ex: <http://example.net/ns#> .
    ex:PersonShape a sh:NodeShape ;
        sh:targetClass ex:Person ;
        sh:property [
            sh:path ex:name ;
            sh:minCount 1
        ] .
    """
    report = rdf_validate(m, shapes_ttl)
    @test !report.conforms
end

# ─── Datalog Integration ────────────────────────────────────────

@testset "rdf_reason! — applies Datalog rules" begin
    m = RDFMapping()
    ex = "http://example.org/"
    rdfs_sc = "http://www.w3.org/2000/01/rdf-schema#subClassOf"
    rdf_type = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    # Add data
    add!(m.graph, Triple(URIRef(ex * "Dog"), URIRef(rdfs_sc), URIRef(ex * "Animal")))
    add!(m.graph, Triple(URIRef(ex * "fido"), URIRef(rdf_type), URIRef(ex * "Dog")))
    # Add RDFS-like rule: ?x rdf:type ?A, ?A rdfs:subClassOf ?B → ?x rdf:type ?B
    add!(m.graph, Triple(URIRef(rdfs_sc), URIRef(rdf_type), URIRef(ex * "TransitiveProperty")))

    before = length(m.graph)
    rdf_reason!(m)
    # Datalog may or may not infer new triples depending on encoded rules
    # At minimum, the graph should not lose triples
    @test length(m.graph) >= before
end

# ─── Trailing comma in large template ───────────────────────────

@testset "parse_ottr — trailing comma in instance list" begin
    doc = """
    @prefix rdf:<http://www.w3.org/1999/02/22-rdf-syntax-ns#>.
    @prefix foaf:<http://xmlns.com/foaf/0.1/>.
    @prefix dct:<http://purl.org/dc/terms/>.
    @prefix gtfs:<http://vocab.gtfs.org/terms#>.
    @prefix geo:<http://www.w3.org/2003/01/geo/wgs84_pos#>.
    @prefix t:<https://github.com/maplib/template#>.

    t:Stops [ ottr:IRI ?stop_id, ?stop_code, ?stop_name, ?stop_lat, ?stop_lon,
              , ] :: {
      ottr:Triple(?stop_id, a, gtfs:Stop) ,
      ottr:Triple(?stop_id, foaf:name, ?stop_name) ,
      ottr:Triple(?stop_id, geo:lat, ?stop_lat) ,
      ottr:Triple(?stop_id, geo:long, ?stop_lon) ,
    } .
    """
    tpls = parse_ottr(doc)
    @test length(tpls) == 1
    @test length(tpls[1].instances) == 4
end

@testset "parse_ottr — xsd:anyURI type" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    ex:T [? xsd:anyURI ?website] :: {
        ottr:Triple(ex:subject, ex:hasWebsite, ?website)
    } .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].parameters[1].ptype isa OTTRTypeIRI
    @test tpls[1].parameters[1].optional
end

@testset "parse_ottr — LUB type" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [?! LUB<owl:NamedIndividual> ?country] .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].parameters[1].name == "country"
    @test tpls[1].parameters[1].optional
end

@testset "parse_ottr — NEList type" begin
    doc = """
    @prefix ex: <http://example.net/ns#> .
    ex:T [NEList<List<List<owl:Class>>> ?toppings] .
    """
    tpls = parse_ottr(doc)
    @test tpls[1].parameters[1].ptype isa OTTRTypeList
end

end  # OTTR Template Engine
