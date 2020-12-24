istraining() = false

@adjoint istraining() = true, _ -> nothing

_isactive(m) = isnothing(m.active) ? istraining() : m.active

_dropout_shape(s, ::Colon) = size(s)
_dropout_shape(s, dims) = tuple((i ∉ dims ? 1 : si for (i, si) ∈ enumerate(size(s)))...)

_dropout_kernel(y::T, p, q) where {T} = y > p ? T(1 / q) : T(0)

"""
    dropout(x, p; dims=:, active=true)

The dropout function. If `active` is `true`,
for each input, either sets that input to `0` (with probability
`p`) or scales it by `1 / (1 - p)`. `dims` specifies the unbroadcasted dimensions,
e.g. `dims=1` applies dropout along columns and `dims=2` along rows.
This is used as a regularisation, i.e. it reduces overfitting during training.

If `active` is `false`, it just returns the input `x`

Warning: when using this function, you have to manually manage the activation
state. Usually in fact, dropout is used while training
but is deactivated in the inference phase. This can be
automatically managed using the [`Dropout`](@ref) layer instead of the
`dropout` function.

The [`Dropout`](@ref) layer is what you should use in most scenarios.
"""
function dropout(x, p; dims=:, active::Bool=true)
  active || return x
  y = dropout_mask(x, p, dims=dims)
  return x .* y
end

@adjoint function dropout(x, p; dims=:, active::Bool=true)
  active || return x, Δ -> (Δ, nothing)
  y = dropout_mask(x, p, dims=dims)
  return x .* y, Δ -> (Δ .* y, nothing)
end

function dropout_mask(x, p; dims=:)
  y = rand!(similar(x, _dropout_shape(x, dims)))
  y .= _dropout_kernel.(y, p, 1 - p)
  return y
end

"""
    Dropout(p; dims=:)

Dropout layer. In the forward pass, apply the [`Flux.dropout`](@ref) function on the input.

Does nothing to the input once [`Flux.testmode!`](@ref) is set to `true`.
"""
mutable struct Dropout{F,D}
  p::F
  dims::D
  active::Union{Bool, Nothing}
end

function Dropout(p; dims=:)
  @assert 0 ≤ p ≤ 1
  Dropout(p, dims, nothing)
end

function (a::Dropout)(x)
  _isactive(a) || return x
  return dropout(x, a.p; dims=a.dims, active=true)
end

testmode!(m::Dropout, mode=true) =
  (m.active = (isnothing(mode) || mode == :auto) ? nothing : !mode; m)

function Base.show(io::IO, d::Dropout)
  print(io, "Dropout(", d.p)
  d.dims != (:) && print(io, ", dims = $(repr(d.dims))")
  print(io, ")")
end

"""
    AlphaDropout(p)

A dropout layer. Used in
[Self-Normalizing Neural Networks](https://arxiv.org/abs/1706.02515).
The AlphaDropout layer ensures that mean and variance of activations
remain the same as before.

Does nothing to the input once [`testmode!`](@ref) is true.
"""
mutable struct AlphaDropout{F}
  p::F
  active::Union{Bool, Nothing}
  function AlphaDropout(p, active = nothing)
    @assert 0 ≤ p ≤ 1
    new{typeof(p)}(p, active)
  end
end

function (a::AlphaDropout)(x)
  _isactive(a) || return x
  λ = eltype(x)(1.0507009873554804934193349852946)
  α = eltype(x)(1.6732632423543772848170429916717)
  α1 = eltype(x)(-λ*α)
  noise = randn(eltype(x), size(x))
  x = @. x*(noise > (1 - a.p)) + α1 * (noise < (1 - a.p))
  A = (a.p + a.p * (1 - a.p) * α1 ^ 2)^0.5
  B = -A * α1 * (1 - a.p)
  x = @. A * x + B
  return x
end

testmode!(m::AlphaDropout, mode=true) =
  (m.active = (isnothing(mode) || mode == :auto) ? nothing : !mode; m)

"""
    LayerNorm(sz, σ=identity; affine=true, ϵ=1fe-5)

A [normalisation layer](https://arxiv.org/abs/1607.06450) designed to be
used with recurrent hidden states. 
The argument `sz` should be an integer or a tuple of integers. 
In the forward pass, the layer normalises the mean and standard 
deviation of the input, the applied the elementwise activation `σ`.
The input is normalised along the first `length(sz)` dimensions
for tuple `sz`, along the first dimension for integer `sz`.
The input  is expected to have first dimensions' size equal to `sz`. 

If `affine=true` also applies a learnable shift and rescaling
as in the [`Diagonal`](@ref) layer.


Se also [`BatchNorm`](@ref), [`InstanceNorm`](@ref), [`GroupNorm`](@ref), and [`normalise`](@ref).
"""
struct LayerNorm
  σ
  diag
  ϵ
  size
  affine::Bool
end

function LayerNorm(sz, σ=identity; affine=true, ϵ=1f-5)
  sz = sz isa Integer ? (sz,) : sz
  diag = affine ? Diagonal(sz...) : nothing
  return LayerNorm(σ, diag, ϵ, sz, affine)
end

@functor LayerNorm

function (a::LayerNorm)(x)
  x = normalise(x, dims=1:length(a.size), ϵ=a.ϵ)
  a.diag === nothing ? a.σ.(x) : a.σ.(a.diag(x))
end

function Base.show(io::IO, l::LayerNorm)
  print(io, "LayerNorm($(l.size)")
  a.σ == identity || print(io, ", $(a.σ)")
  hasaffine(l) || print(io, ", affine=false")
  print(io, ")")
end

# For InstanceNorm and BatchNorm
# Compute the statistics on the slices specified by dims.
# dims=[1,...,N-2,N] for BatchNorm
# dims=[1,...,N-2] for InstanceNorm
function _norm_layer_forward(l, x; dims)
  N = ndims(x)
  affine_shape = ntuple(i -> i == N-1 ? size(x, N-1) : 1, N)
  if !_isactive(l) && l.track_stats
    if l.μ isa AbstractArray
      μ = reshape(l.μ, affine_shape)
      σ² = reshape(l.σ², affine_shape)
    else
      μ , σ² = l.μ, l.σ²
    end
  else
    μ = mean(x; dims)
    σ² = mean((x .- μ).^2; dims)
    if l.track_stats
      # update moving mean/std
      mtm = l.momentum
      m = prod(size(x)) ÷ size(x, N-1)  # needed for computing corrected var
      l.μ = (1-mtm) .* l.μ .+ mtm .* vec(N ∈ dims ? μ : mean(μ, dims=N))
      l.σ² = (1-mtm) .* l.σ² .+ mtm .* (m/(m-1f0)) .* vec(N ∈ dims ? σ² : mean(σ², dims=N))
    end
  end
  if hasaffine(l)
    γ = reshape(l.γ, affine_shape)
    β = reshape(l.β, affine_shape)
    return l.σ.(γ .* (x .- μ) ./ sqrt.(σ² .+ l.ϵ) .+ β)
  else
    return l.σ.((x .- μ) ./ sqrt.(σ² .+ l.ϵ))
  end
end

"""
    BatchNorm(channels::Integer, σ=identity;
              initβ=zeros, initγ=ones,
              ϵ=1f-5, momentum= 0.1f0)

[Batch Normalization](https://arxiv.org/abs/1502.03167) layer.
`channels` should be the size of the channel dimension in your data (see below).

Given an array with `N` dimensions, call the `N-1`th the channel dimension. For
a batch of feature vectors this is just the data dimension, for `WHCN` images
it's the usual channel dimension.

`BatchNorm` computes the mean and variance for each `D_1×...×D_{N-2}×1×D_N` 
input slice and normalises the input accordingly.

If `affine=true`, it also applies  a shift and a rescale to the input 
through to learnable per-channel bias β and scale γ parameters.

After normalisation, elementwise activation `σ` is applied.  

If `track_stats=true`, accumulates mean and var statistics in training phase 
that will be used to renormalize the input in test phase.

Use [`testmode!`](@ref) during inference.

# Examples
```julia
m = Chain(
  Dense(28^2, 64),
  BatchNorm(64, relu),
  Dense(64, 10),
  BatchNorm(10),
  softmax)
```
"""
mutable struct BatchNorm{F,V,N}
  σ::F  # activation function
  β::V  # bias
  γ::V  # scale
  μ     # moving mean
  σ²    # moving var
  ϵ::N
  momentum::N
  affine::Bool
  track_stats::Bool
  active::Union{Bool, Nothing}
end

function BatchNorm(chs::Integer, σ=identity;
          initβ = i -> zeros(Float32, i), 
          initγ = i -> ones(Float32, i), 
          affine=true, track_stats=true,
          ϵ=1f-5, momentum=0.1f0)

  if affine
    β = initβ(chs)
    γ = initγ(chs)
  else
    β = nothing
    γ = nothing
  end  
  
  return BatchNorm(σ, β, γ,
            0, 1, ϵ, momentum, 
            affine, track_stats, nothing)
end

@functor BatchNorm
trainable(bn::BatchNorm) = hasaffine(bn) ? (bn.β, bn.γ) : ()

function (BN::BatchNorm)(x)
  N = ndims(x)
  dims = [1:N-2; N]
  _norm_layer_forward(BN, x; dims)
end

testmode!(m::BatchNorm, mode=true) =
  (m.active = (isnothing(mode) || mode == :auto) ? nothing : !mode; m)

function Base.show(io::IO, l::BatchNorm)
  print(io, "BatchNorm(")
  print(io, hasaffine(l) ? "affine=false" : length(l.β))
  (l.σ == identity) || print(io, ", $(l.σ)")
  print(io, ")")
end


"""
    InstanceNorm(channels::Integer, σ=identity;
                 initβ=zeros, initγ=ones,
                 affine=false, track_stats=false,
                 ϵ=1f-5, momentum=0.1f0)

[Instance Normalization](https://arxiv.org/abs/1607.08022) layer.
`channels` should be the size of the channel dimension in your data (see below).

Given an array with `N > 2` dimensions, call the `N-1`th the channel dimension. 
For `WHCN` images it's the usual channel dimension.

`InstanceNorm` computes the mean and variance for each `D_1×...×D_{N-2}×1×1` 
input slice and normalises the input accordingly.

If `affine=true`, it also applies  a shift and a rescale to the input 
through to learnable per-channel bias β and scale γ parameters.

If `track_stats=true`, accumulates mean and var statistics in training phase 
that will be used to renormalize the input in test phase.

Use [`testmode!`](@ref) during inference.

**Warning**: the defaults for `affine` and `track_stats` used to be `true` 
in previous Flux versions (< v0.12).

# Examples
```julia
m = Chain(
      Dense(28^2, 64),
      InstanceNorm(64, relu),
      Dense(64, 10),
      InstanceNorm(10),
      softmax)
```
"""
mutable struct InstanceNorm{F,V,N}
  σ::F  # activation function
  β::V  # bias
  γ::V  # scale
  μ  # moving mean
  σ²  # moving var
  ϵ::N
  momentum::N
  affine::Bool
  track_stats::Bool
  active::Union{Bool, Nothing}
end

function InstanceNorm(chs::Integer, σ=identity;
                    initβ = i -> zeros(Float32, i), 
                    initγ = i -> ones(Float32, i), 
                    affine=false, track_stats=false,
                    ϵ=1f-5, momentum=0.1f0)

  if affine
    β = initβ(chs)
    γ = initγ(chs)
  else
    β = nothing
    γ = nothing
  end  
  return InstanceNorm(σ, β, γ,
            0, 1, ϵ, momentum, 
            affine, track_stats, nothing)
end

trainable(in::InstanceNorm) = hasaffine(in) ? (in.β, in.γ) : ()
@functor InstanceNorm

function (l::InstanceNorm)(x)
  @assert ndims(x) > 2
  N = ndims(x)
  dims = 1:N-2 # axes to reduce along (all but channels and batch size axes)
  _norm_layer_forward(l, x; dims)
end


testmode!(m::InstanceNorm, mode=true) =
  (m.active = (isnothing(mode) || mode == :auto) ? nothing : !mode; m)

#TODO
function Base.show(io::IO, l::InstanceNorm)
  print(io, "InstanceNorm($(join(size(l.β), ", "))")
  (l.σ == identity) || print(io, ", $(l.σ)")
  print(io, ")")
end

"""
    GroupNorm(chs::Integer, G::Integer, λ = identity;
              initβ = (i) -> zeros(Float32, i), initγ = (i) -> ones(Float32, i),
              ϵ = 1f-5, momentum = 0.1f0)

[Group Normalization](https://arxiv.org/abs/1803.08494) layer.
This layer can outperform Batch Normalization and Instance Normalization.

`chs` is the number of channels, the channel dimension of your input.
For an array of N dimensions, the `N-1`th index is the channel dimension.

`G` is the number of groups along which the statistics are computed.
The number of channels must be an integer multiple of the number of groups.

Use [`testmode!`](@ref) during inference.

# Examples
```julia
m = Chain(Conv((3,3), 1=>32, leakyrelu;pad = 1),
          GroupNorm(32,16))
          # 32 channels, 16 groups (G = 16), thus 2 channels per group used
```
"""
mutable struct GroupNorm{F,V,W,N,T}
  G::T # number of groups
  λ::F  # activation function
  β::V  # bias
  γ::V  # scale
  μ::W  # moving mean
  σ²::W  # moving std
  ϵ::N
  momentum::N
  active::Union{Bool, Nothing}
end

GroupNorm(chs::Integer, G::Integer, λ = identity;
          initβ = (i) -> zeros(Float32, i), initγ = (i) -> ones(Float32, i), ϵ = 1f-5, momentum = 0.1f0) =
  GroupNorm(G, λ, initβ(chs), initγ(chs),
            zeros(G,1), ones(G,1), ϵ, momentum, nothing)

trainable(gn::GroupNorm) = (gn.β, gn.γ)

function(gn::GroupNorm)(x)
  size(x,ndims(x)-1) == length(gn.β) || error("Group Norm expected $(length(gn.β)) channels, but got $(size(x,ndims(x)-1)) channels")
  ndims(x) > 2 || error("Need to pass at least 3 channels for Group Norm to work")
  (size(x,ndims(x) -1))%gn.G == 0 || error("The number of groups ($(gn.G)) must divide the number of channels ($(size(x,ndims(x) -1)))")

  dims = length(size(x))
  groups = gn.G
  channels = size(x, dims-1)
  batches = size(x,dims)
  channels_per_group = div(channels,groups)
  affine_shape = ntuple(i->i == ndims(x) - 1 ? size(x, i) : 1, ndims(x))

  # Output reshaped to (W,H...,C/G,G,N)
  μ_affine_shape = ntuple(i->i == ndims(x) ? groups : 1, ndims(x) + 1)

  m = prod(size(x)[1:end-2]) * channels_per_group
  γ = reshape(gn.γ, affine_shape)
  β = reshape(gn.β, affine_shape)

  y = reshape(x,((size(x))[1:end-2]...,channels_per_group,groups,batches))
  if !_isactive(gn)
    og_shape = size(x)
    μ = reshape(gn.μ, μ_affine_shape) # Shape : (1,1,...C/G,G,1)
    σ² = reshape(gn.σ², μ_affine_shape) # Shape : (1,1,...C/G,G,1)
    ϵ = gn.ϵ
  else
    T = eltype(x)
    og_shape = size(x)
    axes = 1:ndims(y)-2 # axes to reduce along (all but channels axis)
    μ = mean(y, dims=axes)
    σ² = mean((y .- μ) .^ 2, dims=axes)

    ϵ = convert(T, gn.ϵ)
    # update moving mean/std
    mtm = gn.momentum
    S = eltype(gn.μ)
    gn.μ = mean((1 - mtm) .* gn.μ .+ mtm .* S.(reshape(μ, (groups,batches))),dims=2)
    gn.σ² = mean((1 - mtm) .* gn.σ² .+ (mtm * m / (m - 1)) .* S.(reshape(σ², (groups,batches))),dims=2)
  end

  let λ = gn.λ
    x̂ = (y .- μ) ./ sqrt.(σ² .+ ϵ)

    # Reshape x̂
    x̂ = reshape(x̂, og_shape)
    λ.(γ .* x̂ .+ β)
  end
end

@functor GroupNorm

testmode!(m::GroupNorm, mode = true) =
  (m.active = (isnothing(mode) || mode == :auto) ? nothing : !mode; m)

function Base.show(io::IO, l::GroupNorm)
  print(io, "GroupNorm($(join(size(l.β), ", "))")
  (l.λ == identity) || print(io, ", λ = $(l.λ)")
  print(io, ")")
end


"""
  hasaffine(l)

Return `true` if a normalisation layer has trainable shift and 
scale parameters, `false` otherwise.

See [`BatchNorm`](@ref), [`InstanceNorm`](@ref), and [`LayerNorm`](@ref).
"""
hasaffine(l::Union{BatchNorm,InstanceNorm, LayerNorm}) = l.affine  # alternative is  l.β !== nothing
