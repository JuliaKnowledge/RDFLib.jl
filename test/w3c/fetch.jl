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

function main()
    if isdir(SUITE_DIR) && isfile(joinpath(SUITE_DIR, "LICENSE.md"))
        println("W3C suite already present at $SUITE_DIR")
        println("Delete it and re-run to refresh, or run the git steps below manually.")
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
end

main()
