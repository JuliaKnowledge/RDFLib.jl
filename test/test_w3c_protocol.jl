# Official W3C SPARQL Protocol / Graph Store Protocol / Service Description
# conformance gate.
#
# Starts a live RDFLib `SparqlServer` on an ephemeral localhost port and replays
# the official W3C HTTP-in-RDF protocol test manifests against it over real HTTP
# (see test/w3c/protocol_runner.jl), asserting each suite meets a recorded
# pass-count floor (so conformance can only improve, never regress).
#
# As with the RDF/SPARQL conformance gate, the suite is not vendored into the
# repo. When test/w3c/suite is absent (e.g. ordinary CI) these tests SKIP with a
# pointer rather than fail (mirroring test_w3c_conformance.jl).

using Test
using RDFLib
using Logging

const _W3C_PROTO_SUITE = joinpath(@__DIR__, "w3c", "suite")

# Per-suite (relative manifest path, minimum passing tests). Floors are the
# current achieved pass counts; raise them as conformance improves.
const _W3C_PROTO_SUITES = [
    ("SPARQL 1.1 Protocol",            "sparql/sparql11/protocol/manifest.ttl",             34),
    ("SPARQL 1.1 Graph Store Protocol","sparql/sparql11/graph-store-protocol/manifest.ttl",  12),
    ("SPARQL 1.1 Service Description", "sparql/sparql11/service-description/manifest.ttl",     3),
]

@testset "W3C protocol conformance" begin
    if !isdir(_W3C_PROTO_SUITE) || !isfile(joinpath(_W3C_PROTO_SUITE, "LICENSE.md"))
        @info "W3C test suite not present — skipping protocol conformance gate. " *
              "Run `julia --project=. test/w3c/fetch.jl` to enable it."
        @test_skip true
    else
        include(joinpath(@__DIR__, "w3c", "protocol_runner.jl"))
        Logging.disable_logging(Logging.Warn)
        for (label, rel, floor) in _W3C_PROTO_SUITES
            manifest = joinpath(_W3C_PROTO_SUITE, rel)
            @testset "$label" begin
                if !isfile(manifest)
                    @info "manifest missing — skipping" manifest
                    @test_skip true
                    continue
                end
                outs = Main.ProtocolHarness.run_manifest(manifest)
                s = Main.ProtocolHarness.summarize(outs)
                p = get(s, :pass, 0)
                @info "W3C $label" pass=p fail=get(s,:fail,0) error=get(s,:error,0) skip=get(s,:skip,0) total=length(outs)
                for o in outs
                    o.status in (:fail, :error) || continue
                    @info "  non-pass" status=o.status name=o.name detail=first(o.detail, 200)
                end
                @test p >= floor
            end
        end
    end
end
