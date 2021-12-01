# # Setting up a time-varying PDE

#md # ```@meta
#md # CurrentModule = ImmersedLayers
#md # ```

#=
In this example we will demonstrate the use of the package on a time-dependent
PDE, a problem of unsteady heat conduction. We will use the package to
solve for the interior diffusion of temperature from a circle held at constant
temperature.

We seek to solve the heat conduction equation with Dirichlet boundary conditions

$$\dfrac{\partial T}{\partial t} = \kappa \nabla^2 T + q + \sigma \delta(\chi) - \nabla\cdot \left( \kappa [T] \delta(\chi)\right)$$

subject to $T = T_b$ on the immersed surface.

In our discrete formulation, the problem takes the form

$$\begin{bmatrix}
\mathcal{L}_C^\kappa & R_C \\ R_C^T & 0
\end{bmatrix}\begin{pmatrix}
T \\ -\sigma
\end{pmatrix} =
\begin{pmatrix}
q - \kappa D_s [T] \\ T_b
\end{pmatrix}$$

where $\mathcal{L}_C^\kappa = \mathrm{d}/\mathrm{d}t - \kappa L_C$. This has the form required of a
*constrained ODE system*, which the `ConstrainedSystems.jl` package treats.

The main differences from previous examples is that
- we (as the implementers of the PDE) need to specify the functions that calculate the
   various parts of this constrained ODE system.
- we (as the users of this implementation) need to specify the time step size,
   the initial conditions, the time integration range, and create the *integrator*
   to advance the solution.

The latter of these is very easy, as we'll find. Most of our attention will
be on the first part: how to set up the constrained ODE system. For this,
we will make use of the `ConstrainedODEFunction` constructor in the
`ConstrainedSystems.jl` package.
=#

using ImmersedLayers
using Plots
using UnPack

#=
## Set up the constrained ODE system operators
=#
#=
The problem type is generated with the usual macro call. In this example,
we will make use of more of the capabilities of the resulting problem
constructor for "packing" it with information about the problem.
=#
@ilmproblem DirichletHeatConduction scalar

#=
The constrained ODE system requires us to provide functions that calculate
the RHS of the ODE, the RHS of the constraint equation, the Lagrange multiplier force
term in the ODE, and the action of the boundary operator on the state vector.
(You can see the generic form of the system by typing `?ConstrainedODEFunction`)
As you will see, in this example these are `in-place` operators: their
first argument holds the result, which is changed (i.e., mutated)
by the function.
=#
#=
Below, we construct the function that calculates the RHS of the heat conduction ODE.
We have omitted the volumetric heat flux here, supplying only the double-layer
term. Note how this makes use of the physical parameters in `phys_params`
and the boundary data via functions in `bc`. The functions for the boundary
data supply the boundary values. Also, note that the function returns `dT`
in the first argument. This represents this function's contribution to $dT/dt$.
=#
function heatconduction_rhs!(dT,T,sys::ILMSystem,t)
    @unpack bc, forcing, phys_params, extra_cache, base_cache = sys
    @unpack dTb, Tbplus, Tbminus = extra_cache

    κ = phys_params["diffusivity"]

    ## Calculate the double-layer term
    fill!(dT,0.0)
    Tbplus .= bc["Tbplus"](base_cache,t)
    Tbminus .= bc["Tbminus"](base_cache,t)
    dTb .= Tbplus - Tbminus
    surface_divergence!(dT,-κ*dTb,sys)

    return dT
end

#=
Now, we create the function that calculates the RHS of the boundary condition.
For this Dirichlet condition, we simply take the average of the interior
and exterior prescribed values. The first argument `dTb` holds the result.
=#
function heatconduction_bc_constraint_rhs!(dTb,sys::ILMSystem,t)
    @unpack bc, extra_cache, base_cache = sys
    @unpack Tb, Tbplus, Tbminus = extra_cache

    Tbplus .= bc["Tbplus"](base_cache,t)
    Tbminus .= bc["Tbminus"](base_cache,t)
    dTb .= 0.5*(Tbplus + Tbminus)

    return dTb
end

#=
This function calculates the contribution to $dT/dt$ from the Lagrange
multiplier (the input σ). Here, we simply regularize the negative of this
to the grid.
=#
function heatconduction_op_constraint_force!(dT,σ,sys::ILMSystem)
    @unpack extra_cache, base_cache = sys

    fill!(dT,0.0)
    regularize!(dT,-σ,sys)

    return dT
end

#=
Now, we provide the transpose term of the previous function: a function that
interpolates the temperature (state vector) onto the boundary. The first argument `dTb`
holds the result.
=#
function heatconduction_bc_constraint_op!(dTb,T,sys::ILMSystem)
    @unpack extra_cache, base_cache = sys

    fill!(dTb,0.0)
    interpolate!(dTb,T,sys)

    return dTb
end

#=
## Set up the extra cache and extend `prob_cache`
Here, we construct an extra cache that holds a few extra intermediate
variables, used in the routines above. But this cache also, crucially, holds
the constrained ODE function.

The `prob_cache` function creates this ODE function, supplying the functions that we just defined. We
also create a Laplacian operator with the heat diffusivity built into it.
(This operator is singled out from the other terms in the heat conduction
equation, because we account for it separately in the time marching
using a matrix exponential.) We also create a *prototype* of the solution
vector (using `solvector`). This solution vector holds the *state* (which
is the grid temperature data) and *constraint* (the Lagrange multipliers on
the boundary).
=#
struct DirichletHeatConductionCache{DTT,TBT,TBP,TBM,SPT,FT} <: AbstractExtraILMCache
   dTb :: DTT
   Tb :: TBT
   Tbplus :: TBP
   Tbminus :: TBM
   sol_prototype :: SPT
   f :: FT
end

function ImmersedLayers.prob_cache(prob::DirichletHeatConductionProblem,
                                   base_cache::BasicILMCache{N,scaling}) where {N,scaling}
    @unpack phys_params = prob
    @unpack gdata_cache, g = base_cache

    dTb = zeros_surface(base_cache)
    Tb = zeros_surface(base_cache)
    Tbplus = zeros_surface(base_cache)
    Tbminus = zeros_surface(base_cache)

    ## Construct a Lapacian outfitted with the diffusivity
    κ = phys_params["diffusivity"]
    heat_L = Laplacian(base_cache,gdata_cache,κ)

    ## Solution prototype vector, containing the state (grid temperature data)
    ## and constraint (surface Lagrange multipliers)
    sol_prototype = solvector(state=zeros_grid(base_cache),
                              constraint=zeros_surface(base_cache))

    f = ConstrainedODEFunction(heatconduction_rhs!,
                               heatconduction_bc_constraint_rhs!,
                               heatconduction_op_constraint_force!,
                               heatconduction_bc_constraint_op!,
                               heat_L,
                               _func_cache=sol_prototype)

    DirichletHeatConductionCache(dTb,Tb,Tbplus,Tbminus,sol_prototype,f)
end

#=
Before we move on to solving the problem, we need to set up a function
that will calculate the time step size. The time marching algorithm will
call this function. Of course, this could just be used to specify a
time step directly, e.g., by supplying it in `phys_params`. But it
is better to use a stability condition (a Fourier condition) to determine
it based on the other data.
=#
function timestep_fourier(g,phys_params)
    κ = phys_params["diffusivity"]
    Fo = phys_params["Fourier"]
    Δt = Fo*cellsize(g)^2/κ
    return Δt
end


#=
## Solve the problem
We will solve heat conduction inside a circular region with
uniform temperature, with thermal diffusivity equal to 1.
=#

#=
### Set up the grid
=#
Δx = 0.01
Lx = 4.0
xlim = (-Lx/2,Lx/2)
ylim = (-Lx/2,Lx/2)
g = PhysicalGrid(xlim,ylim,Δx);

#=
### Set up the body shape.
Here, we will demonstrate the solution on a circular shape of radius 1.
=#
Δs = 1.4*cellsize(g)
body = Circle(1.0,Δs);

#=
### Specify the physical parameters, data, etc.
These can be changed later without having to regenerate the system.
=#

#=
Here, we create a dict with physical parameters to be passed in.
=#
phys_params = Dict("diffusivity" => 1.0, "Fourier" => 0.25)

#=
The temperature boundary functions on the exterior and interior are
defined here and assembled into a dict.
=#
get_Tbplus(base_cache,t) = zeros_surface(base_cache)
get_Tbminus(base_cache,t) = ones_surface(base_cache)
bcdict = Dict("Tbplus" => get_Tbplus,"Tbminus" => get_Tbminus)

#=
Construct the problem, passing in the data and functions we've just
created.
=#
prob = DirichletHeatConductionProblem(g,body,scaling=GridScaling,
                                             phys_params=phys_params,
                                             bc=bcdict,
                                             timestep_func=timestep_fourier);

#=
Construct the system
=#
sys = ImmersedLayers.__init(prob);

#=
### Solving the problem
In contrast to the previous (time-independent) example, we have not
extended the `solve` function here to serve us in solving this problem.
Instead, we rely on the tools in `ConstrainedSystems.jl` to advance
the solution forward in time. This package builds from the `OrdinaryDiffEq.jl`
package, and leverages most of the tools of that package.
=#

#=
Set an initial condition. Here, we just get a zeroed copy of the
solution prototype that we have stored in the extra cache. We also
get the time step size for our own use.
=#
u0 = zero(sys.extra_cache.sol_prototype)
Δt = timestep_fourier(g,phys_params)


#=
Now, create the integrator, with a time interval of 0 to 1. We have not
specified the algorithm here explicitly; it defaults to the `LiskaIFHERK`
time-marching algorithm, which is a second-order algorithm for constrained
ODE systems that utilizes the matrix exponential (i.e., integrating factor)
for the linear part of the problem. Another choice is the first-order
Euler method, `IFHEEuler`, which one can specify by adding `alg=ConstrainedSystems.IFHEEuler()`
=#
tspan = (0.0,1.0)
integrator = init(u0,tspan,sys)

#=
Now advance the solution by 100 time steps, by using the `step!` function,
which steps through the solution.
=#
step!(integrator,100Δt)

#=
### Plot the solution
Here, we plot the state of the system at the end of the interval.
=#
plot(state(integrator.u),sys)
