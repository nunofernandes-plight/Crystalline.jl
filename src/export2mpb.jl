function lattice2mpb(flat::AbstractFourierLattice)
    orbits = getorbits(flat); coefs = getcoefs(flat)
    Nterms = sum(length, coefs)
    orbits_mpb_vec = Vector{String}(undef, Nterms)
    coefs_mpb_vec  = Vector{String}(undef, Nterms)
    idx = 1
    for (G, c) in zip(Iterators.flatten(orbits), Iterators.flatten(coefs))
        orbits_mpb_vec[idx] = "(vector3"*mapfoldl(x-> " "*string(x), *, G)*")"
        c_re = real(c); c_im = imag(c);
        coefs_mpb_vec[idx]  = string(real(c))*signaschar(c_im)*string(abs(c_im))*"i"
        idx += 1
    end
    orbits_mpb = "(list"*mapfoldl(x->" "*x, *, orbits_mpb_vec)*")"
    coefs_mpb  = "(list"*mapfoldl(x->" "*x, *, coefs_mpb_vec)*")"
    return orbits_mpb, coefs_mpb
end

# returns a lazy "vector" of the (real) value of `flat` over the entire BZ, using `nsamples`
# per dimension; avoids double counting at BZ edges.
function _lazy_fourier_eval_over_bz_as_vector(flat::AbstractFourierLattice{D}, nsamples::Int64) where D
    step = 1.0/nsamples
    samples = range(-0.5, 0.5-step, length=nsamples) # `-step` to avoid double counting ±0.5 (cf. periodicity)
    if D == 2
        itr = (real(calcfourier((x,y), flat)) for x in samples for y in samples)
    elseif D == 3
        itr = (real(calcfourier((x,y,z), flat)) for x in samples for y in samples for z in samples)
    end
end

function filling2isoval(flat::AbstractFourierLattice{D}, filling::Real=0.5, nsamples::Int64=51) where D
    itr = _lazy_fourier_eval_over_bz_as_vector(flat, nsamples)
    return quantile(itr, filling)
end

function isoval2filling(flat::AbstractFourierLattice{D}, isoval::Real, nsamples::Int64=51) where D
    itr = _lazy_fourier_eval_over_bz_as_vector(flat, nsamples)
    return count(<(isoval), itr)/nsamples^D
end

function mpb_calcname!(io, dim, sgnum, id, res, runtype="all")
    write(io, "dim",  string(dim),
              "-sg",  string(sgnum), 
              "-",    string(id),
              "-res", string(res))
    if runtype != "all"
        write(io, "-", runtype)
    end
    return nothing
end
function mpb_calcname(dim, sgnum, id, res, runtype="all")
    io = IOBuffer()
    mpb_calcname!(io, dim, sgnum, id, res, runtype)
    return String(take!(io))
end


function _vec2list(io::IO, f, vs::AbstractVector)
    write(io, "(list")
    for v in vs
        print(io, ' ', f(v))
    end
    write(io, ')')
    return io
end
_vec2list(io::IO, vs::AbstractVector) = _vec2list(io, identity, vs)
_vec2list(f, vs::AbstractArray) = String(take!(_vec2list(IOBuffer(), f, vs)))
_vec2list(vs::AbstractArray) = _vec2list(identity, vs)

function _vec2vector3(v::AbstractVector)
    length(v) > 3 && throw(DomainError(v, "A vector3 must be either one-, two-, or three-dimensional"))

    return "(vector3 "*join(v, ' ')*')'
end

function _mat2matrix3x3(m)
    size(m) ≠ (3,3) && throw(DomainError(m, "A matrix3x3 must be of size (3,3)"))
    # TODO: We should probably allow feeding in 2D and 1D matrices as well.
    io = IOBuffer()
    write(io, "(matrix3x3")
    for i in 1:3
        write(io, ' ', _vec2vector3(@view m[:,i]))
    end
    write(io, ')')
    return String(take!(io))
end

""" 
    prepare_mpbcalc!(...)

Formats a set of parameters that uniquely specify an MPB calculation, given a 
space group number `sgnum`, a Fourier lattice `flat`, a DirectBasis `Rs`, a filling
fraction `filling` for `flat`, interior and exterior (above, below the contour)
permittivities `εin` and `εout`, as well as a list of k-vectors `kvecs`, an 
identifying tag `id` (to label the calculation for book-keeping purposes), a 
resolution for the MPB calculation `res`, and a selection of calculation type
`runtype` ("all", "te", or "tm"). The results are written to requested IO `io`.

Our preferred choice is to write these parameters to a bash file, with a name
generated by the `mpb_calcname(...)` method.

The options are expected to be fed to the `fourier-lattice.ctl` file, e.g. through
a bash script of the following kind:
```sh
    IFS=\$'\\n'; # stop command-substitutions from word-splitting at space

    PATH_TO_MPB_EXECUTABLE \\
        (cat \${calcname}.sh)
        ctl/fourier-lattice.ctl 2>&1 | tee logs/\${calcname}.log
        
    unset IFS; # restore usual command-substitution word-splitting practice
```
where `PATH_TO_MPB_EXECUTABLE` is the path to the MPB executable.
Locally, in `mpb-ctl` we have a file `run-fourier-lattice.sh` which performs the 
above, with `calcname` specified as an input parameter (assumed to be a subfolder
`/input/`).
"""
function prepare_mpbcalc!(io::IO, sgnum::Integer, flat::AbstractFourierLattice{D},
                          Rs::DirectBasis{D},
                          filling::Union{Real, Nothing}=0.5, εin::Real=10.0, εout::Real=1.0,
                          runtype::String="all";
                          # kwargs
                          id=1,
                          res::Integer=32,
                          kvecs::Union{Nothing, AbstractString, AbstractVector{<:Vector{<:Number}}}=nothing,
                          lgs::Union{Nothing, AbstractVector{LittleGroup{D}}}=nothing,
                          nbands::Union{Nothing, Integer}=nothing,
                          isoval::Union{Nothing, Real}=nothing) where D

    # --- prep work to actually call mpb ---
    calcname = mpb_calcname(D, sgnum, id, res, runtype)
    rvecs = _vec2list(_vec2vector3, Rs)
    uc_gvecs, uc_coefs = lattice2mpb(flat)
    if filling !== nothing
        uc_level = filling2isoval(flat, filling)
    elseif isoval !== nothing
        uc_level = isoval
    else
        throw(DomainError((filling, isoval), "Either filling or isoval must be a real number"))
    end
    if filling !== nothing && isoval !== nothing
        throw(DomainError((filling, isoval), "Either filling or isoval must be nothing"))
    end    

    # prepare and write all runtype, structural, and identifying inputs
    print(io, # run-type ("all", "te", or "tm")
              "run-type", "=",  "\"", runtype,  "\"",  "\n",
              # dimension, space group, resolution, and prefix name
              "dim",      "=",        D,               "\n",
              "sgnum",    "=",        sgnum,           "\n",
              "res",      "=",        res,             "\n",
              "prefix",   "=",  "\"", calcname, "\"",  "\n",
              # crystal (basis vectors)
              "rvecs",    "=",        rvecs,           "\n",
              # unitcell/lattice shape
              "uc-gvecs", "=",        uc_gvecs,        "\n",
              "uc-coefs", "=",        uc_coefs,        "\n",
              "uc-level", "=",        uc_level,        "\n",
              # permittivities
              "epsin",    "=",        εin,             "\n",
              "epsout",   "=",        εout,            "\n")
    
    if !isnothing(nbands) # number of bands to solve for (otherwise default to .ctl choice)
        print(io, "nbands", "=",      nbands,          "\n")
    end

    # prepare and write k-vecs and possibly also little group operations
    if lgs !== nothing
        # if `lgs` is supplied, we interpret it as a request to do symmetry eigenvalue
        # calculations at requested little group k-points
        kvecs !== nothing && throw(ArgumentError("One of kvecs or lgs must be nothing"))
        kvecs = write_lgs_to_mpb!(io, lgs)
        println(io)
    end

    # write kvecs (if they are not nothing; we may not always want to give kvecs explicitly,
    #              e.g. for berry phase calculations)
    write(io, "kvecs", "=")
    if kvecs !== nothing 
        if kvecs isa AbstractString
            write(io, "\"", kvecs, "\"")
        elseif kvecs isa AbstractVector{<:Vector{<:Number}}
            _vec2list(io, _vec2vector3, kvecs)
        end
    else
        # easier just to write an empty string than nothing; otherwise we have to bother
        # with figuring out how to remove an empty newline at the end of the file
        write(io, "(list)")
    end

    return nothing
end

function prepare_mpbcalc(sgnum::Integer, flat::AbstractFourierLattice{D}, 
                         Rs::DirectBasis{D}, 
                         filling::Union{Real, Nothing}=0.5, εin::Real=10.0, εout::Real=1.0,
                         runtype::String="all";
                         # kwargs
                         id=1, 
                         res::Integer=32, 
                         kvecs::Union{Nothing, AbstractVector{<:Vector{Number}}}=nothing, 
                         lgs::Union{Nothing, AbstractVector{LittleGroup{D}}}=nothing,
                         nbands::Union{Nothing, Integer}=nothing,
                         isoval::Union{Nothing, Real}=nothing) where D
    io = IOBuffer()
    prepare_mpbcalc!(io, sgnum, flat, Rs, filling, εin, εout, runtype; 
                         res=res, id=id, kvecs=kvecs, lgs=lgs, nbands=nbands, isoval=isoval)
    return String(take!(io))
end

# TODO: Maybe remove this method? 
#       Only parts worth keeping are the matching_littlegroups+primitivize parts...
function gen_symeig_mpbcalc(sgnum, D, εin::Real=10.0, εout::Real=1.0; res::Integer=32, id=1)
    D ∉ (1,3) && _throw_2d_not_yet_implemented(D)

    brs  = bandreps(sgnum, allpaths=false, spinful=false, timereversal=true)
    lgs  = matching_littlegroups(brs)

    cntr = centering(sgnum, D)
    flat = modulate(levelsetlattice(sgnum, D, (1,1,1)))
    Rs   = directbasis(sgnum, D)

    # go to a primitive basis (the lgs from ISOTROPY do not include operations that are 
    # equivalent in a primitive basis, so we _must_ go to the primitive basis)
    lgs′  = primitivize.(lgs)
    flat′ = primitivize(flat, cntr)
    Rs′   = primitivize(Rs, cntr)

    prepare_mpbcalc(sgnum, flat′, Rs′, εin, εout; res=res, lgs=lgs′, id=id)
end
    
function write_lgs_to_mpb!(io::IO, lgs::AbstractVector{<:LittleGroup{D}}) where D
    # build a unique set of all SymOperations across `lgs` and then find the indices
    # into this set for each lg
    ops = unique(Iterators.flatten(operations.(lgs)))
    idxs2ops = [[findfirst(==(op), ops) for op in operations(lg)] for lg in lgs] 

    # write little group symmetry operations at each k-point (as indexing list of lists)
    write(io, "Ws",     "=");  _vec2list(io, _mat2matrix3x3∘rotation,  ops); println(io)
    write(io, "ws",     "=");  _vec2list(io, _vec2vector3∘translation, ops); println(io)
    write(io, "opidxs", "=");  _vec2list(io, _vec2list, idxs2ops);

    # define the k-points across `lgs`, evaluated with (α,β,γ) = TEST_αβγ
    αβγ   = length(TEST_αβγ) == D ? TEST_αβγ : TEST_αβγ[OneTo(D)]
    kvecs = map(lg->kvec(lg)(αβγ), lgs)
    # ... does not print a newline after last line; should be added by callee if relevant

    return kvecs
end


"""
    lattice_from_mpbparams(filepath::String)

This will load an input file with path `filepath` that was previously created by
`prepare_mpbcalc(!)` and return the associated lattice as Julia objects.

Output:
```jl
    Rs::DirectBasis,
    flat::ModulatedFourierLattice,
    isoval::Float64,
    epsin::Float64,
    epsout::Float64
    kvecs::Vector{SVector{D, Float64}}
```

Note that `flat` does not retain information about orbit groupings, since we flatten the 
orbits into a single vector in `lattice2mpb`. This doesn't matter as we typically just want
to plot the saved lattice (see `plot_lattice_from_mpbparams` from `compat/pyplot.jl`).
"""
function lattice_from_mpbparams(io::IO)

    # --- dimension ---
    readuntil(io, "dim=")
    D = parse(Int64, readline(io))

    # --- basis vectors ---
    rewinding_readuntil(io, "rvecs=")
    vecs = Tuple(Vector{Float64}(undef, D) for _ in OneTo(D))
    for R in vecs
        readuntil(io, "(vector3 ")
        coords = split.(readuntil(io, ')'))
        R .= parse.(Ref(Float64), coords)
    end
    Rs = DirectBasis{D}(vecs)

    # --- ("flattened") orbits ---
    rewinding_readuntil(io, "uc-gvecs=")
    gvecs = Vector{SVector{D, Int64}}() 
    while true
        readuntil(io, "(vector3 ")
        coords = split.(readuntil(io, ')'))
        next_gvec = parse.(Ref(Int64), coords)
        push!(gvecs, next_gvec)
        (read(io, Char) == ')') && break # look for a closing (double) parenthesis to match the assumed opening "(list "
    end

    # --- ("flattened") orbit coefficients --- 
    rewinding_readuntil(io, "uc-coefs=")
    readuntil(io, "(list ")
    gcoefs = Vector{ComplexF64}(undef, length(gvecs)) 
    for n in eachindex(gcoefs)
        gcoefs[n] = parse(ComplexF64, readuntil(io, x -> isspace(x) || x==')'))
    end

    # --- ("flattened") Fourier Lattice ---
    # note that we've lost info about orbit groupings (since we flatten on exporting 
    # to mpb in lattice2mpb(...)) but it doesn't matter much, as we only ever need
    # to reload these to see the lattice itself.
    flat = ModulatedFourierLattice{D}([gvecs], [gcoefs])

    # --- iso-level ---
    rewinding_readuntil(io, "uc-level=")
    isoval = parse(Float64, readline(io))

    # --- epsilon values ---
    rewinding_readuntil(io, "epsin=")
    epsin = tryparse(Float64, readline(io))
    rewinding_readuntil(io, "epsout=")
    epsout = tryparse(Float64, readline(io))

    # --- k-vectors ---
    kvecs = kvecs_from_mpbparams(io, D)

    return Rs, flat, isoval, epsin, epsout, kvecs
end
lattice_from_mpbparams(filepath::String) = open(filepath) do io; lattice_from_mpbparams(io); end

function kvecs_from_mpbparams(io::IO, D::Int)
    rewinding_readuntil(io, "kvecs=")
    mark(io)
    # if kvecs is a string, we don't try to do anything with it at this point, and just
    # return nothing instead
    if read(io, Char) !== '"'
        reset(io)
        kvecs = SVector{D, Float64}[]
        while true
            readuntil(io, "(vector3 ")
            coords = split(readuntil(io, ')'))
            next_kvec = parse.(Ref(Float64), coords)
            push!(kvecs, SVector{3,Float64}(next_kvec))
            (read(io, Char) == ')') && break # look for a closing (double) parenthesis to match the assumed opening "(list "
        end
    else # kvecs is a string, interpret as filename in same directory as io's "origin"
        ioname = io.name
        kvecsfile = readuntil(io, "\"")
        if ioname[1:6] == "<file "
            dir = dirname(ioname[7:end-1])
            kvecs = SVector{D, Float64}[]
            open(dir*"/"*kvecsfile) do ioᵏ
                # assume a format "((0.0 0.1 0.2) (0.2 0.3 .4) ... (.3 .1 .2) )" [note the space at the end]
                (read(ioᵏ, Char) == '(' && read(ioᵏ, Char) == '(') || throw("Unexpected format of kvecs file")
                while true
                    coords = split(readuntil(ioᵏ, ")"))
                    next_kvec = parse.(Ref(Float64), coords)
                    push!(kvecs, SVector{3,Float64}(next_kvec))
                    (read(ioᵏ, Char) == ' ' && read(ioᵏ, Char) == '(') || break
                end
            end
        else
            return nothing
        end
    end

    return kvecs
end
kvecs_from_mpbparams(filepath::String, D::Int=3) = open(filepath) do io; kvecs_from_mpbparams(io, D); end

function rewinding_readuntil(io::IO, str::AbstractString)
    readuntil(io, str)
    # we try to be robust to arbitrary ordering of input (otherwise we must assume and 
    # commit to a fixed order of parameters in the input), so we allow the stream to be 
    # reset to its beginnings if we don't find what we're looking for in the first place
    if eof(io); seekstart(io); readuntil(io, str); end # try to be robust to arbitrary ordering

    nothing
end