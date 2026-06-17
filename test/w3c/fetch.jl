# Fetch the official W3C rdf-tests suite into test/w3c/suite/ (gitignored).
#
# Usage:  julia --project=. test/w3c/fetch.jl
#
# The suite is pinned to a known commit for reproducibility. Re-running updates
# to that commit. The conformance tests (test/test_w3c_conformance.jl) run only
# when this directory is present; otherwise they skip with a pointer here.

const RDF_TESTS_REPO = "https://github.com/w3c/rdf-tests"
const RDF_TESTS_COMMIT = "f172950b7c8b42a7d2618a7905bba521847249b1"

const SUITE_DIR = joinpath(@__DIR__, "suite")

# ─── RIF Core entailment documents ──────────────────────────────────────────
#
# The 4 SPARQL `ent:RIF` entailment tests (rif01/03/04/06) reference rule
# documents (`.rif`) and external import data that are NOT in the rdf-tests
# repository — they live in the W3C dataset-12 / RIF test repositories. We
# download them next to the entailment manifest so the RIF tests run offline.

const ENT_DIR = joinpath(SUITE_DIR, "sparql", "sparql11", "entailment")
const RIF_CACHE_DIR = joinpath(ENT_DIR, "_rif_cache")

# rule document IRI → local filename (as referenced by the *.ttl data files).
const RIF_RULE_DOCS = [
    "https://www.w3.org/2009/sparql/docs/tests/data-sparql11/entailment/rif01.rif" => "rif01.rif",
    "https://www.w3.org/2009/sparql/docs/tests/data-sparql11/entailment/Frames-premise.rif" => "Frames-premise.rif",
    "https://www.w3.org/2009/sparql/docs/tests/data-sparql11/entailment/Modeling_Brain_Anatomy-premise.rif" => "Modeling_Brain_Anatomy-premise.rif",
    "https://www.w3.org/2009/sparql/docs/tests/data-sparql11/entailment/RDF_Combination_Blank_Node-premise.rif" => "RDF_Combination_Blank_Node-premise.rif",
]

# External RDF data imported by the rule documents (rif04 = RDF/XML brain
# ontology, rif06 = a Turtle blank-node fact). Cached under _rif_cache/ keyed by
# a sanitized URL, matching src/rif.jl's `_rif_cache_name`.
const RIF_IMPORTS = [
    "http://www.w3.org/2005/rules/test/repository/tc/Modeling_Brain_Anatomy/Modeling_Brain_Anatomy-import001.rdf",
    "http://www.w3.org/2005/rules/test/repository/tc/RDF_Combination_Blank_Node/RDF_Combination_Blank_Node-import001",
]

_rif_cache_name(url::AbstractString) = replace(String(url), r"[^A-Za-z0-9._-]" => "_")

function _try_download(url, dest)
    try
        download(url, dest)
        return true
    catch e
        @warn "could not download $url: $(e)"
        return false
    end
end

function fetch_rif_docs()
    isdir(ENT_DIR) || (@warn "entailment dir missing: $ENT_DIR"; return)
    for (url, fname) in RIF_RULE_DOCS
        dest = joinpath(ENT_DIR, fname)
        isfile(dest) && continue
        _try_download(url, dest) && println("  fetched $fname")
    end
    mkpath(RIF_CACHE_DIR)
    for url in RIF_IMPORTS
        dest = joinpath(RIF_CACHE_DIR, _rif_cache_name(url))
        isfile(dest) && continue
        if _try_download(url, dest)
            # Record an empty content-type marker so the loader sniffs the syntax.
            isfile(dest * ".ct") || write(dest * ".ct", "")
            println("  cached import $(basename(url))")
        end
    end
end

function main()
    if isdir(SUITE_DIR) && isfile(joinpath(SUITE_DIR, "LICENSE.md"))
        println("W3C suite already present at $SUITE_DIR")
        println("Delete it and re-run to refresh, or run the git steps below manually.")
        fetch_rif_docs()
        return
    end
    mktempdir() do tmp
        clone = joinpath(tmp, "rdf-tests")
        run(`git clone --filter=blob:none $RDF_TESTS_REPO $clone`)
        run(Cmd(`git checkout $RDF_TESTS_COMMIT`, dir = clone))
        rm(joinpath(clone, ".git"); recursive = true, force = true)
        mkpath(dirname(SUITE_DIR))
        mv(clone, SUITE_DIR)
    end
    println("Fetched W3C rdf-tests @ $RDF_TESTS_COMMIT into $SUITE_DIR")
    fetch_rif_docs()
end

using Downloads: download
main()
