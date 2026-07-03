using Test
using HTTP
using JSON

@testset "SPARQL Server" begin
    # Create and configure server
    server = SparqlServer(port=3332, verbose=false)
    add_dataset!(server, "test")

    # Pre-load data
    ep = get_dataset(server, "test")
    g = ep.dataset.default_graph
    add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
    add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Alice")))
    add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://xmlns.com/foaf/0.1/age"), Literal("30", datatype=URIRef("http://www.w3.org/2001/XMLSchema#integer"))))
    add!(g, Triple(URIRef("http://example.org/bob"), URIRef("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"), URIRef("http://xmlns.com/foaf/0.1/Person")))
    add!(g, Triple(URIRef("http://example.org/bob"), URIRef("http://xmlns.com/foaf/0.1/name"), Literal("Bob")))
    add!(g, Triple(URIRef("http://example.org/alice"), URIRef("http://xmlns.com/foaf/0.1/knows"), URIRef("http://example.org/bob")))

    # Start server
    serve!(server; background=true)
    sleep(0.5)

    BASE = "http://127.0.0.1:3332"

    @testset "Health & Admin" begin
        r = HTTP.get("$BASE/\$/ping")
        @test r.status == 200
        @test String(r.body) == "OK"

        r = HTTP.get("$BASE/\$/server")
        @test r.status == 200
        info = JSON.parse(String(r.body))
        @test info["server"] == "RDFLib.jl SPARQL Server"
        @test "Jelly RDF binary upload/download" in info["features"]

        r = HTTP.get("$BASE/\$/datasets")
        @test r.status == 200
        ds = JSON.parse(String(r.body))
        @test length(ds["datasets"]) == 1
    end

    @testset "SPARQL Query — GET" begin
        q = HTTP.URIs.escapeuri("SELECT ?name WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name } ORDER BY ?name")
        r = HTTP.get("$BASE/test/sparql?query=$q",
            headers=["Accept" => "application/sparql-results+json"])
        @test r.status == 200
        result = JSON.parse(String(r.body))
        @test "name" in result["head"]["vars"]
        names = [b["name"]["value"] for b in result["results"]["bindings"]]
        @test "Alice" in names
        @test "Bob" in names
    end

    @testset "SPARQL Query — POST (body)" begin
        r = HTTP.post("$BASE/test/sparql",
            headers=["Content-Type" => "application/sparql-query",
                     "Accept" => "application/sparql-results+json"],
            body="ASK WHERE { <http://example.org/alice> <http://xmlns.com/foaf/0.1/knows> <http://example.org/bob> }")
        @test r.status == 200
        result = JSON.parse(String(r.body))
        @test result["boolean"] == true
    end

    @testset "SPARQL Query — POST (form)" begin
        r = HTTP.post("$BASE/test/sparql",
            headers=["Content-Type" => "application/x-www-form-urlencoded",
                     "Accept" => "application/sparql-results+xml"],
            body="query=" * HTTP.URIs.escapeuri("SELECT ?s WHERE { ?s a <http://xmlns.com/foaf/0.1/Person> }"))
        @test r.status == 200
        @test occursin("sparql-results", String(r.body))
    end

    @testset "SPARQL Query — CONSTRUCT" begin
        r = HTTP.post("$BASE/test/sparql",
            headers=["Content-Type" => "application/sparql-query",
                     "Accept" => "text/turtle"],
            body="CONSTRUCT { ?s <http://example.org/label> ?name } WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name }")
        @test r.status == 200
        body = String(r.body)
        @test occursin("Alice", body) || occursin("alice", body)
    end

    @testset "SPARQL Query — CSV/TSV" begin
        q = HTTP.URIs.escapeuri("SELECT ?name WHERE { ?s <http://xmlns.com/foaf/0.1/name> ?name }")
        r = HTTP.get("$BASE/test/sparql?query=$q",
            headers=["Accept" => "text/csv"])
        @test r.status == 200
        @test occursin("Alice", String(r.body))

        r = HTTP.get("$BASE/test/sparql?query=$q",
            headers=["Accept" => "text/tab-separated-values"])
        @test r.status == 200
        @test occursin("Alice", String(r.body))
    end

    @testset "SPARQL Update" begin
        r = HTTP.post("$BASE/test/update",
            headers=["Content-Type" => "application/sparql-update"],
            body="INSERT DATA { <http://example.org/charlie> <http://xmlns.com/foaf/0.1/name> \"Charlie\" }")
        @test r.status == 204

        q = HTTP.URIs.escapeuri("ASK WHERE { <http://example.org/charlie> ?p ?o }")
        r = HTTP.get("$BASE/test/sparql?query=$q")
        result = JSON.parse(String(r.body))
        @test result["boolean"] == true

        # DELETE
        r = HTTP.post("$BASE/test/update",
            headers=["Content-Type" => "application/sparql-update"],
            body="DELETE DATA { <http://example.org/charlie> <http://xmlns.com/foaf/0.1/name> \"Charlie\" }")
        @test r.status == 204
    end

    @testset "Graph Store Protocol — GET" begin
        r = HTTP.get("$BASE/test/data?default",
            headers=["Accept" => "application/n-triples"])
        @test r.status == 200
        @test occursin("alice", String(r.body))

        r = HTTP.get("$BASE/test/data?default",
            headers=["Accept" => "text/turtle"])
        @test r.status == 200

        r = HTTP.get("$BASE/test/data?default",
            headers=["Accept" => "application/ld+json"])
        @test r.status == 200
    end

    @testset "Graph Store Protocol — PUT/POST/DELETE (named graph)" begin
        # PUT a new named graph
        ttl = """
        @prefix ex: <http://example.org/> .
        ex:x ex:y ex:z .
        ex:x ex:y "hello" .
        """
        r = HTTP.request("PUT", "$BASE/test/data?graph=" * HTTP.URIs.escapeuri("http://example.org/graph1"),
            headers=["Content-Type" => "text/turtle"],
            body=ttl)
        @test r.status == 204

        # GET the named graph
        r = HTTP.get("$BASE/test/data?graph=" * HTTP.URIs.escapeuri("http://example.org/graph1"),
            headers=["Accept" => "application/n-triples"])
        @test r.status == 200
        @test occursin("hello", String(r.body))

        # POST more data to it
        r = HTTP.post("$BASE/test/data?graph=" * HTTP.URIs.escapeuri("http://example.org/graph1"),
            headers=["Content-Type" => "text/turtle"],
            body="<http://example.org/a> <http://example.org/b> <http://example.org/c> .")
        @test r.status == 200

        # DELETE the named graph
        r = HTTP.request("DELETE", "$BASE/test/data?graph=" * HTTP.URIs.escapeuri("http://example.org/graph1"))
        @test r.status == 204

        # Verify it's gone
        r = HTTP.get("$BASE/test/data?graph=" * HTTP.URIs.escapeuri("http://example.org/graph1"),
            status_exception=false)
        @test r.status == 404
    end

    @testset "Jelly Upload & Download" begin
        # Create a graph and serialize to Jelly
        jg = RDFGraph()
        for i in 1:100
            add!(jg, Triple(
                URIRef("http://jelly.org/node$i"),
                URIRef("http://jelly.org/value"),
                Literal("val$i")))
        end
        jdata = serialize_jelly(jg)

        # Upload
        r = HTTP.post("$BASE/test/upload",
            headers=["Content-Type" => "application/x-jelly-rdf"],
            body=jdata)
        @test r.status == 200
        result = JSON.parse(String(r.body))
        @test result["tripleCount"] == 100

        # Download as Jelly
        r = HTTP.get("$BASE/test/data?default",
            headers=["Accept" => "application/x-jelly-rdf"])
        @test r.status == 200
        g_back = parse_jelly(r.body)
        # Should have at least the 100 jelly triples
        @test length(g_back) >= 100

        # Clean up: remove the jelly triples
        HTTP.post("$BASE/test/update",
            headers=["Content-Type" => "application/sparql-update"],
            body="DELETE WHERE { <http://jelly.org/node1> ?p ?o }")
    end

    @testset "Jelly dataset serialization is rejected" begin
        ds = Dataset()
        add!(ds, Triple(URIRef("http://example.org/default"), URIRef("http://example.org/p"), Literal("v")))
        add!(ds, Triple(URIRef("http://example.org/named"), URIRef("http://example.org/p"), Literal("v2")),
             URIRef("http://example.org/g"))
        @test_throws ArgumentError RDFLib._serialize_dataset(ds, RDFLib.CT_JELLY)
    end

    @testset "File Upload — Multiple Formats" begin
        for (ct, body) in [
            ("application/n-triples", "<http://fmt.org/nt> <http://fmt.org/p> \"ntriples\" .\n"),
            ("application/rdf+xml", """<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="http://fmt.org/xml">
    <rdf:value>rdfxml</rdf:value>
  </rdf:Description>
</rdf:RDF>"""),
            ("application/ld+json", """{"@id":"http://fmt.org/jld","http://fmt.org/p":[{"@value":"jsonld"}]}"""),
        ]
            r = HTTP.post("$BASE/test/upload",
                headers=["Content-Type" => ct], body=body)
            @test r.status == 200
        end
    end

    @testset "Content Negotiation" begin
        q = HTTP.URIs.escapeuri("SELECT ?s WHERE { ?s a <http://xmlns.com/foaf/0.1/Person> }")

        # JSON results
        r = HTTP.get("$BASE/test/sparql?query=$q",
            headers=["Accept" => "application/sparql-results+json"])
        @test occursin("sparql-results+json", string(r.headers))

        # XML results
        r = HTTP.get("$BASE/test/sparql?query=$q",
            headers=["Accept" => "application/sparql-results+xml"])
        ct = String(Dict(r.headers)["Content-Type"])
        @test occursin("xml", ct)

        # Wildcard
        r = HTTP.get("$BASE/test/sparql?query=$q",
            headers=["Accept" => "*/*"])
        @test r.status == 200
    end

    @testset "Dataset Management" begin
        # Create new dataset
        r = HTTP.post("$BASE/\$/datasets",
            headers=["Content-Type" => "application/x-www-form-urlencoded"],
            body="dbName=newds")
        @test r.status == 201

        # List datasets
        r = HTTP.get("$BASE/\$/datasets")
        ds = JSON.parse(String(r.body))
        names = [d["name"] for d in ds["datasets"]]
        @test "/newds" in names

        # Query the new dataset
        q = HTTP.URIs.escapeuri("SELECT * WHERE { ?s ?p ?o }")
        r = HTTP.get("$BASE/newds/sparql?query=$q")
        @test r.status == 200

        # Delete it
        r = HTTP.request("DELETE", "$BASE/\$/datasets/newds")
        @test r.status == 204

        # Verify gone
        r = HTTP.get("$BASE/newds/sparql?query=$q", status_exception=false)
        @test r.status == 404
    end

    @testset "CORS" begin
        r = HTTP.request("OPTIONS", "$BASE/test/sparql")
        @test r.status == 204
        hdrs = Dict(r.headers)
        @test haskey(hdrs, "Access-Control-Allow-Origin")
        @test haskey(hdrs, "Access-Control-Allow-Methods")
    end

    @testset "Error Handling" begin
        # Bad SPARQL
        r = HTTP.get("$BASE/test/sparql?query=" * HTTP.URIs.escapeuri("SELECTX * WHERE { }"),
            status_exception=false)
        @test r.status == 400

        # Missing query
        r = HTTP.get("$BASE/test/sparql", status_exception=false)
        @test r.status == 400

        # Unknown dataset
        r = HTTP.get("$BASE/nosuch/sparql?query=SELECT+*+WHERE+{}", status_exception=false)
        @test r.status == 404

        # Bad content type for upload
        r = HTTP.post("$BASE/test/upload",
            headers=["Content-Type" => "text/html"],
            body="<html></html>", status_exception=false)
        @test r.status == 400
    end

    @testset "Dataset Info" begin
        r = HTTP.get("$BASE/test/",
            headers=["Accept" => "application/json"])
        @test r.status == 200
        info = JSON.parse(String(r.body))
        @test info["name"] == "test"
        @test haskey(info, "totalTriples")
        @test haskey(info, "endpoints")
    end
end
