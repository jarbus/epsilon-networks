# Specify functions you want to extend with multidispatch for some reason
import MetaGraphs: AbstractMetaGraph, PropDict, MetaDict, set_prop!, get_prop, props, rem_vertex!, add_vertex!, merge_vertices!, add_edge!, nv

# Verticies in all graphs share same properties
# This must be defined before importing any graphs
# Individual graphs have their own edge properties
DEFAULT_VERTEX_PROPERTIES = Dict(
    :name => "0",
    :activation => 0,
    :age => 0,
    :value => 0,
    :removed => false,
)

include("./prediction-weights.jl")

mutable struct EpsilonNetwork
    prw::MetaDiGraph
    removed_neurons::Set{Int}
end

# iterable of all metadigraphs in epsilon network
networks(en::EpsilonNetwork) = (en.prw,)
is_directed(en::EpsilonNetwork) = true
# nodes in all graphs are identical, so we just get the props of node v in the first graph
props(en::EpsilonNetwork, v::Int) = props(networks(en)[1], v)
get_prop(en::EpsilonNetwork, v::Int, prop::Symbol) = get_prop(networks(en)[1], v, prop)
neurons(en::EpsilonNetwork) = [v for v in vertices(networks(en)[1]) if not_removed(v, en)]
nv(en::EpsilonNetwork) = nv(networks(en)[1])
is_active(en::EpsilonNetwork, v::Int) = Bool(get_prop(networks(en)[1], v, :activation))
increment_age!(en::EpsilonNetwork, v::Int) = update_prop!(en, v, :age, x-> x+1)
increment_value!(en::EpsilonNetwork, v::Int) = update_prop!(en, v, :value, x -> x+1)
deactivate_neuron!(en::EpsilonNetwork, v::Int) = set_prop!(en, v, :activation, 0)
valid_edges(mg::MetaDiGraph) = [e for e in edges(mg) if not_removed(e.src, en) && not_removed(e.dst, en)]
not_removed(v::Int, en) = !in(v, en.removed_neurons)

function update_prop!(en::EpsilonNetwork, v::Int, prop::Symbol, func::Function)
    for weight_graph in networks(en)
        set_prop!(weight_graph, v, prop, func(get_prop(weight_graph, v, prop)))
    end
end


function update_prop!(mg::AbstractMetaGraph, v1::Int, v2::Int, prop::Symbol, func::Function)
    set_prop!(mg, v1, v2, prop, func(get_prop(mg, v1, v2, prop)))
end


function add_neuron!(en::EpsilonNetwork)
    for weight_graph in networks(en)
        add_vertex!(weight_graph, copy(DEFAULT_VERTEX_PROPERTIES))
        set_prop!(weight_graph, nv(en), :name, string(nv(en)))
    end
    return nv(networks(en)[1])
end


function EpsilonNetwork(x::Int)
    en = EpsilonNetwork(MetaDiGraph(), Set{Int}())
    for i in 1:x
        add_neuron!(en)
    end
    return en
end


# Functions to act on all graphs in the epsilon network
function activate_neuron!(en::EpsilonNetwork, v::Int)
    set_prop!(en, v, :activation, 1)
    update_prop!(en, v, :age, x->x+1)
end


function remove_neuron!(en::EpsilonNetwork, v::Int)
    for weight_graph in networks(en)
        for neighbor in inneighbors(weight_graph, v)
            rem_edge!(weight_graph, neighbor, v)
        end
        for neighbor in outneighbors(weight_graph, v)
            rem_edge!(weight_graph, v, neighbor)
        end
        set_prop!(weight_graph, v, :removed, true)
        push!(en.removed_neurons, v)
    end
end


function set_prop!(en::EpsilonNetwork, args...)
    for weight_graph in networks(en)
        set_prop!(weight_graph, args...)
    end
end

# Helper functions used in create_merged_vertex
rename_neuron!(en::EpsilonNetwork, v::Int, name::String) = set_prop!(en, v, :name, name)
mean(x::Vector) = sum(x)/length(x)
average_prop(prop_dicts::Vector{Dict{Symbol, Any}}, prop::Symbol)::Int = mean([d[prop] for d in prop_dicts]) |> x -> round(Int, x)


function create_merged_vertex!(en::EpsilonNetwork, vs::Vector{Int})
    # Make a new neuron with the average props of vs
    neuron = add_neuron!(en)
    set_prop!(en, neuron, :age, average_prop([props(networks(en)[1], v) for v in vs], :age))
    set_prop!(en, neuron, :value, average_prop([props(networks(en)[1], v) for v in vs], :value))
    name = string("{",[string(v, ", ") for v in vs[1:end-1]]...,string(vs[end]),"}")
    rename_neuron!(en, neuron, name)
    for weight_graph in networks(en)
        all_out_neighbors = [outneighbors(weight_graph, v) for v in vs] |> x->cat(x..., dims=1) |> Set
        all_in_neighbors  = [inneighbors(weight_graph, v) for v in vs] |> x->cat(x..., dims=1) |> Set
        for out_neighbor in all_out_neighbors
            # merge all props that go from one node into to multiple nodes in vs
            #
            #  vs[1]
            #       \
            #        V                         new_edge
            #        u    =======>  new neuron ---------> u
            #        ^
            #       /
            #  vs[2]
            #
            current_edges = [
                    props(weight_graph, v, out_neighbor)
                    for v in vs if has_edge(weight_graph, v, out_neighbor)
            ]

            new_edge_props = copy(DEFAULT_EDGE_PROPERTIES)
            new_edge_props[:age] = average_prop(current_edges, :age)
            new_edge_props[:value] = average_prop(current_edges, :value)
            add_edge!(weight_graph, neuron, out_neighbor, new_edge_props)
        end
        for in_neighbor in all_in_neighbors

            # merge all props that go from one node into to multiple nodes in vs
            #
            #    vs[1]
            #     ^
            #    /                     new_edge
            #  u          =======>  u ----------> new neuron
            #    \
            #     V
            #     vs[2]
            #
            current_edges = [
                props(weight_graph, in_neighbor, v)
                for v in vs if has_edge(weight_graph, in_neighbor, v)
            ]
            new_edge_props = copy(DEFAULT_EDGE_PROPERTIES)
            new_edge_props[:age] = average_prop(current_edges, :age)
            new_edge_props[:value] = average_prop(current_edges, :value)

            add_edge!(weight_graph, in_neighbor, neuron, new_edge_props)
        end
    end
end


function snap!(prw::MetaDiGraph)
    similar_neurons = Vector{Vector{Int}}()
    for neuron in neurons(prw)
        found_snap_group = false
        for (j, neuron_group) in enumerate(similar_neurons)
            if is_similar(prw, neuron, neuron_group[1])
                push!(similar_neurons[j], neuron)
                found_snap_group = true
                break
            end
        end
        if !found_snap_group
            push!(similar_neurons, [neuron])
        end
    end
    for snap_set in similar_neurons
        println("snapping ", snap_set)
        if length(snap_set) > 1
            create_merged_vertex!(en, snap_set)
            for neuron in snap_set
                remove_neuron!(en, neuron)
            end
        end
    end
end

function draw_en(en::EpsilonNetwork)
    # Draw all nodes in en
    nodelabels =
    [   get_prop(en, n, :name)
        for n in neurons(en) ]

    edgelabels =
    [   PrW(en.prw, edge.src, edge.dst)
        for edge in valid_edges(en.prw)]
    subgraph = induced_subgraph(en.prw, [n for n in neurons(en) if !get_prop(en.prw, n, :removed)])[1]
    draw(PDF("prw.pdf", 16cm, 16cm), gplot(subgraph, nodelabel=nodelabels, edgelabel=edgelabels))

end
