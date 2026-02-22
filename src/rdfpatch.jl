# ─── RDF Patch Format ─────────────────────────────────────────────────
# Line-based format for expressing changes to an RDF graph.
# Lines: A <s> <p> <o> .  (add)
#        D <s> <p> <o> .  (delete)
#        TX  (start transaction)
#        TC  (commit transaction)
#        TA  (abort transaction)

"""
    serialize_rdfpatch(additions::Vector{Triple}, deletions::Vector{Triple}) -> String

Serialize additions and deletions as RDF Patch format.
"""
function serialize_rdfpatch(additions::Vector{Triple}, deletions::Vector{Triple})
    buf = IOBuffer()
    write(buf, "TX .\n")
    for t in additions
        write(buf, "A ")
        _write_patch_triple(buf, t)
    end
    for t in deletions
        write(buf, "D ")
        _write_patch_triple(buf, t)
    end
    write(buf, "TC .\n")
    String(take!(buf))
end

function _write_patch_triple(io::IO, t::Triple)
    write(io, n3(t.subject))
    write(io, " ")
    write(io, n3(t.predicate))
    write(io, " ")
    write(io, n3(t.object))
    write(io, " .\n")
end

"""
    parse_rdfpatch(str::AbstractString) -> (additions, deletions)

Parse an RDF Patch string, returning vectors of additions and deletions.
"""
function parse_rdfpatch(str::AbstractString)
    additions = Triple[]
    deletions = Triple[]
    for line in split(str, '\n')
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, '#') && continue
        if stripped in ("TX .", "TC .", "TA .", "TX", "TC", "TA")
            continue
        end
        if startswith(stripped, "A ")
            triple_str = strip(stripped[3:end])
            push!(additions, _parse_patch_triple(triple_str))
        elseif startswith(stripped, "D ")
            triple_str = strip(stripped[3:end])
            push!(deletions, _parse_patch_triple(triple_str))
        end
    end
    (additions, deletions)
end

function _parse_patch_triple(s::AbstractString)
    # Remove trailing " ."
    if endswith(s, " .")
        s = s[1:end-2]
    elseif endswith(s, ".")
        s = s[1:end-1]
    end
    s = strip(s)
    # Parse as N-Triples line by adding " ."
    g = parse_rdf(s * " .\n", NTriplesFormat())
    ts = collect(g)
    isempty(ts) && throw(ArgumentError("Failed to parse RDF Patch triple: $s"))
    ts[1]
end

"""
    apply_rdfpatch!(g::RDFGraph, patch::AbstractString) -> RDFGraph

Apply an RDF Patch to a graph: add additions, remove deletions.
"""
function apply_rdfpatch!(g::RDFGraph, patch::AbstractString)
    additions, deletions = parse_rdfpatch(patch)
    for t in deletions
        remove!(g, t)
    end
    for t in additions
        add!(g, t)
    end
    g
end
