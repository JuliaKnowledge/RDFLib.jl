# Run one W3C suite and print pass/fail/error/skip + every non-pass test.
# Usage: julia --project=. test/w3c/run_suite.jl <suite-relative-manifest-path>
using Logging; Logging.disable_logging(Logging.Warn)   # parsers @warn per bad line; suppress
using RDFLib
include(joinpath(@__DIR__, "manifest_runner.jl"))
using .W3CHarness
rel = isempty(ARGS) ? "rdf/rdf11/rdf-turtle/manifest.ttl" : ARGS[1]
path = joinpath(@__DIR__, "suite", rel)
outs = W3CHarness.run_manifest(path)
s = W3CHarness.summarize(outs)
println("pass=", get(s,:pass,0), " fail=", get(s,:fail,0),
        " error=", get(s,:error,0), " skip=", get(s,:skip,0), " / ", length(outs))
for o in outs
    o.status in (:fail,:error) || continue
    println(o.status, "\t", o.type, "\t", o.name, "\t", replace(first(o.detail,150), '\n'=>' '))
end
