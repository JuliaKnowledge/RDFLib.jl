# ─── SPARQL Results TSV Format ────────────────────────────────────────
# Tab-separated values format for SPARQL query results.

"""
    sparql_results_tsv(results; variables=nothing) -> String

Serialize SPARQL query results to TSV (SPARQL Results TSV format).
`results` can be a `Vector{Dict{String,Identifier}}` (SELECT) or `Bool` (ASK).
"""
function sparql_results_tsv(results; variables=nothing)
    if results isa Bool
        return results ? "true" : "false"
    end

    vars = if !isnothing(variables)
        variables
    elseif !isempty(results)
        sort(collect(keys(results[1])))
    else
        String[]
    end

    buf = IOBuffer()
    # Header: tab-separated ?var names
    println(buf, join(["?" * v for v in vars], "\t"))
    for row in results
        vals = String[]
        for v in vars
            val = get(row, v, nothing)
            if isnothing(val)
                push!(vals, "")
            elseif val isa URIRef
                push!(vals, "<" * val.value * ">")
            elseif val isa BNode
                push!(vals, "_:" * val.id)
            elseif val isa Literal
                push!(vals, n3(val))
            else
                push!(vals, string(val))
            end
        end
        println(buf, join(vals, "\t"))
    end
    String(take!(buf))
end
