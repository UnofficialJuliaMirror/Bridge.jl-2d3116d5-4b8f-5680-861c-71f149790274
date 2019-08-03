# THIS SCRIPT REPLACES THE OLDER 'lmpar.jl'
using Bridge, StaticArrays, Distributions
using Bridge:logpdfnormal
using Test, Statistics, Random, LinearAlgebra
using Bridge.Models
using DelimitedFiles,  DataFrames,  CSV, RCall
using Base.Iterators, SparseArrays, LowRankApprox, Trajectories
using ForwardDiff #: GradientConfig, Chunk, gradient!, gradient, Dual, value
using ReverseDiff #: GradientConfig,  gradient!, gradient, Dual, value
using DiffResults
using TimerOutputs #undeclared
using Plots,  PyPlot #using Makie
using RecursiveArrayTools
using DataFrames

outdir = "/Users/Frank/.julia/dev/Bridge/landmarks/figs/"

pyplot()

const sk=1  # entries to skip for likelihood evaluation
const itostrat = true#false#true                    #false#true#false#true
const d = 2
const inplace = true  # if true inplace updates on the path when doing autodifferentiation
const TEST = false


#include("ostate.jl")
include("nstate.jl")
include("state.jl")
#include("state_localversion.jl")
include("models.jl")
include("patches.jl")
include("lmguiding.jl")
include("plotlandmarks.jl")
include("automaticdiff_lm.jl")
include("generatedata.jl")
include("lm_mcmc.jl")

#Base.Float64(d::Dual{T,V,N}) where {T,V,N} = Float64(d.value)
#Base.float(d::Dual{T,V,N}) where {T,V,N} = Float64(d.value)

deepvalue(x::Float64) = x
deepvalue(x::ForwardDiff.Dual) = ForwardDiff.value(x)
deepvalue(x) = deepvalue.(x)
function deepvalue(x::State)
    State(deepvalue.(x.x))
end


n = 15#35 # nr of landmarks
models = [:ms, :ahs]
model = models[1]
println(model)

partialobs = true  #false
rotation = false  # rotate configuration at time T
showplotσq = false

samplers =[:sgd, :sgld, :mcmc]
sampler = samplers[3]



ρ = 0.9
if model==:ms
    δ = 0.1
else
    δ = 0.005
end
ϵ = 0.01  # sgd step size
ϵstep(i) = 1/(1+i)^(0.7)


datasets =["forwardsimulated", "shifted","shiftedextreme", "bear", "heart","peach"]
dataset = datasets[1]

ITER = 50 # nr of sgd iterations
subsamples = 0:2:ITER


σobs = 0.01   # noise on observations

T = 1.0#1.0#0.5
dt = 0.01
t = 0.0:dt:T  # time grid

### Specify landmarks models
a = 5.0     # Hamiltonian kernel parameter (the larger, the stronger landmarks behave similarly)


if model == :ms
    λ = 0.0;    # Mean reversion par in MS-model = not the lambda of noise fields  =#
    γ = .5 #2.0     # Noise level in for MS-model
    dwiener = n
    nfs = 0 # needs to have value for plotting purposes
    P = MarslandShardlow(a, γ, λ, n)
else
    db = 5.0 # domainbound
    nfstd = 2.5#2.5#  1.25 # tau , width of noisefields
    γ = 0.2
    nfs = construct_nfs(db, nfstd, γ) # 3rd argument gives average noise of positions (with superposition)
    dwiener = length(nfs)
    P = Landmarks(a, n, nfs)
end



if (model == :ahs) & showplotσq
    plotσq(db, nfs)
end

StateW = PointF

# set time grid for guided process
tt_ =  tc(t,T)#tc(t,T)# 0:dtimp:(T)

# generate data
x0, xobs0, xobsT, Xf, P = generatedata(dataset,P,t,σobs)

# plotlandmarkpositions(Xf,P.n,model,xobs0,xobsT,nfs,db=6)#2.6)
# ham = [hamiltonian(Xf.yy[i],P) for i in 1:length(t)]
# Plots.plot(1:length(t),ham)
# print(ham)

if partialobs
    L0 = LT = [(i==j)*one(UncF) for i in 1:2:2P.n, j in 1:2P.n]
    Σ0 = ΣT = [(i==j)*σobs^2*one(UncF) for i in 1:P.n, j in 1:P.n]
    μT = zeros(PointF,P.n)
    mT = zeros(PointF,P.n)   #
else
    LT = [(i==j)*one(UncF) for i in 1:2P.n, j in 1:2P.n]
    ΣT = [(i==j)*σobs^2*one(UncF) for i in 1:2P.n, j in 1:2P.n]
    μT = zeros(PointF,2P.n)
    xobsT = vec(X.yy[end])
    mT = Xf.yy[end].p
    L0 = [(i==j)*one(UncF) for i in 1:2:2P.n, j in 1:2P.n]
    Σ0 = [(i==j)*σobs^2*one(UncF) for i in 1:P.n, j in 1:P.n]
end

if model == :ms
    Paux = MarslandShardlowAux(P, State(xobsT, mT))
else
    Paux = LandmarksAux(P, State(xobsT, mT))
end

# initialise guided path
xinit = State(xobs0, [Point(-1.0,3.0)/P.n for i in 1:P.n])
# xinit = State(xobs0, rand(PointF,n))# xinit = x0#xinit = State(xobs0, zeros(PointF,n))#xinit=State(x0.q, 30*x0.p)

start = time() # to compute elapsed time
Xsave, objvals, perc_acc = lm_mcmc(tt_, (LT,ΣT,μT), (L0,Σ0), (xobs0,xobsT), P, Paux, model, sampler,
                                        dataset, xinit, δ, ITER, outdir; makefig=true)
elapsed = time() - start

if false
    ########### grad desc for pars

    # also do gradient descent on parameters a (in kernel of Hamiltonian)
    # first for MS model
    get_targetpars(Q::GuidedProposall!) = [Q.target.a, Q.target.γ]
    get_auxpars(Q::GuidedProposall!) = [Q.aux.a, Q.aux.γ]

    put_targetpars = function(pars,Q)
        GuidedProposall!(MarslandShardlow(pars[1],pars[2],Q.target.λ, Q.target.n), Q.aux, Q.tt, Q.Lt, Q.Mt, Q.μt,Q.Ht, Q.xobs)
    end

    put_auxpars(pars,Q) = GuidedProposall!(Q.target,MarslandShardlowAux(pars[1],pars[2],Q.aux.λ, Q.aux.xT,Q.aux.n), Q.tt, Q.Lt, Q.Mt, Q.μt,Q.Ht, Q.xobs)

    QQ = put_targetpars([3.0, 300.0],Q)
    QQ.target.a
    QQ.target.γ
end


# write mcmc iterates to csv file
iterates = reshape(vcat(Xsave...),2*d*length(tt_)*P.n, length(subsamples)) # each column contains samplepath of an iteration
# Ordering in each column is as follows:
# 1) time
# 2) landmark nr
# 3) for each landmark: q1, q2 p1, p2
pqtype = repeat(["pos1", "pos2", "mom1", "mom2"], length(tt_)*P.n)
times = repeat(tt_,inner=2d*P.n)
landmarkid = repeat(1:P.n, inner=2d, outer=length(tt_))

out = hcat(times,pqtype,landmarkid,iterates)
head = "time " * "pqtype " * "landmarkid " * prod(map(x -> "iter"*string(x)*" ",subsamples))
head = chop(head,tail=1) * "\n"

fn = outdir*"iterates.csv"
f = open(fn,"w")
write(f, head)
writedlm(f,out)
close(f)

println("Average acceptance percentage: ",perc_acc,"\n")
println("Elapsed time: ",round(elapsed;digits=3))



# write info to txt file
fn = outdir*"info.txt"
f = open(fn,"w")
write(f, "Dataset: ", string(dataset),"\n")
write(f, "Sampler: ", string(sampler), "\n")

write(f, "Number of iterations: ",string(ITER),"\n")
write(f, "Number of landmarks: ",string(P.n),"\n")
write(f, "Length time grid: ", string(length(tt_)),"\n")
write(f, "Mesh width: ",string(dt),"\n")
write(f, "Noise Sigma: ",string(σobs),"\n")
write(f, "rho (Crank-Nicholsen parameter: ",string(ρ),"\n")
write(f, "MALA parameter (delta): ",string(δ),"\n")
write(f, "skip in evaluation of loglikelihood: ",string(sk),"\n")
write(f, "Average acceptance percentage (path - initial state): ",string(perc_acc),"\n\n")
#write(f, "Backward type parametrisation in terms of nu and H? ",string(Î½Hparam),"\n")
close(f)
