module meth_params_module

  implicit none

  ! fifth-order WENO needs 3 ghost cells
  integer, parameter :: NGROW = 3  

  ! Riemann solvers
  integer, save :: riemann_solver
  integer, parameter :: HLL_solver = 0
  integer, parameter :: JBB_solver = 1
  integer, parameter :: nriemann   = 2

  double precision, save :: difmag
  
  integer, save :: ndim   ! spatial dimension
  integer, save :: NCHARV ! number of characteristic variables
  integer, save :: CFS    ! first species in characteristic variables

  ! conserved variables
  integer         , save :: NVAR, NSPEC
  integer         , save :: URHO, UMX, UMY, UMZ, UEDEN, UTEMP, UFS

  ! primitive variables
  integer         , save :: QCVAR, QFVAR  ! cell-centered and face
  integer         , save :: QRHO, QU, QV, QW, QPRES, QTEMP, QFY, QFX, QFH

  double precision, save :: small_dens, small_temp, small_pres  

  double precision, save :: gravity

end module meth_params_module
