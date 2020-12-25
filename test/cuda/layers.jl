# Test layers and data/model movements on and off the GPU
# Add tests for layers and their gradients on the GPU
# Most of the forward passes should be fine being applied
# to bitstype objects, but this gives higher coverage for our use-cases
# Check that getting the gradients does not throw

# generic movement tests
@testset "Basic GPU Movement" begin
  @test gradient(x -> sum(gpu(x)), rand(3,3)) isa Tuple
  @test gradient(x -> sum(cpu(x)), gpu(rand(3,3))) isa Tuple
end

# TODO: These layers get into scalar indexing
# `AlphaDropout` throws a compilation error on GPUs,
# whereas, the rest are scalar indexing issues.
const BROKEN_LAYERS = Union{DepthwiseConv,
                            AlphaDropout}

function gpu_gradtest(name::String, layers::Vector, x_cpu, args...; 
            setmode=false, test_cpu=true, rtol=1e-5, atol=1e-5)
  @testset "$name GPU grad tests" begin
    for layer in layers
      @testset "$layer GPU grad test" begin
        l_cpu = layer(args...)
        if l_cpu isa BROKEN_LAYERS
          @test_broken gpu_autodiff_test(l_cpu, x_cpu, 
                          test_equal=test_cpu, rtol=rtol, atol=atol)
        else
          gpu_autodiff_test(l_cpu, x_cpu, 
              test_equal=test_cpu, rtol=rtol, atol=atol)
          if setmode
            testmode!(l_cpu)
            gpu_autodiff_test(l_cpu, x_cpu, 
              test_equal=test_cpu, rtol=rtol, atol=atol)
          end  
        end
      end
    end
  end
end


# Just to give testset in gradtest meaningful labels
ConvNoBias(args...) = Conv(args...; bias=false)
ConvTransposeNoBias(args...) = ConvTranspose(args...; bias=false)
CrossCorNoBias(args...) = CrossCor(args...; bias=false)
DepthwiseConvNoBias(args...) = DepthwiseConv(args...; bias=false)
r = rand(Float32, 28, 28, 1, 1)
conv_layers = [Conv, ConvNoBias, ConvTranspose, ConvTransposeNoBias, CrossCor, CrossCorNoBias, DepthwiseConv, DepthwiseConvNoBias]
gpu_gradtest("Conv", conv_layers, r, (2,2), 1=>3)

pooling_layers = [MaxPool, MeanPool]
gpu_gradtest("Pooling", pooling_layers, r, (2,2))

adaptive_pooling_layers = [AdaptiveMaxPool, AdaptiveMeanPool]
gpu_gradtest("AdaptivePooling", adaptive_pooling_layers, r, (7,7))

dropout_layers = [Dropout, AlphaDropout]
gpu_gradtest("Dropout", dropout_layers, r, 0.5f0; test_cpu=false, setmode=true) # dropout is not deterministic

layer_norm = [i -> LayerNorm(i; affine=false), i -> LayerNorm(i; affine=true)]
gpu_gradtest("LayerNorm 1", layer_norm, rand(Float32, 8, 8, 3, 4), 8)
gpu_gradtest("LayerNorm 2", layer_norm, rand(Float32, 8, 8, 3, 4), (8,8))
gpu_gradtest("LayerNorm 3", layer_norm, rand(Float32, 5, 4), 5)

batch_norm = [BatchNorm]
gpu_gradtest("BatchNorm 3d", batch_norm, rand(Float32, 8, 8, 8, 3, 4), 3, setmode=false) # bug in CUDA.jl with gradient in testmode
gpu_gradtest("BatchNorm 2d", batch_norm, rand(Float32, 8, 8, 3, 4), 3, setmode=false) # bug in CUDA.jl with gradient in testmode
gpu_gradtest("BatchNorm 1d", batch_norm, rand(Float32, 8, 3, 4), 3, setmode=false) # bug in CUDA.jl with gradient in testmode
gpu_gradtest("BatchNorm fullyconn", batch_norm, rand(Float32, 5,4), 5, setmode=false)

instancenorm = [i -> InstanceNorm(i; affine=false), i -> InstanceNorm(i; affine=true)]
gpu_gradtest("InstanceNorm 3d", instancenorm, rand(Float32, 8, 8, 8, 3, 4), 3, setmode=true)
gpu_gradtest("InstanceNorm 2d", instancenorm, rand(Float32, 8, 8, 3, 4), 3, setmode=true)
gpu_gradtest("InstanceNorm 1d", instancenorm, rand(Float32, 8, 3, 4), 3, setmode=true)

groupnorm = [(i, j) -> GroupNorm(i, j; affine=false), (i, j) -> GroupNorm(i, j; affine=true)]
gpu_gradtest("GroupNorm 3d", groupnorm, rand(Float32, 8, 8, 8, 12, 4), 12, 3, setmode=true)
gpu_gradtest("GroupNorm 2d", groupnorm, rand(Float32, 8, 8, 12, 4), 12, 3, setmode=true)
gpu_gradtest("GroupNorm 1d", groupnorm, rand(Float32, 8, 3, 12, 4), 12, 3, setmode=true)

@testset "function layers" begin
  x = rand(Float32, 3,3)
  gpu_autodiff_test(x -> sum(Flux.normalise(x; dims=1)), x)
  gpu_autodiff_test(x -> sum(Flux.normalise(x; dims=2)), x)
  gpu_autodiff_test(x -> sum(Flux.normalise(x)), x)
end

@testset "Zeros mapped for $cl" for cl in (Conv, ConvTranspose, CrossCor, DepthwiseConv)
  l = cl((2,2), 1=>3, bias = false) |> gpu
  ip = zeros(Float32, 28,28,1,1) |> gpu
  if l isa BROKEN_LAYERS
    @test_broken sum(l(ip)) ≈ 0.f0
    @test_broken gradient(() -> sum(l(ip)), Flux.params(l)) isa Flux.Zygote.Grads
  else
    @test sum(l(ip)) ≈ 0.f0
    gs = gradient(() -> sum(l(ip)), Flux.params(l))
    @test l.bias ∉ gs.params 
  end
end

@testset "Dense with Zeros bias" begin
  l = Dense(ones(Float32, 4,3), Flux.Zeros()) |> gpu
  ip = zeros(Float32, 3, 7) |> gpu

  @test sum(l(ip)) ≈ 0.f0  
  gs = gradient(() -> sum(l(ip)), Flux.params(l))
  @test l.b ∉ gs.params 
end