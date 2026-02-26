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

end
