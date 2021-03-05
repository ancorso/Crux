const MinHeap = MutableBinaryHeap{Float32, DataStructures.FasterForward}

# Efficient inverse query for fenwick tree : adapted from https://codeforces.com/blog/entry/61364
function inverse_query(t::FenwickTree, v, N = length(t))
    tot, pos = 0, 0
    for i=floor(Int, log2(N)):-1:0
        new_pos = pos + 1 << i
        if new_pos <= N && tot + t.bi_tree[new_pos] < v
            tot += t.bi_tree[new_pos]
            pos = new_pos
        end
    end
    pos + 1
end

Base.getindex(t::FenwickTree, i::Int) = prefixsum(t, i) - prefixsum(t, i-1)

DataStructures.update!(t::FenwickTree, i, v) = inc!(t, i, v - t[i])

Base.zero(s::Type{Symbol}) = :zero # For initializing symbolic arrays

# construction of common mdp data
function mdp_data(S::T1, A::T2, capacity::Int, extras::Array{Symbol} = Symbol[]; ArrayType = Array, R = Float32, D = Bool, W = Float32) where {T1 <: AbstractSpace, T2 <: AbstractSpace}
    data = Dict{Symbol, ArrayType}(
        :s => ArrayType(fill(zero(type(S)), dim(S)..., capacity)), 
        :a => ArrayType(fill(zero(type(A)), dim(A)..., capacity)), 
        :sp => ArrayType(fill(zero(type(S)), dim(S)..., capacity)), 
        :r => ArrayType(fill(zero(R), 1, capacity)), 
        :done => ArrayType(fill(zero(D), 1, capacity))
        )
    for k in extras
        if k in [:return, :logprob, :advantage]
            data[k] = ArrayType(fill(zero(R), 1, capacity))
        elseif k in [:weight]
            data[k] = ArrayType(fill(one(R), 1, capacity))
        elseif k in [:episode_end]
            data[k] = ArrayType(fill(false, 1, capacity))
        elseif k in [:t]
            data[k] = ArrayType(fill(0, 1, capacity))
        elseif k in [:s0]
            data[k] = ArrayType(fill(zero(type(S)), dim(S)..., capacity))
        else
            error("Unrecognized key: ", k)
        end
    end
    data
end
    
## Experience Buffer stuff
@with_kw mutable struct ExperienceBuffer{T <: AbstractArray} 
    data::Dict{Symbol, T}
    elements::Int64 = 0
    next_ind::Int64 = 1
    
    indices::Vector{Int} = []
    minsort_priorities::Union{Nothing, MinHeap} = nothing
    priorities::Union{Nothing, FenwickTree} = nothing
    α::Float32 = 0.6
    β::Function = (i) -> 0.5f0
    max_priority::Float32 = 1.0
end

function buffer_like(b::ExperienceBuffer; capacity=capacity(b), device=device(b))
    data = Dict(k=>deepcopy(device(collect(bslice(v,1:capacity)))) for (k,v) in b.data)
    clear!(ExperienceBuffer(data))
end        

function ExperienceBuffer(data::Dict{Symbol, T}) where {T <: AbstractArray}
    elements = size(first(data)[2], 2)
    ExperienceBuffer(data = data, elements = elements)
end

function ExperienceBuffer(S::T1, A::T2, capacity::Int, extras::Array{Symbol} = Symbol[]; device = cpu, 
                          prioritized = false, α = 0.6f0, β = (i) -> 0.5f0, max_priority = 1f0,
                          R = Float32, D = Bool, W = Float32) where {T1 <: AbstractSpace, T2 <: AbstractSpace}
    Atype = device == gpu ? CuArray : Array
    prioritized && !(:weight in extras) && push!(extras, :weight)
    b = ExperienceBuffer(data = mdp_data(S, A, capacity, extras, ArrayType = Atype,  R = R, D = D, W = W))
    if prioritized
        b.minsort_priorities = MinHeap(fill(Inf32, capacity))
        b.priorities = FenwickTree(fill(0f0, capacity))
        b.α = α
        b.β = β
        b.max_priority = max_priority
    end
    b
end

function Flux.gpu(b::ExperienceBuffer)
    data = Dict{Symbol, CuArray}(k => v |> gpu for (k,v) in b.data)
    ExperienceBuffer(data, b.elements, b.next_ind, b.indices, b.minsort_priorities, b.priorities, b.α, b.β, b.max_priority)
end

function Flux.cpu(b::ExperienceBuffer)
    data = Dict{Symbol, Array}(k => v |> cpu for (k,v) in b.data)
    ExperienceBuffer(data, b.elements, b.next_ind, b.indices, b.minsort_priorities, b.priorities, b.α, b.β, b.max_priority)
end

function clear!(b::ExperienceBuffer)
    b.elements = 0
    b.next_ind = 1
    b.indices = []
    if prioritized(b)
        b.minsort_priorities = MinHeap(fill(Inf32, capacity))
        b.priorities = FenwickTree(fill(0f0, capacity))
    end
    b
end 

function Random.shuffle!(b::ExperienceBuffer)
    new_i = shuffle(1:length(b))
    for k in keys(b)
        b[k] .= bslice(b[k], new_i)
    end
end

minibatch(b::ExperienceBuffer, indices) = Dict(k => bslice(b.data[k], indices) for k in keys(b))

Base.getindex(b::ExperienceBuffer, key::Symbol) = bslice(b.data[key], 1:b.elements)

Base.keys(b::ExperienceBuffer) = keys(b.data)

Base.haskey(b::ExperienceBuffer, k) = haskey(b.data, k)

Base.length(b::ExperienceBuffer) = b.elements

DataStructures.capacity(b::ExperienceBuffer) = size(first(b.data)[2], 2)

prioritized(b::ExperienceBuffer) = !isnothing(b.priorities)

device(b::ExperienceBuffer{CuArray}) = gpu
device(b::ExperienceBuffer{Array}) = cpu

dim(b::ExperienceBuffer, s::Symbol) = size(b[s], 1)

function episodes(b::ExperienceBuffer)
    if haskey(b, :episode_end)
        ep_ends = findall(b[:episode_end][1,:])
        ep_starts = [1, ep_ends[1:end-1] .+ 1 ...]
    elseif haskey(b, :t)
        ep_starts = findall(b[:t][1,:] .== 1)
        ep_ends = [ep_starts[2:end] .- 1 ..., length(b)]
    else
        error("Need :episode_end flag or :t column to determine episodes")
    end
    zip(ep_starts, ep_ends)
end

# Note: data can be a dictionary or an experience buffer
function Base.push!(b::ExperienceBuffer, data; ids = nothing)
    ids = isnothing(ids) ? UnitRange(1, size(data[first(keys(data))], 2)) : ids
    N, C = length(ids), capacity(b)
    I = mod1.(b.next_ind:b.next_ind + N - 1, C)
    for k in keys(b)
        copyto!(bslice(b.data[k], I), collect(bslice(data[k], ids)))
    end
    prioritized(b) && update_priorities!(b, I, b.max_priority*ones(N))
        
    b.elements = min(C, b.elements + N)
    b.next_ind = mod1(b.next_ind + N, C)
    I
end

function update_priorities!(b, I::AbstractArray, v::AbstractArray)
    for i = 1:length(I)
        val = v[i] + eps(Float32)
        update!(b.priorities, I[i], val^b.α)
        update!(b.minsort_priorities, I[i], val^b.α)
        b.max_priority = max(val, b.max_priority)
    end
end

function Random.rand!(target::ExperienceBuffer, source::ExperienceBuffer...; i = 1, fracs = ones(length(source))./length(source))
    batches = floor.(Int, capacity(target) .* fracs)
    batches[1] += capacity(target) - sum(batches)
    
    for (b, B) in zip(source, batches)
        B == 0 && continue
        prioritized(b) ? prioritized_sample!(target, b, i=i, B=B) : uniform_sample!(target, b, B=B)
    end
end

function uniform_sample!(target::ExperienceBuffer, source::ExperienceBuffer; B = capacity(target))
    ids = rand(1:length(source), B)
    push!(target, source, ids = ids)
end

# With guidance from https://github.com/openai/baselines/blob/master/baselines/deepq/replay_buffer.py
function prioritized_sample!(target::ExperienceBuffer, source::ExperienceBuffer; i = 1, B = capacity(target))
    @assert haskey(source, :weight) 
    N = length(source)
    ptot = prefixsum(source.priorities, N)
    Δp = ptot / B
    target.indices = [inverse_query(source.priorities, (j + rand() - 1) * Δp, N-1) for j=1:B]
    target.indices = max.(target.indices, )
    pmin = first(source.minsort_priorities) / ptot
    max_w = (pmin*N)^(-source.β(i))
    source[:weight][1, target.indices] .= [(N * source.priorities[id] / ptot)^source.β(i) for id in target.indices] ./ max_w
    
    push!(target, source, ids = target.indices)
end


function find_ep(i, eps)
    for ep in eps
        i >= ep[1] && i <= ep[2] && return ep
    end
    error("$i out of range of $(collect(eps)[end][2])")
end

function geometric_sample!(target::ExperienceBuffer, source::ExperienceBuffer, γ; B = capacity(target))
    ids = rand(1:length(source), B) # sample random starting points
    eps = episodes(source)
    eps = [Crux.find_ep(i, eps) for i in ids] # get the corresponding episode
    range = [eps[i][2] - ids[i] for i=1:B] # get the length to the end of the episode
    ids = [ids[i] + (range[i] == 0 ? 0 : Int(rand(Truncated(Geometric(1 - γ), 0, range[i])))) for i=1:B] # sample truncated geometric distribution
    
    indices = push!(target, source, ids=ids)
    if haskey(target, :s0)
        s0_ids = [ep[1] for ep in eps]
        copyto!(bslice(target.data[:s0], indices), collect(bslice(source[:s], s0_ids)))
    end
end

