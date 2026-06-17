# Official W3C rdf-tests conformance gate.
#
# Runs the official W3C RDF 1.1 / SPARQL test manifests through RDFLib via the
# harness in test/w3c/manifest_runner.jl and asserts that each suite meets a
# recorded pass-count floor (so conformance can only improve, never regress).
#
# The test suite itself is large and permissively licensed but NOT vendored into
# this repo (it is gitignored). Run `julia --project=. test/w3c/fetch.jl` once to
# download it into test/w3c/suite/. When the suite is absent (e.g. ordinary CI),
# these tests SKIP with a pointer rather than fail.

using Test
using RDFLib
using Logging

const _W3C_SUITE = joinpath(@__DIR__, "w3c", "suite")

# Per-suite (relative manifest path, minimum passing tests). Floors are the
# current achieved pass counts; raise them as conformance improves.
const _W3C_SUITES = [
    # RDF 1.1 syntax
    ("Turtle",            "rdf/rdf11/rdf-turtle/manifest.ttl",               313),
    ("N-Triples",         "rdf/rdf11/rdf-n-triples/manifest.ttl",            70),
    ("N-Quads",           "rdf/rdf11/rdf-n-quads/manifest.ttl",              87),
    ("TriG",              "rdf/rdf11/rdf-trig/manifest.ttl",                 356),
    ("RDF/XML",           "rdf/rdf11/rdf-xml/manifest.ttl",                  166),
    # RDF 1.2 / RDF-star
    ("RDF1.2 Turtle",     "rdf/rdf12/rdf-turtle/manifest.ttl",               416),
    ("RDF1.2 TriG",       "rdf/rdf12/rdf-trig/manifest.ttl",                 416),
    ("RDF1.2 N-Triples",  "rdf/rdf12/rdf-n-triples/manifest.ttl",            140),
    ("RDF1.2 N-Quads",    "rdf/rdf12/rdf-n-quads/manifest.ttl",              155),
    ("RDF1.2 RDF/XML",    "rdf/rdf12/rdf-xml/manifest.ttl",                  197),
    # RDF canonicalization (RDFC-1.0)
    ("c14n N-Triples",    "rdf/rdf12/rdf-n-triples/c14n/manifest.ttl",       41),
    ("c14n N-Quads",      "rdf/rdf12/rdf-n-quads/c14n/manifest.ttl",         41),
    # RDF semantics / entailment
    ("RDF-MT entailment", "rdf/rdf11/rdf-mt/manifest.ttl",                   48),
    ("RDF1.2 semantics",  "rdf/rdf12/rdf-semantics/manifest.ttl",            77),
    # SPARQL
    ("SPARQL 1.0",        "sparql/sparql10/manifest.ttl",                    482),
    ("SPARQL 1.1 query",  "sparql/sparql11/manifest-sparql11-query.ttl",     328),
    ("SPARQL 1.1 update", "sparql/sparql11/manifest-sparql11-update.ttl",    157),
    ("SPARQL 1.2",        "sparql/sparql12/manifest.ttl",                    269),
    ("SPARQL CSV/TSV",    "sparql/sparql11/csv-tsv-res/manifest.ttl",        6),
    ("SPARQL JSON",       "sparql/sparql11/json-res/manifest.ttl",           4),
    # Entailment floor is 66 hermetically; 70 once the (network-fetched) RIF rule
    # documents are present — see the adaptive bump below.
    ("SPARQL entailment", "sparql/sparql11/entailment/manifest.ttl",         66),
]

# The 4 RIF entailment tests need rule documents fetched from the W3C site (see
# fetch.jl). When present, all 70 entailment tests pass; otherwise the RIF tests
# skip and the floor stays at 66.
_rif_docs_present() =
    isfile(joinpath(_W3C_SUITE, "sparql", "sparql11", "entailment", "rif01.rif"))

@testset "W3C conformance" begin
    if !isdir(_W3C_SUITE) || !isfile(joinpath(_W3C_SUITE, "LICENSE.md"))
        @info "W3C test suite not present — skipping conformance gate. " *
              "Run `julia --project=. test/w3c/fetch.jl` to enable it."
        @test_skip true
    else
        include(joinpath(@__DIR__, "w3c", "manifest_runner.jl"))
        Logging.disable_logging(Logging.Warn)  # parsers @warn per bad line during negative tests
        for (label, rel, floor) in _W3C_SUITES
            @testset "$label" begin
                outs = Main.W3CHarness.run_manifest(joinpath(_W3C_SUITE, rel))
                s = Main.W3CHarness.summarize(outs)
                p = get(s, :pass, 0)
                @info "W3C $label" pass=p fail=get(s,:fail,0) error=get(s,:error,0) skip=get(s,:skip,0) total=length(outs)
                eff_floor = (label == "SPARQL entailment" && _rif_docs_present()) ? 70 : floor
                @test p >= eff_floor
            end
        end
    end
end
