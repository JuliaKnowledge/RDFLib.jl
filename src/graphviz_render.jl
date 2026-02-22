# ─── GraphViz.jl Rendering Integration ──────────────────────────────

import GraphViz

"""
    render_dot(dot_string::AbstractString; format::Symbol=:svg) -> Vector{UInt8}

Render a DOT string to the given format using GraphViz.jl.
Supported formats: `:svg`. For `:png` and `:pdf`, falls back to the
system `dot` command.
"""
function render_dot(dot_string::AbstractString; format::Symbol=:svg)
    if format === :svg
        gv = GraphViz.Graph(dot_string)
        GraphViz.layout!(gv, engine="dot")
        buf = IOBuffer()
        GraphViz.render(buf, gv)
        return take!(buf)
    else
        # Use system dot command for png/pdf
        fmt_str = String(format)
        out = IOBuffer()
        try
            run(pipeline(`dot -T$fmt_str`, stdin=IOBuffer(dot_string), stdout=out))
        catch e
            error("Failed to run Graphviz `dot` command for format $fmt_str. Is Graphviz installed? ($e)")
        end
        return take!(out)
    end
end

"""
    render_graph(g::RDFGraph; format::Symbol=:svg, label::AbstractString="RDF Graph") -> Vector{UInt8}

Render an RDF graph visualization to the given format.
"""
function render_graph(g::RDFGraph; format::Symbol=:svg, label::AbstractString="RDF Graph")
    dot = to_dot(g; label=label)
    render_dot(dot; format=format)
end

"""
    render_schema(g::RDFGraph; format::Symbol=:svg, label::AbstractString="RDFS Schema") -> Vector{UInt8}

Render an RDFS/OWL schema visualization to the given format.
"""
function render_schema(g::RDFGraph; format::Symbol=:svg, label::AbstractString="RDFS Schema")
    dot = rdfs2dot(g; label=label)
    render_dot(dot; format=format)
end

"""
    save_visualization(g::RDFGraph, filename::AbstractString;
                       format::Union{Symbol,Nothing}=nothing,
                       schema::Bool=false,
                       label::Union{AbstractString,Nothing}=nothing)

Save a graph visualization to a file. Auto-detects format from extension
if `format` is not specified. Uses `rdfs2dot` when `schema=true`, otherwise `to_dot`.
"""
function save_visualization(g::RDFGraph, filename::AbstractString;
                            format::Union{Symbol,Nothing}=nothing,
                            schema::Bool=false,
                            label::Union{AbstractString,Nothing}=nothing)
    if isnothing(format)
        ext = lowercase(splitext(filename)[2])
        format = if ext == ".svg"
            :svg
        elseif ext == ".png"
            :png
        elseif ext == ".pdf"
            :pdf
        elseif ext == ".dot"
            :dot
        else
            throw(ArgumentError("Cannot detect format from extension: $ext"))
        end
    end

    lbl = isnothing(label) ? (schema ? "RDFS Schema" : "RDF Graph") : label

    if format === :dot
        dot = schema ? rdfs2dot(g; label=lbl) : to_dot(g; label=lbl)
        open(filename, "w") do io
            write(io, dot)
        end
    else
        data = schema ? render_schema(g; format=format, label=lbl) :
                        render_graph(g; format=format, label=lbl)
        open(filename, "w") do io
            write(io, data)
        end
    end
    filename
end
