__precompile__(true)

"""
    RootsAndPoles.jl

`RootsAndPoles` is a Julia implementation of the Global complex Roots and Poles Finding
(GRPF) algorithm.

Matlab code is available under MIT license at https://github.com/PioKow/GRPF.

# References

[^1]: P. Kowalczyk, “Global complex roots and poles finding algorithm based on phase
    analysis for propagation and radiation problems,” IEEE Transactions on Antennas and
    Propagation, vol. 66, no. 12, pp. 7198–7205, Dec. 2018, doi: 10.1109/TAP.2018.2869213.
"""
module RootsAndPoles

#==
NOTE: Some variable conversions from the original GRPF papers to this code:

| Paper | Code |
|-------|------|
|   𝓔   |   E  |
|   𝐶   |   C  |
|   ϕ   |  phi |
==#

import Base
import Base.Threads.@threads
using LinearAlgebra
using DelaunayTriangulation
const DT = DelaunayTriangulation

"""
    GRPFParams

Struct for holding values used by `RootsAndPoles` to stop iterating or split
Delaunay triangles.

Default values are provided by `GRPFParams()`.

# Fields

- `maxiterations::Int = 100`: the maximum number of refinement iterations before `grpf`
    returns.
- `maxnodes::Int = 500000`: the maximum number of Delaunay tessalation nodes before `grpf`
    returns.
- `skinnytriangle::Int = 3`: maximum ratio of the longest to shortest side length of
    Delaunay triangles before they are split during `grpf` refinement iterations.
- `tess_sizehint::Int = 5000`: provide a size hint to the total number of expected nodes in
    the Delaunay tesselation. Setting this number approximately correct can improve
    performance.
- `tolerance::Float64 = 1e-9`: maximum allowed edge length of the tesselation defined in the
    `origcoords` domain before returning.
- `multithreading::Bool = false`: use `Threads.@threads` to run the user-provided function
    `fcn` across the `DelaunayTriangulation`.
"""
struct GRPFParams
    maxiterations::Int
    maxnodes::Int
    skinnytriangle::Int
    tess_sizehint::Int
    tolerance::Float64
    multithreading::Bool

    function GRPFParams(maxiterations, maxnodes, skinnytriangle, tess_sizehint, tolerance,
                        multithreading)
        tess_sizehint > maxnodes && @warn "GRPFParams `tess_sizehint` is greater than `maxnodes`"
        new(maxiterations, maxnodes, skinnytriangle, tess_sizehint, tolerance, multithreading)
    end
end
GRPFParams() = GRPFParams(100, 500000, 3, 5000, 1e-9, false)

"""
    GRPFParams(tess_sizehint, tolerance, multithreading=false)

Convenience function for creating a `GRPFParams` object with the most important parameters,
`tess_sizehint`, `tolerance`, and `multithreading`.
"""
GRPFParams(tess_sizehint, tolerance, multithreading=false) =
    GRPFParams(100, 500000, 3, tess_sizehint, tolerance, multithreading)

function Base.isequal(a::GRPFParams, b::GRPFParams)
    for n in fieldnames(GRPFParams)
        isequal(getfield(a,n), getfield(b,n)) || return false
    end
    return true
end
Base.:(==)(a::GRPFParams, b::GRPFParams) = isequal(a,b)

struct PlotData end

# These files need the above structs defined
include("DelaunayTriangulationExtensions.jl")
include("utils.jl")
include("coordinate_domains.jl")

export rectangulardomain, diskdomain, grpf, PlotData, getplotdata, GRPFParams

"""
    quadrant(z)

Convert complex function value `z` to quadrant number.

| Quadrant |       Phase       |
|:--------:|:-----------------:|
|    1     | 0 ≤ arg f < π/2   |
|    2     | π/2 ≤ arg f < π   |
|    3     | π ≤ arg f < 3π/2  |
|    4     | 3π/2 ≤ arg f < 2π |
"""
@inline function quadrant(z)
    r, i = reim(z)
    if r > 0 && i >= 0
        return 1
    elseif r <= 0 && i > 0
        return 2
    elseif r < 0 && i <= 0
        return 3
    else
        # r >= 0 && i < 0
        return 4
    end
end

"""
    assignquadrants!(points, f, multithreading=false)

Evaluate function `f` for [`quadrant`](@ref) at `points` and update each point in-place.
"""
function assignquadrants!(points, f, multithreading=false)
    if multithreading
        @threads for p in points
            Q = quadrant(f(complex(p)))
            setquadrant!(p, Q)
        end
    else
        for p in points
            Q = quadrant(f(complex(p)))
            setquadrant!(p, Q)
        end
    end
    return nothing
end

"""
    candidateedges!(E, tess; phasediffs=nothing)

Fill in `Vector` of candidate edges `E` that contain a phase change of 2 quadrants.

If `phasediffs` is not `nothing`, then push `|ΔQ|` of each edge to `phasediffs`.
This is useful for plotting

Any root or pole is located at the point where the regions described by four different
quadrants meet. Since any triangulation of the four nodes located in the four different
quadrants requires at least one edge of ``|ΔQ| = 2``, then all such edges are potentially in
the vicinity of a root or pole.

`E` is not sorted.
"""
function candidateedges!(E, tess; phasediffs=nothing)
    for edge in each_solid_edge(tess)
        a, b = get_point(tess, edge...)
        ΔQ = mod(getquadrant(a) - getquadrant(b), 4)  # phase difference
        if ΔQ == 2
            push!(E, edge)
        end
        if !isnothing(phasediffs)
            push!(phasediffs, ΔQ)
        end
    end
end

"""
    addzone1node!(newnodes, p, q, tolerance)

Push the midpoint of `p` and `q` into `newnodes` if the distance between them is greater
than `tolerance`.
"""
@inline function addzone1node!(newnodes, p, q, tolerance)
    if distance(p, q) > tolerance
        avgnode = (p + q)/2
        push!(newnodes, avgnode)
    end
    return nothing
end

"""
    addzone2node!(newnodes, p, q, r, skinnytriangle)

Push the average of `p`, `q`, and `r` into `newnodes`.

`skinnytriangle` is the maximum allowed ratio of the longest to shortest side length.
"""
@inline function addzone2node!(newnodes, p, q, r, skinnytriangle)
    l1 = RP.distance(p, q)
    l2 = RP.distance(p, r)
    l3 = RP.distance(q, r)
    if max(l1,l2,l3)/min(l1,l2,l3) > skinnytriangle
        avgnode = (p + q + r)/3
        push!(newnodes, avgnode)
    end
    return nothing
end

"""
    splittriangles!(zone1triangles, mesh_points, tess, edge_idxs, params)

Zone `1` triangles have more than one node in `edge_idxs`, whereas zone `2` triangles have
only a single node.
"""
function splittriangles!(tess, unique_pts, params)
    triangles = Set{DT.triangle_type(tess)}()
    edges = Set{DT.edge_type(tess)}()
    for p1 in unique_pts
        adj2v = RP.get_adjacent2vertex(tess, p1) 
        for (p2, p3) in adj2v
            sortedtri = DT.sort_triangle((p1, p2, p3))
            if sortedtri in triangles
                continue  # this triangle has already been visited
            end
            push!(triangles, sortedtri)
            p, q, r = RP.get_point(tess, p1, p2, p3)

            if p2 in unique_pts || p3 in unique_pts
                # (p1, p2, p3) is a zone 1 triangle
                # Add a new node at the midpoint of each edge of (p1, p2, p3)
                if !(sort_edge(p1, p2) in edges)
                    addzone1node!(newnodes, p, q, params.tolerance)
                    push!(edges, sort_edge(p1, p2))
                end
                if !(sort_edge(p1, p3) in edges)
                    addzone1node!(newnodes, p, r, params.tolerance)
                    push!(edges, sort_edge(p1, p3))
                end
                if !(sort_edge(p2, p3) in edges)
                    addzone1node!(newnodes, q, r, params.tolerance)
                    push!(edges, sort_edge(p2, p3))
                end
            else
                # (p1, p2, p3) is a zone 2 triangle
                # Add a new node at the average of (p1, p2, p3) 
                addzone2node!(newnodes, p, q, r, params.skinnytriangle)
            end
        end
    end
end

"""
    findnextnode(prevnode, refnode, nodes)

Find the index of the next node in `nodes` as part of the candidate region boundary process.
The next one (after the reference) is picked from the fixed set of nodes.
"""
function findnextnode(prevnode, refnode, nodes)
    P = prevnode
    S = refnode

    minphi = 2π + 1  # max diff of angles is 2π, so this is guaranteed larger
    minphi_idx = firstindex(nodes)

    for i in eachindex(nodes)
        N = nodes[i]

        SP = P - S
        SN = N - S

        phi = mod2pi(angle(SP) - angle(SN))

        if phi < minphi
            minphi = phi
            minphi_idx = i
        end
    end

    return minphi_idx
end

"""
    contouredges(tess, edges)

Find contour edges from all candidate `edges`.
"""
function contouredges(tess, edges)
    C = Vector{DelaunayEdge{IndexablePoint2D}}()
    sizehint!(C, length(edges))

    # Edges of triangles that contain at least 1 of `edges`
    for triangle in tess
        pa, pb, pc = geta(triangle), getb(triangle), getc(triangle)
        pai, pbi, pci = getindex(pa), getindex(pb), getindex(pc)

        for edge in edges
            eai, ebi = getindex(geta(edge)), getindex(getb(edge))

            if (eai == pai && ebi == pbi) || (eai == pbi && ebi == pai) ||
                (eai == pbi && ebi == pci) || (eai == pci && ebi == pbi) ||
                (eai == pci && ebi == pai) || (eai == pai && ebi == pci)
                push!(C, DelaunayEdge(pa,pb), DelaunayEdge(pb,pc), DelaunayEdge(pc,pa))
                break  # only count each triangle once
            end
        end
    end

    # Remove duplicate edges
    sameunique!(C)

    return C
end

"""
    evaluateregions!(C)
"""
function evaluateregions!(C)
    # NOTE: The nodes of each region are in reverse order compared to Matlab with respect
    # to their quadrants

    # Initialize
    numregions = 1
    regions = [[geta(C[1])]]
    refnode = getb(C[1])
    popfirst!(C)

    nextedgeidxs = similar(Array{Int}, axes(C))
    empty!(nextedgeidxs)
    while length(C) > 0

        # This loop is equivalent to `findall(e->geta(e)==refnode, C)`
        # but avoids closure Core.Box issue
        for i in eachindex(C)
            if geta(C[i]) == refnode
                push!(nextedgeidxs, i)
            end
        end

        if !isempty(nextedgeidxs)
            if length(nextedgeidxs) == 1
                nextedgeidx = only(nextedgeidxs)
            else
                prevnode = regions[numregions][end]
                tempnodes = getb.(C[nextedgeidxs])
                idx = findnextnode(prevnode, refnode, tempnodes)
                nextedgeidx = nextedgeidxs[idx]
            end

            nextedge = C[nextedgeidx]
            push!(regions[numregions], geta(nextedge))
            refnode = getb(nextedge)
            deleteat!(C, nextedgeidx)
        else # isempty
            push!(regions[numregions], refnode)
            # New region
            numregions += 1
            push!(regions, [geta(C[1])])
            refnode = getb(C[1])
            popfirst!(C)
        end

        # reset `nextedgeidxs`
        empty!(nextedgeidxs)
    end

    push!(regions[numregions], refnode)

    return regions
end

"""
    rootsandpoles(regions, quadrants)

Identify roots and poles of function based on `regions` (usually a `Vector{Vector{IndexablePoint2D}}`)
and `quadrants`.
"""
function rootsandpoles(regions, quadrants) where T
    complexT = complex(T)
    zroots = Vector{complexT}()
    zpoles = Vector{complexT}()
    for r in regions
        quadrantsequence = [quadrants[getindex(node)] for node in r]

        # Sign flip because `r` are in opposite order of Matlab?
        dq = -diff(quadrantsequence)
        for i in eachindex(dq)
            if dq[i] == 3
                dq[i] = -1
            elseif dq[i] == -3
                dq[i] = 1
            elseif abs(dq[i]) == 2
                # ``|ΔQ| = 2`` is ambiguous; cannot tell whether phase increases or
                # decreases by two quadrants
                dq[i] = 0
            end
        end
        q = sum(dq)/4
        z = sum(r)/length(r)

        if q > 0
            push!(zroots, convert(complexT, z))  # convert in case T isn't Float64
        elseif q < 0
            push!(zpoles, convert(complexT, z))
        end
    end

    return zroots, zpoles
end

"""
    tesselate!(initial_mesh, f, params, pd=nothing)

Label quadrants, identify candidate edges, and iteratively split triangles, returning
the tuple `(tess, E, quadrants, phasediffs)`.
"""
function tesselate!(initial_mesh, f, params, pd=nothing)
    E = Set{Tuple{Int, Int}}()  # edges
    selectE = Set{Tuple{Int, Int}}()
    zone1triangles = Vector{DelaunayTriangle{IndexablePoint2D}}()

    if pd isa PlotData
        phasediffs = Vector{Int}()
    else
        phasediffs = nothing
    end

    mesh_points = QuadrantPoints(QuadrantPoint.(initial_mesh))
    # tess = triangulate(mesh_points)

    iteration = 0
    while iteration < params.maxiterations && num_vertices(tess) < params.maxnodes
        iteration += 1

        # Evaluate the function `f` for the quadrant at each node
        assignquadrants!(mesh_points, f, params.multithreading)

        # Determine candidate edges that may be near a root or pole
        empty!(E)  # start with a blank E
        empty!(selectE)
        pd isa PlotData && empty!(phasediffs)
        candidateedges!(E, tess; phasediffs)
    
        isempty(E) && return tess, E, phasediffs  # no roots or poles found

        # Select candidate edges that are longer than the chosen tolerance
        maxElength = 0.0
        for e in E
            d = distance(get_point(tess, e...))
            if d > params.tolerance
                push!(selectE, e)
                if d > maxElength
                    maxElength = d
                end
            end
        end
        isempty(selectE) && return tess, E, phasediffs

        # Get unique indices of points in `edges`
        unique_pts = Set(Iterators.flatten(selectE))

        # TODO: do splitting/refinement in a dedicated function?
        # Refine (split) triangles
        empty!(mesh_points)
        empty!(zone1triangles)

        # TODO: Instead of looping over all triangles, is it possible to more directly
        # identify which triangles contain the points in unique_pts?
        splittriangles!(zone1triangles, mesh_points, tess, unique_pts, params)

        # Add new nodes in zone 1
        zone1newnodes!(newnodes, zone1triangles, params.tolerance)

        # Add new nodes to `tess`
        push!(tess, newnodes)
    end

    iteration >= params.maxiterations && @warn "params.maxiterations reached"
    numnodes >= params.maxnodes && @warn "params.maxnodes reached"

    return tess, E, quadrants, phasediffs
end

"""
    grpf(fcn, initial_mesh, params=GRPFParams())

Return a vector `roots` and a vector `poles` of a single (complex) argument function
`fcn`.

Searches within a domain specified by the vector of complex `initial_mesh`.

# Examples
```jldoctest
julia> simplefcn(z) = (z - 1)*(z - im)^2*(z + 1)^3/(z + im)

julia> xb, xe = -2, 2

julia> yb, ye = -2, 2

julia> r = 0.1

julia> initial_mesh = rectangulardomain(complex(xb, yb), complex(xe, ye), r)

julia> roots, poles = grpf(simplefcn, initial_mesh);

julia> roots
3-element Array{Complex{Float64},1}:
    -0.9999999998508017 - 8.765385802810127e-11im
 1.3587683359414186e-10 + 1.0000000001862643im
     1.0000000002536367 + 1.0339757656912847e-26im

julia> poles
1-element Array{Complex{Float64},1}:
 -2.5363675604239815e-10 - 1.0000000002980232im
```
"""
function grpf(fcn, initial_mesh, params=GRPFParams())
    tess, E, quadrants, _ = tesselate!(initial_mesh, fcn, params)

    complexT = complex(eltype(g2f))
    isempty(E) && return Vector{complexT}(), Vector{complexT}()

    C = contouredges(tess, E)
    regions = evaluateregions!(C)
    zroots, zpoles = rootsandpoles(regions, quadrants)

    return zroots, zpoles
end

"""
    grpf(fcn, origcoords, ::PlotData, params=GRPFParams())

Variant of `grpf` that returns `quadrants`, `phasediffs`, the `VoronoiDelauany`
tesselation `tess`, and the `Geometry2Function` struct `g2f` for converting from the
`VoronoiDelaunay` to function space, in addition to `zroots` and `zpoles`.

These additional outputs are primarily for plotting or diagnostics.

# Examples
```
julia> roots, poles, quadrants, phasediffs, tess = grpf(simplefcn, origcoords, PlotData());
```
"""
function grpf(fcn, origcoords, ::PlotData, params=GRPFParams())
    newnodes = reim.(origcoords)

    tess = DelaunayTessellation2D{IndexablePoint2D}(params.tess_sizehint)

    tess, E, quadrants, phasediffs = tesselate!(tess, fcn, params, PlotData())

    complexT = complex(eltype(g2f))
    isempty(E) && return (Vector{complexT}(), Vector{complexT}(), quadrants, phasediffs,
                          tess)

    C = contouredges(tess, E)
    regions = evaluateregions!(C)
    zroots, zpoles = rootsandpoles(regions, quadrants)

    return zroots, zpoles, quadrants, phasediffs, tess
end

end # module
