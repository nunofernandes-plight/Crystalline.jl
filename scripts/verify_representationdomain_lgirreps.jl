using Crystalline, LinearAlgebra, Test

include("../data/stopgap_missing_lgirreps.jl") # loads lgirs_dict with some special-point lgirs
# Choose one of 195, 198, 200, 201
#for sgnum in [195, 198, 200, 201] # works for 195 and 200; not for 198 and 201
#sgnum = 201
#target_klab = "ZA"
#sgnum = 24
#target_klab = "WA"
sgnum = 82
target_klab = "PA"

lgirsvec = get_lgirreps(sgnum, Val(3))
append!(lgirsvec, lgirs_dict[sgnum])

target_kidx = findfirst(x->klabel(first(x))==target_klab, lgirsvec)
if target_kidx !== nothing
    target_lgirs = deepcopy(lgirsvec[target_kidx])
    deleteat!(lgirsvec, target_kidx)
end

added_lgirs = find_lgirreps(add_ΦnotΩ_lgirs!(deepcopy(lgirsvec), true), target_klab);

#=
println("\nOriginal: ", string(target_lgirs[1].lg.kv))
display.(target_lgirs)
println("\nComputed: ", string(added_lgirs[1].lg.kv))
display(added_lgirs[1].lg.kv)
display.(added_lgirs)
println()
=#

# Check operator sorting and k-vector
#@test target_lgirs[1].lg.kv == added_lgirs[1].lg.kv
@test all(operations(target_lgirs[1].lg) .== operations(added_lgirs[1].lg))

# Print some info
println('\n','-'^25, ' ', sgnum, ' ', '-'^25, "\nk = ", string(target_lgirs[1].lg.kv), '\n')
print("ops = ")
join(stdout, seitz.(operations(target_lgirs[1].lg)), ", ")
println('\n')

# Difference
αβγ = [0.3,0.2,0.4]

δχ = characters.(target_lgirs, Ref(αβγ)) .- characters.(added_lgirs, Ref(αβγ))
δP = irreps.(target_lgirs, Ref(αβγ)) .- irreps.(added_lgirs, Ref(αβγ))

println.(label.(added_lgirs), Ref(": |δχ| = "), norm.(δχ), ", |δP| = ", norm.(δP)); println()

τs = getfield.(added_lgirs, :translations)
println.(label.(added_lgirs), Ref(": τs = "), τs)
println('-'^55)
#end