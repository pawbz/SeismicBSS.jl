# blind deconvolution
__precompile__()

module Decon
import JuMIT.DSP
import JuMIT.Misfits
using Optim, LineSearches

type Param
	gf::Array{Float64,2}
	dgf::Array{Float64,2}
	ntgf::Int64
	dobs::Array{Float64,2}
	dcal::Array{Float64,2}
	ddcal::Array{Float64,2}
	wav::Vector{Float64}
	wavmat::Array{Float64,2}
	dwavmat::Array{Float64,2}
	spow2::Array{Complex{Float64}}
	rpow2::Array{Complex{Float64}}
	wpow2::Array{Complex{Float64}}
	nt::Int64
	nr::Int64
	attrib_inv::Symbol
	verbose::Bool
	fftplan
	ifftplan
end

function Param(ntgf, nt, nr, gfobs, wavobs; verbose=false, attrib_inv=:gf,) 
	dobs=zeros(nt, nr)
	dcal=zeros(nt, nr)
	ddcal=zeros(nt, nr)
	
	# initial values are random
	wav=randn(nt)
	wavmat=repeat(wav,outer=(1,nr))
	dwavmat=similar(wavmat)
	gf=randn(ntgf,nr)
	dgf=similar(gf)

	# use maximum threads for fft
	#FFTW.set_num_threads(Sys.CPU_CORES)
	# fft dimension for plan
	np2=nextpow2(maximum([2*nt, 2*ntgf]))
	# create plan
	fftplan = plan_fft!(complex.(zeros(np2,nr)),[1],flags=FFTW.PATIENT)
	ifftplan = plan_ifft!(complex.(zeros(np2,nr)),[1],flags=FFTW.PATIENT)

	# preallocate pow2 vectors
	spow2=complex.(zeros(np2,nr))
	rpow2=complex.(zeros(np2,nr))
	wpow2=complex.(zeros(np2,nr))

	pa = Param(gf, dgf, ntgf, dobs, dcal, ddcal, wav, wavmat, dwavmat,
	     spow2, rpow2, wpow2,
	     nt, nr, attrib_inv, verbose, fftplan, ifftplan)

	F!(pa, mattrib=:gfwav, dattrib=:dobs, gf=gfobs, wav=wavobs)

	return pa
end
function ninv(pa)
	if(pa.attrib_inv == :wav)
		return pa.nt
	else(pa.attrib_inv == :gf)
		return pa.ntgf*pa.nr
	end
end

function model_to_x!(x, pa)
	if(pa.attrib_inv == :wav)
		copy!(x, pa.wav)
	else(pa.attrib_inv == :gf)
		copy!(x, pa.gf)
	end
	return x
end


function x_to_model!(x, pa)
	if(pa.attrib_inv == :wav)
		copy!(pa.wav, x)
	else(pa.attrib_inv == :gf)
		copy!(pa.gf, x)
	end
	return pa
end

function F!(
			pa::Param,
			x::Vector{Float64}=zeros(ninv(pa)),
			last_x::Vector{Float64}=ones(ninv(pa));
			gf=nothing,
			wav=nothing,
			mattrib::Symbol=:x,
			dattrib::Symbol=:dcal,
			   )

	if(x!=last_x)

		if(mattrib == :x)
			x_to_model!(x, pa)
			gf=pa.gf
			wav=pa.wav
		elseif(mattrib == :gf)
			wav=pa.wav
			(gf===nothing) && error("need gf")
		elseif(mattrib == :wav)
			gf=pa.gf
			(wav===nothing) && error("need wav")
		elseif(mattrib == :gfwav)
			(gf===nothing) && error("need gf")
			(wav===nothing) && error("need wav")
		else
			error("invalid mattrib")
		end

		#pa.verbose && println("updating buffer")
		copy!(last_x, x)
		for ir in 1:pa.nr
			pa.wavmat[:,ir]=wav
		end
		DSP.fast_filt!(pa.ddcal, gf, pa.wavmat, :s, nwplags=pa.nt-1,
		 nwnlags=0,nsplags=pa.nt-1,nsnlags=0,nrplags=pa.ntgf-1,nrnlags=0,
		  np2=size(pa.fftplan,1), fftplan=pa.fftplan, ifftplan=pa.ifftplan,
		  spow2=pa.spow2, rpow2=pa.rpow2, wpow2=pa.wpow2,
		  			)
		copy!(getfield(pa, dattrib), pa.ddcal)
		return pa
	end
end

function func_grad!(storage, x::Vector{Float64},
			last_x::Vector{Float64}, 
			pa)

	#pa.verbose && println("computing gradient...")

	# x to w 
	x_to_model!(x, pa)

	F!(pa, x, last_x)

	if(storage === nothing)
		# compute misfit and δdcal
		f = Misfits.fg_cls!(nothing, pa.dcal, pa.dobs)
		return f
	else
		f = Misfits.fg_cls!(pa.ddcal, pa.dcal, pa.dobs)
		Fadj!(pa, storage, pa.ddcal)
		return f
	end
end

"""
Apply Fadj to 
"""
function Fadj!(pa, storage, dcal)
	if(pa.attrib_inv == :wav)
		DSP.fast_filt!(dcal, pa.gf, pa.wavmat, :w, nwplags=pa.nt-1, 
		 nwnlags=0,nsplags=pa.nt-1,nsnlags=0,nrplags=pa.ntgf-1,nrnlags=0,
		  np2=size(pa.fftplan,1), fftplan=pa.fftplan, ifftplan=pa.ifftplan,
		  spow2=pa.spow2, rpow2=pa.rpow2, wpow2=pa.wpow2,
			)
		copy!(storage, sum(pa.wavmat,2))
	else(pa.attrib_inv == :gf)
		for ir in 1:pa.nr
			pa.wavmat[:,ir]=pa.wav
		end
		DSP.fast_filt!(dcal, pa.dgf, pa.wavmat, :r, nwplags=pa.nt-1,
		 nwnlags=0,nsplags=pa.nt-1,nsnlags=0,nrplags=pa.ntgf-1,nrnlags=0,
		  np2=size(pa.fftplan,1), fftplan=pa.fftplan, ifftplan=pa.ifftplan,
		  spow2=pa.spow2, rpow2=pa.rpow2, wpow2=pa.wpow2,
			)
		copy!(storage, pa.dgf)
	end
	return storage
end

# core algorithm
function update!(pa::Param, x, last_x, df; store_trace::Bool=true, extended_trace::Bool=false, 
	     time_limit=Float64=2.0*60., 
	     f_tol::Float64=1e-8, g_tol::Float64=1e-8, x_tol::Float64=1e-8)

	# initial w to x
	model_to_x!(x, pa)

	"""
	Unbounded LBFGS inversion, only for testing
	"""
	res = optimize(df, x, 
		       LBFGS(),
		       Optim.Options(g_tol = g_tol, f_tol=f_tol, x_tol=x_tol,
		       iterations = 200, store_trace = store_trace,
		       extended_trace=extended_trace, show_trace = false))
	pa.verbose && println(res)

	x_to_model!(Optim.minimizer(res), pa)

	return res
end


function update_all!(pa)

	# convert initial model to the inversion variable
	pa.attrib_inv=:gf    
	xgf = zeros(ninv(pa));
	last_xgf = randn(size(xgf)) # reset last_x

	# create df for optimization
	dfgf = OnceDifferentiable(x -> func_grad!(nothing, x, last_xgf, pa),
	  (storage, x) -> func_grad!(storage, x, last_xgf, pa))

	pa.attrib_inv=:wav    
	xwav = zeros(ninv(pa));
	last_xwav = randn(size(xwav)) # reset last_x

	# create df for optimization
	dfwav = OnceDifferentiable(x -> func_grad!(nothing, x, last_xwav, pa),
	  (storage, x) -> func_grad!(storage, x, last_xwav, pa))


	converged_all=false
	itr_all=0
	maxitr_all=10
	while !converged_all && itr_all < maxitr_all
		itr_all += 1
		pa.verbose && (itr_all > 1) && println("\t", "failed to converge.. reintializing round trips")
		# starting models
		randn!(pa.wav)
		randn!(pa.gf)
	
		fgfmin=Inf
		fgfmax=0.0
		fwavmin=Inf
		fwavmax=0.0

		maxitr=1000
		itr=0
		converged=false
		tol=1e-8
		while !converged && itr < maxitr
			pa.verbose && (itr > 1) && println("\t", "round trip: ", itr)
			itr += 1
			pa.attrib_inv=:gf    
			resgf = update!(pa, xgf, last_xgf, dfgf)
			fgf = Optim.minimum(resgf)
			fgfmin = min(fgfmin, fgf) 
			fgfmax = max(fgfmax, fgf) 
			pa.attrib_inv=:wav    
			reswav = update!(pa, xwav, last_xwav, dfwav)
			fwav = Optim.minimum(reswav)
			fwavmin = min(fwavmin, fwav) 
			fwavmax = max(fwavmax, fwav) 

			converged = ((abs(fwav-fgf)) < tol)
		end
		converged_all = (fgfmin/fgfmax < 1e-3) & (fwavmin/fwavmax < 1e-3)
	end
end




# initialize gf and ssf 

# create unknown vector

end # module
