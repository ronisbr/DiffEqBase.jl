"""
$(TYPEDEF)
"""
abstract type BasicEnsembleAlgorithm <: EnsembleAlgorithm end

"""
$(TYPEDEF)
"""
struct EnsembleThreads <: BasicEnsembleAlgorithm end

"""
$(TYPEDEF)
"""
struct EnsembleDistributed <: BasicEnsembleAlgorithm end

"""
$(TYPEDEF)
"""
struct EnsembleSplitThreads <: BasicEnsembleAlgorithm end

"""
$(TYPEDEF)
"""
struct EnsembleSerial <: BasicEnsembleAlgorithm end

#=
if (kwargs[:parallel_type] == != :none && kwargs[:parallel_type] == != :threads)
  error("Distributed arrays cannot be generated via none or threads")
end
(batch_size != trajectories) && warn("batch_size and reductions are ignored when !collect_result")

elapsed_time = @elapsed u = DArray((trajectories,)) do I
    solve_batch(prob,alg,kwargs[:parallel_type] ==,I[1],pmap_batch_size,kwargs...)
end
return EnsembleSolution(u,elapsed_time,false)
=#

function __solve(prob::AbstractEnsembleProblem,
                 alg::Union{DEAlgorithm,Nothing};
                 kwargs...)
    #=
    if alg isa EnsembleAlgorithm
      @error "You forgot to pass a DE solver algorithm! Only a EnsembleAlgorithm has been supplied. Exiting"
    end
    =#
    if :parallel_type ∈ keys(kwargs)
      if kwargs[:parallel_type] == :none
        ensemblealg = EnsembleSerial()
      elseif kwargs[:parallel_type] == :pmap || kwargs[:parallel_type] == :parfor
        ensemblealg = EnsembleDistributed()
      elseif kwargs[:parallel_type] == :threads
        ensemblealg = EnsembleThreads()
      elseif kwargs[:parallel_type] == :split_threads
        ensemblealg = EnsembleSplitThreads()
      else
        @error "parallel_type value not recognized"
      end
    elseif alg isa EnsembleAlgorithm
      # Assume DifferentialEquations.jl is being used, so default alg
      ensemblealg = alg
      alg = nothing
    else
      ensemblealg = EnsembleThreads()
    end
    if :num_monte ∈ keys(kwargs)
      @warn "num_monte has been replaced by trajectories"
      trajectories = kwargs[:num_monte]
    else
      @assert :trajectories ∈ keys(kwargs)
      trajectories = kwargs[:trajectories]
    end
    if :parallel_type ∈ keys(kwargs)
      @warn "parallel_type has been deprecated. Please refer to the docs for the new dispatch-based system."
    end
    __solve(prob,alg,ensemblealg;trajectories=trajectories,kwargs...)
end

function __solve(prob::AbstractEnsembleProblem,
                 alg::Union{DEAlgorithm,Nothing},
                 ensemblealg::BasicEnsembleAlgorithm;
                 trajectories, batch_size = trajectories,
                 pmap_batch_size = batch_size÷100 > 0 ? batch_size÷100 : 1, kwargs...)

  num_batches = trajectories ÷ batch_size
  num_batches * batch_size != trajectories && (num_batches += 1)

  u = deepcopy(prob.u_init)
  converged = false
  elapsed_time = @elapsed for i in 1:num_batches
    if i == num_batches
      I = (batch_size*(i-1)+1):trajectories
    else
      I = (batch_size*(i-1)+1):batch_size*i
    end
    batch_data = solve_batch(prob,alg,ensemblealg,I,pmap_batch_size,kwargs...)
    u,converged = prob.reduction(u,batch_data,I)
    converged && break
  end
  if typeof(u) <: Vector{Any}
    _u = map(i->u[i],1:length(u))
  else
    _u = u
  end
  return EnsembleSolution(_u,elapsed_time,converged)
end

function batch_func(i,prob,alg,I,kwargs...)
  iter = 1
  _prob = prob.safetycopy ? deepcopy(prob.prob) : prob.prob
  new_prob = prob.prob_func(_prob,i,iter)
  rerun = true
  x = prob.output_func(solve(new_prob,alg;kwargs...),i)
  if !(typeof(x) <: Tuple)
      @warn("output_func should return (out,rerun). See docs for updated details")
      _x = (x,false)
  else
    _x = x
  end
  rerun = _x[2]
  while rerun
      iter += 1
      _prob = prob.safetycopy ? deepcopy(prob.prob) : prob.prob
      new_prob = prob.prob_func(_prob,i,iter)
      x = prob.output_func(solve(new_prob,alg;kwargs...),i)
      if !(typeof(x) <: Tuple)
          @warn("output_func should return (out,rerun). See docs for updated details")
          _x = (x,false)
      else
        _x = x
      end
      rerun = _x[2]
  end
  _x[1]
end

function solve_batch(prob,alg,ensemblealg::EnsembleDistributed,I,pmap_batch_size,kwargs...)
  wp=CachingPool(workers())
  batch_data = let
    pmap(wp,I,batch_size=pmap_batch_size) do i
      batch_func(i,prob,alg,I,kwargs...)
    end
  end
  map(i->batch_data[i],1:length(batch_data))
end

function solve_batch(prob,alg,::EnsembleSerial,I,pmap_batch_size,kwargs...)
  batch_data = let
    map(I) do i
      batch_func(i,prob,alg,I,kwargs...)
    end
  end
  map(i->batch_data[i],1:length(batch_data))
end

function solve_batch(prob,alg,ensemblealg::EnsembleThreads,I,pmap_batch_size,kwargs...)
  batch_data = Vector{Any}(undef,length(I))
  let
    Threads.@threads for batch_idx in axes(batch_data, 1)
        i = I[batch_idx]
        iter = 1
        _prob = prob.safetycopy ? deepcopy(prob.prob) : prob.prob
        new_prob = prob.prob_func(_prob,i,iter)
        x = prob.output_func(solve(new_prob,alg;kwargs...),i)
        if !(typeof(x) <: Tuple)
            @warn("output_func should return (out,rerun). See docs for updated details")
            _x = (x,false)
        else
          _x = x
        end
        rerun = _x[2]

        while rerun
            iter += 1
            _prob = prob.safetycopy ? deepcopy(prob.prob) : prob.prob
            new_prob = prob.prob_func(_prob,i,iter)
            x = prob.output_func(solve(new_prob,alg;kwargs...),i)
            if !(typeof(x) <: Tuple)
                @warn("output_func should return (out,rerun). See docs for updated details")
                _x = (x,false)
            else
              _x = x
            end
            rerun = _x[2]
        end
        batch_data[batch_idx] = _x[1]
    end
  end
  map(i->batch_data[i],1:length(batch_data))
end

function solve_batch(prob,alg,::EnsembleSplitThreads,I,pmap_batch_size,kwargs...)
  wp=CachingPool(workers())
  N = nworkers()
  batch_size = length(I)÷N
  batch_data = let
    pmap(wp,1:N,batch_size=pmap_batch_size) do i
      if i == N
        I_local = I[(batch_size*(i-1)+1):end]
      else
        I_local = I[(batch_size*(i-1)+1):(batch_size*i)]
      end
      thread_monte(prob,I_local,alg,i,kwargs...)
    end
  end
  _batch_data = vector_batch_data_to_arr(batch_data)
end

function thread_monte(prob,I,alg,procid,kwargs...)
  batch_data = Vector{Any}(undef,length(I))
  let
    Threads.@threads for j in 1:length(I)
      i = I[j]
      iter = 1
      _prob = prob.safetycopy ? deepcopy(prob.prob) : prob.prob
      new_prob = prob.prob_func(_prob,i,iter)
      rerun = true
      x = prob.output_func(solve(new_prob,alg;kwargs...),i)
      if !(typeof(x) <: Tuple)
          @warn("output_func should return (out,rerun). See docs for updated details")
          _x = (x,false)
      else
        _x = x
      end
      rerun = _x[2]
      while rerun
          iter += 1
          _prob = prob.safetycopy ? deepcopy(prob.prob) : prob.prob
          new_prob = prob.prob_func(_prob,i,iter)
          x = prob.output_func(solve(new_prob,alg;kwargs...),i)
          if !(typeof(x) <: Tuple)
              @warn("output_func should return (out,rerun). See docs for updated details")
              _x = (x,false)
          else
            _x = x
          end
          rerun = _x[2]
      end
      batch_data[j] = _x[1]
    end
  end
  batch_data
end

function vector_batch_data_to_arr(batch_data)
  _batch_data = Vector{Any}(undef,sum((length(x) for x in batch_data)))
  idx = 0
  @inbounds for a in batch_data
    for x in a
      idx += 1
      _batch_data[idx] = x
    end
  end
  map(i->_batch_data[i],1:length(_batch_data))
end
