# Specify functions you want to extend with multidispatch

# Verticies in all graphs share same properties
# This must be defined before importing any graphs
# Individual graphs have their own edge properties
DEFAULT_VERTEX_PROPERTIES = Dict(
    :name => "0",
    :original_numbers => Set(0),
    :activation => 0,
    :removed => false,
)

M = 40

mutable struct EpsilonNetwork
    prw::MetaDiGraph
    paw::MetaDiGraph
    stm::Set{Int}
    predicted::Set{Int}
    removed_neurons::Set{Int}
    snap_map::Dict{Int, Int}
    time_step::Int
end


function EpsilonNetwork(x::Int)
    snap_map = Dict(i => i for i in 1:x)
    en = EpsilonNetwork(
        MetaDiGraph(), # prw
        MetaDiGraph(), # paw
        Set(),         # stm
        Set(),         # predicted
        Set(),         # removed neurons
        snap_map,      # snap_map
        1,             # timestep
    )
    for i in 1:x
        add_neuron!(en)
    end
    return en
end


include("./prediction-weights.jl")
include("./pattern-weights.jl")

# iterable of all metadigraphs in epsilon network
networks(en::EpsilonNetwork) = (en.prw, en.paw)
is_directed(en::EpsilonNetwork) = true
# nodes in all graphs are identical, so we just get the props of node v in the first graph
props(en::EpsilonNetwork, v::Int) = props(networks(en)[1], v)
get_prop(en::EpsilonNetwork, v::Int, prop::Symbol) = get_prop(networks(en)[1], v, prop)
neurons(en::EpsilonNetwork) = [v for v in vertices(networks(en)[1]) if !removed(v, en)]
is_active(en::EpsilonNetwork, v::Int) = Bool(get_prop(networks(en)[1], v, :activation))
active_neurons(en::EpsilonNetwork) = [v for v in vertices(networks(en)[1]) if !removed(v, en) && is_active(en, v)]
nv(en::EpsilonNetwork) = nv(networks(en)[1])
deactivate_neuron!(en::EpsilonNetwork, v::Int) = set_prop!(en, v, :activation, 0)
valid_edge(mg::MetaDiGraph,e::SimpleEdge) = !removed(e.src, mg) && !removed(e.dst, mg)
valid_edge(en::EpsilonNetwork,e::SimpleEdge) = any([valid_edge(mg, e) for mg in networks(en)])
valid_edges(mg::MetaDiGraph) = [e for e in edges(mg) if valid_edge(mg, e)]
removed(v::Int, en::EpsilonNetwork) = in(v, en.removed_neurons)
removed(v::Int, mg::MetaDiGraph) = get_prop(mg, v, :removed)

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
        set_prop!(weight_graph, nv(en), :original_numbers, Set(nv(en)))
    end
    return nv(networks(en)[1])
end

function compute_predictions!(en::EpsilonNetwork)
    empty!(en.predicted)
    for neuron in active_neurons(en)
        for pred in outneighbors(en.prw, neuron)
            set_prop!(en.prw, neuron, pred, :activation, 1)
            if PrW(en.prw, neuron, pred) > 0.8
                push!(en.predicted, pred)
            end
        end
    end
end


# Create prediction weights if possible, else create pattern weights
# Assumes a neuron is surprised
function create_connections!(en::EpsilonNetwork, neuron::Int)
    @assert get_prop(en, neuron, :activation) == 1
    neuron ∈ en.predicted && return false
    new_prws::Int = 0
    # @debug "stm" en.stm
    for prev_neuron in en.stm
        new_prws += add_prw!(en.prw, prev_neuron, neuron)
    end
    # TODO make this not occur when successfully predicted
    # Create pattern weight
    if new_prws == 0 && length(en.stm) > 1
        new_paw::Int = create_pattern_weight(en, inneighbors(en.prw, neuron), neuron)
        if new_paw == 0
            update_pattern_weights(en, neuron)
        end
    end
    return true
end


function process_input!(en::EpsilonNetwork, input_vector::Vector{Int})
    @debug "Beginning timestep " en.time_step
    for input in input_vector
        @debug input en.snap_map[input]
        neuron = en.snap_map[input]
        if !is_active(en, neuron)
            activate_neuron!(en, neuron)
        end
    end

    activate_PaW!(en)

    @debug active_neurons(en)
    for neuron in active_neurons(en)
        if neuron ∉ en.predicted
            create_connections!(en, neuron)
        end
    end

    activate_PrW!(en)

    empty!(en.stm)
    compute_predictions!(en)
    @debug "predictions:" en.predicted

    for neuron in active_neurons(en)
        push!(en.stm, neuron)
        deactivate_neuron!(en, neuron)
    end

    if en.time_step % 50 == 0
        snap!(en)
    end
    en.time_step += 1
end


# Functions to act on all graphs in the epsilon network
function activate_neuron!(en::EpsilonNetwork, v::Int)
    set_prop!(en, v, :activation, 1)
    # if get_prop(en, v, :age) < M # M=20 from paper
    #     update_prop!(en, v, :age, x->x+1)
    # end
    # If neuron is not predicted, add prw
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


# Make a new neuron with the average prw props of vs
function create_merged_vertex!(en::EpsilonNetwork, vs::Vector{Int})
    neuron = add_neuron!(en)
    og_numbers::Vector{Int} = [n for n in union([get_prop(en, v, :original_numbers) for v in vs]...)]
    set_prop!(en, neuron, :original_numbers, Set(og_numbers))
    name = string("{",[string(v, ", ") for v in og_numbers[1:end-1]]...,string(og_numbers[end]),"}")
    rename_neuron!(en, neuron, name)
    for weight_graph in networks(en)
        all_out_neighbors::Set{Int} = [outneighbors(weight_graph, v) for v in vs] |> x->cat(x..., dims=1) |> Set
        all_in_neighbors::Set{Int}  = [inneighbors(weight_graph, v) for v in vs] |> x->cat(x..., dims=1) |> Set
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

            new_edge_props = copy(DEFAULT_PRW_PROPERTIES)
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
            
            new_edge_props = copy(DEFAULT_PRW_PROPERTIES)
            new_edge_props[:age] = average_prop(current_edges, :age)
            new_edge_props[:value] = average_prop(current_edges, :value)

            add_edge!(weight_graph, in_neighbor, neuron, new_edge_props)
        end
    end
    return neuron
end


function snap!(en::EpsilonNetwork)
    similar_neurons = Vector{Vector{Int}}()
    snap_map::Dict{Int,Int} = Dict()
    for neuron in neurons(en)
        found_snap_group = false
        for (j, neuron_group) in enumerate(similar_neurons)
            if is_similar(en.prw, neuron, neuron_group[1])
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
        if length(snap_set) > 1
            new_neuron::Int = create_merged_vertex!(en, snap_set)
            for original_number in get_prop(en, new_neuron, :original_numbers)
                snap_map[original_number] = new_neuron
            end
            snap_map[new_neuron] = new_neuron
            for neuron in snap_set
                remove_neuron!(en, neuron)
            end
        else
            for neuron in snap_set
                if !get_prop(en, neuron, :removed)
                    snap_map[neuron] = neuron
                end
            end
        end
    end
    @debug snap_map
    merge!(en.snap_map, snap_map)
end

function determine_edge_color(en::EpsilonNetwork, e::SimpleEdge)::String
    has_edge(en.paw, e) ? "red" : "lightblue"
end

function determine_edge_label(en::EpsilonNetwork, e::SimpleEdge)::String
    has_edge(en.paw, e) ? w(en, e.src, e.dst) |> string : string(PrW(en.prw, e; one_decimal=true))
end

function remove_invalid_edges!(en::EpsilonNetwork)
    for net in networks(en)
        # make a copy of the edges since the iterator
        # would change if we remove them during floop
        es = edges(net) |> collect
        for edge in es
            if !valid_edge(net, edge)
                rem_edge!(net, edge)
            end
        end
    end
end

function draw_en(filename::String, en::EpsilonNetwork; hide_small_predictions::Bool=true)
    # We heavily modify structure of EN to make it suitable for printing
    en2 = deepcopy(en)
    # Remove PrW with small probabilities
    hide_small_predictions && rem_small_prw!(en2.prw)

    # Get rid of all bad edges
    remove_invalid_edges!(en2)
    for edge in edges(en2.prw)
        @assert valid_edge(en2.prw, edge)
        @assert !removed(edge.src, en2.prw) && !removed(edge.dst, en2.prw)
        @assert !removed(edge.src, en2.prw)
        @assert !removed(edge.dst, en2.prw)
    end

    nodelabels = [get_prop(en2, n, :name) for n in neurons(en2)]

    # We use this to instead of the subgraph of non-removed neurons in order
    # to keep the node information of the edges when making labels and colors
    giga_graph = union([net.graph for net in networks(en2)]...)

    prw_visible_graph = induced_subgraph(en2.prw, neurons(en2))[1]
    paw_visible_graph = induced_subgraph(en2.paw, neurons(en2))[1]
    #gplot(g, edgestrokec = ["red", "red", "blue", "blue"])
    visible_en_graph = union(prw_visible_graph.graph, paw_visible_graph.graph)
    @assert ne(visible_en_graph) == ne(giga_graph)

    edgelabels = [determine_edge_label(en2, e) for e in edges(giga_graph)]
    edge_colors = [determine_edge_color(en2, e) for e in edges(giga_graph)]

    draw(
        PDF(filename, 16cm, 16cm),
        gplot(visible_en_graph,
            layout=circular_layout,
            nodelabel=nodelabels,
            edgelabel=edgelabels,
            edgestrokec=edge_colors,
            linetype=curve)
    )

end
