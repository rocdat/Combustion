!
! BDF (backward differentiation formula) time-stepping routines.
!
! See
!
!   1. VODE: A variable-coefficient ODE solver; Brown, Byrne, and
!      Hindmarsh; SIAM J. Sci. Stat. Comput., vol. 10, no. 5, pp.
!      1035-1051, 1989.
!
!   2. An alternative implementation of variable step-size multistep
!      formulas for stiff ODES; Jackson and Sacks-Davis; ACM
!      Trans. Math. Soft., vol. 6, no. 3, pp. 295-318, 1980.
!
!   3. A polyalgorithm for the numerical solution of ODEs; Byrne and
!      Hindmarsh; ACM Trans. Math. Soft., vol. 1, no. 1, pp. 71-96,
!      1975.
!

module bdf
  implicit none

  integer, parameter  :: dp   = kind(1.d0)
  real(dp), parameter :: one  = 1.0_dp
  real(dp), parameter :: two  = 2.0_dp
  real(dp), parameter :: half = 0.5_dp

  integer, parameter :: bdf_max_iters = 666666666

  integer, parameter :: BDF_ERR_SUCCESS  = 0
  integer, parameter :: BDF_ERR_SOLVER   = 1
  integer, parameter :: BDF_ERR_MAXSTEPS = 2

  character(len=64), parameter :: errors(0:2) = [ &
       'Success.                                                ', &
       'Newton solver failed to converge several times in a row.', &
       'Too many steps were taken.                              ' ]

  !
  ! bdf time-stepper
  !
  type :: bdf_ts

     ! options
     integer  :: neq                      ! number of equations (degrees of freedom)
     integer  :: max_order                ! maximum order (1 to 6)
     integer  :: max_steps                ! maximum allowable number of steps
     integer  :: max_iters                ! maximum allowable number of newton iterations
     integer  :: verbose                  ! verbosity level
     real(dp) :: dt_min                   ! minimum allowable step-size
     real(dp) :: eta_min                  ! minimum allowable step-size shrink factor
     real(dp) :: eta_max                  ! maximum allowable step-size growth factor
     real(dp) :: eta_thresh               ! step-size growth threshold
     integer  :: max_j_age                ! maximum age of jacobian
     integer  :: max_p_age                ! maximum age of newton iteration matrix

     real(dp), pointer :: rtol(:)         ! realtive tolerances
     real(dp), pointer :: atol(:)         ! absolute tolerances

     ! state
     real(dp) :: t                        ! current time
     real(dp) :: dt                       ! current time step
     real(dp) :: dt_nwt                   ! dt used when building newton iteration matrix
     integer  :: k                        ! current order
     integer  :: n                        ! current step
     integer  :: j_age                    ! age of jacobian
     integer  :: p_age                    ! age of newton iteration matrix
     integer  :: k_age                    ! number of steps taken at current order
     real(dp) :: tq(-1:2)                 ! error coefficients (test quality)
     real(dp) :: tq2save

     real(dp), pointer :: J(:,:)          ! jacobian matrix
     real(dp), pointer :: P(:,:)          ! newton iteration matrix
     real(dp), pointer :: z(:,:)          ! nordsieck histroy array, indexed as (dof, n)
     real(dp), pointer :: z0(:,:)         ! nordsieck predictor array
     real(dp), pointer :: h(:)            ! time steps, h = [ h_n, h_{n-1}, ..., h_{n-k} ]
     real(dp), pointer :: l(:)            ! predictor/corrector update coefficients
     real(dp), pointer :: y(:)            ! current y
     real(dp), pointer :: yd(:)           ! current \dot{y}
     real(dp), pointer :: rhs(:)          ! solver rhs
     real(dp), pointer :: e(:)            ! accumulated correction
     real(dp), pointer :: e1(:)           ! accumulated correction, previous step
     real(dp), pointer :: ewt(:)          ! cached error weights
     real(dp), pointer :: b(:)            ! solver work space
     integer,  pointer :: ipvt(:)         ! pivots
     integer,  pointer :: A(:,:)          ! pascal matrix

     ! counters
     integer :: nfe                       ! number of function evaluations
     integer :: nje                       ! number of jacobian evaluations
     integer :: nlu                       ! number of factorizations
     integer :: nit                       ! number of non-linear solver iterations
     integer :: nse                       ! number of non-linear solver errors
     integer :: ncse                      ! number of consecutive non-linear solver errors

  end type bdf_ts

  private :: &
       rescale_timestep, decrease_order, increase_order, &
       alpha0, alphahat0, xi_j, xi_star, xi_star_inv, ewts, norm, eye_r, eye_i, factorial

contains

  !
  ! Advance system from t0 to t1.
  !
  subroutine bdf_advance(ts, f, Jac, neq, y0, t0, y1, t1, dt0, reset, reuse, ierr)
    type(bdf_ts),     intent(inout) :: ts
    integer,          intent(in)    :: neq
    real(dp),         intent(in)    :: y0(neq), t0, t1, dt0
    real(dp),         intent(out)   :: y1(neq)
    logical,          intent(in)    :: reset, reuse
    integer,          intent(out)   :: ierr
    interface
       subroutine f(neq, y, t, yd)
         import dp
         integer,  intent(in)  :: neq
         real(dp), intent(in)  :: y(neq), t
         real(dp), intent(out) :: yd(neq)
       end subroutine f
       subroutine Jac(neq, y, t, J)
         import dp
         integer,  intent(in)  :: neq
         real(dp), intent(in)  :: y(neq), t
         real(dp), intent(out) :: J(neq, neq)
       end subroutine Jac
    end interface

    include 'LinAlg.inc'

    integer  :: k, m, n, iter, info
    real(dp) :: c, dt_adj, error, dt_rat, eta, inv_l1
    logical  :: rebuild, refactor

    if (reset) call bdf_reset(ts, f, y0, dt0, reuse)

    !
    ! stepping loop
    !

    ts%t = t0
    ts%ncse = 0
    do k = 1, bdf_max_iters + 1

       if (ts%n > ts%max_steps .or. k > bdf_max_iters) then
          ierr = BDF_ERR_MAXSTEPS; return
       end if

       call bdf_update(ts)
       call bdf_predict(ts)


       !
       ! solve y_n - dt f(y_n,t) = y - dt yd for y_n
       !
       !
       ! newton iteration general form is:
       !   solve:   P x = -c G(y(k)) for x
       !   update:  y(k+1) = y(k) + x
       ! where
       !   G(y) = y - dt * f(y,t) - rhs
       !

       inv_l1 = 1.0_dp / ts%l(1)
       do m = 1, neq
          ts%e(m)   = 0
          ts%rhs(m) = ts%z0(m,0) - ts%z0(m,1) * inv_l1
          ts%y(m)   = ts%z0(m,0)
       end do
       dt_adj = ts%dt / ts%l(1)

       dt_rat = dt_adj / ts%dt_nwt
       if (ts%p_age > ts%max_p_age) refactor = .true.
       if (dt_rat < 0.7d0 .or. dt_rat > 1.429d0) refactor = .true.

       do iter = 1, ts%max_iters

          ! build iteration matrix and factor
          if (refactor) then
             rebuild = .true.
             if (ts%ncse == 0 .and. ts%j_age < ts%max_j_age) rebuild = .false.
             if (ts%ncse > 0  .and. (dt_rat < 0.2d0 .or. dt_rat > 5.d0)) rebuild = .false.

             if (rebuild) then
                call Jac(neq, ts%y, ts%t, ts%J)
                ts%nje   = ts%nje + 1
                ts%j_age = 0
             end if

             call eye_r(ts%P)

             do m = 1, neq
                do n = 1, neq
                   ts%P(n,m) = ts%P(n,m) - dt_adj * ts%J(n,m)
                end do
             end do

             call dgefa(ts%P, neq, neq, ts%ipvt, info)
! lapack      call dgetrf(neq, neq, ts%P, neq, ts%ipvt, info)
             ts%nlu    = ts%nlu + 1
             ts%dt_nwt = dt_adj
             ts%p_age  = 0
             refactor  = .false.
          end if

          ! solve using factorized iteration matrix
          call f(neq, ts%y, ts%t, ts%yd)
          ts%nfe = ts%nfe + 1

          c    = 2 * ts%dt_nwt / (dt_adj + ts%dt_nwt)
          do m = 1, neq
             ts%b(m) = c * (ts%rhs(m) - ts%y(m) + dt_adj * ts%yd(m))
          end do
          call dgesl(ts%P, neq, neq, ts%ipvt, ts%b, 0)
! lapack   call dgetrs ('N', neq, 1, ts%P, neq, ts%ipvt, ts%b, neq, info)
          ts%nit = ts%nit + 1

          if (norm(ts%b, ts%ewt) < one) then
             do m = 1, neq
                ts%e(m) = ts%e(m) + ts%b(m)
             end do
             exit
          else
             do m = 1, neq
                ts%e(m) = ts%e(m) + ts%b(m)
                ts%y(m) = ts%z0(m,0) + ts%e(m)
             end do
          end if
       end do

       ts%p_age = ts%p_age + 1; ts%j_age = ts%j_age + 1

       ! if solver failed many times, bail...
       if (iter >= ts%max_iters .and. ts%ncse > 7) then 
          ierr = BDF_ERR_SOLVER; return 
       end if

       ! if solver failed to converge, shrink dt and try again
       if (iter >= ts%max_iters) then
          refactor = .true.; ts%nse = ts%nse + 1; ts%ncse = ts%ncse + 1
          call rescale_timestep(ts, 0.25d0)
          cycle
       end if
       ts%ncse = 0

       ! if local error is too large, shrink dt and try again
       error = ts%tq(0) * norm(ts%e, ts%ewt)
       if (error > one) then
          eta = one / ( (6.d0 * error) ** (one / ts%k) + 1.d-6 )
          call rescale_timestep(ts, eta)
          cycle
       end if

       ! new solution looks good, correct history
       call bdf_correct(ts)
       if (ts%t >= t1) exit

       ! adjust step-size/order
       call bdf_adjust(ts, t1)
    end do

    if (ts%verbose > 0) &
         print '("BDF: n:",i6,", fe:",i6,", je: ",i3,", lu: ",i3,", it: ",i3,", se: ",i3,", dt: ",e15.8,", k: ",i2)', &
         ts%n, ts%nfe, ts%nje, ts%nlu, ts%nit, ts%nse, ts%dt, ts%k

    ierr = BDF_ERR_SUCCESS
    y1   = ts%z(:,0)

  end subroutine bdf_advance

  !
  ! Rescale time-step.
  !
  ! This consists of:
  !   1. bound eta to honor eta_min, eta_max, and dt_min
  !   2. scale dt and adjust time array t accordingly
  !   3. rescalel Nordsieck history array
  !
  subroutine rescale_timestep(ts, eta_in)
    type(bdf_ts), intent(inout) :: ts
    real(dp),     intent(in)    :: eta_in
    real(dp) :: eta
    integer  :: i

    eta = max(eta_in, ts%dt_min / ts%dt, ts%eta_min)
    eta = min(eta, ts%eta_max)

    ts%dt   = eta * ts%dt
    ts%h(0) = ts%dt

    do i = 1, ts%k
       ts%z(:,i) = eta**i * ts%z(:,i)
    end do
  end subroutine rescale_timestep

  !
  ! Decrease order.
  !
  subroutine decrease_order(ts)
    type(bdf_ts), intent(inout) :: ts
    integer  :: j
    real(dp) :: c(0:6)

    if (ts%k > 2) then
       c = 0
       c(2) = 1
       do j = 1, ts%k-2
          c = eoshift(c, -1) + c * xi_j(ts%h, j)
       end do

       do j = 2, ts%k-1
          ts%z(:,j) = ts%z(:,j) - c(j) * ts%z(:,ts%k)
       end do
    end if

    ts%z(:,ts%k) = 0
    ts%k = ts%k - 1
  end subroutine decrease_order

  !
  ! Increase order.
  !
  subroutine increase_order(ts)
    type(bdf_ts), intent(inout) :: ts
    integer  :: j
    real(dp) :: c(0:6)

    c = 0
    c(2) = 1
    do j = 1, ts%k-2
       c = eoshift(c, -1) + c * xi_j(ts%h, j)
    end do

    ts%z(:,ts%k+1) = 0
    do j = 2, ts%k+1
       ts%z(:,j) = ts%z(:,j) + c(j) * ts%e
    end do

    ts%k = ts%k + 1
  end subroutine increase_order

  !
  ! Compute Nordsieck update coefficients l and error coefficients tq.
  !
  ! Regarding the l coefficients, see section 5, and in particular
  ! eqn. 5.2, of Jackson and Sacks-Davis (1980).
  !
  ! Regarding the error coefficients tq, these have been adapted from
  ! cvode.  The tq array is indexed as:
  !
  !  tq(-1) coeff. for order k-1 error est.
  !  tq(0)  coeff. for order k error est.
  !  tq(1)  coeff. for order k+1 error est.
  !  tq(2)  coeff. for order k+1 error est. (used for second derivative)
  !
  ! Note: 
  !
  !   1. The input vector t = [ t_n, t_{n-1}, ... t_{n-k} ] where we
  !      are advancing from step n-1 to step n.
  ! 
  !   2. The step size h_n = t_n - t_{n-1}.
  !
  subroutine bdf_update(ts)
    type(bdf_ts), intent(inout) :: ts

    integer  :: j
    real(dp) :: a0, a0hat, a1, a2, a3, a4, a5, a6, xistar_inv, xi_inv, c

    ts%l  = 0
    ts%tq = 0

    ! compute l vector
    ts%l(0) = 1
    ts%l(1) = xi_j(ts%h, 1)
    if (ts%k > 1) then
       do j = 2, ts%k-1
          ts%l = ts%l + eoshift(ts%l, -1) / xi_j(ts%h, j)
       end do
       ts%l = ts%l + eoshift(ts%l, -1) * xi_star_inv(ts%k, ts%h)
    end if

    ! compute error coefficients (adapted from cvode)
    a0hat = alphahat0(ts%k, ts%h)
    a0    = alpha0(ts%k)

    xi_inv     = one
    xistar_inv = one
    if (ts%k > 1) then
       xi_inv     = one / xi_j(ts%h, ts%k)
       xistar_inv = xi_star_inv(ts%k, ts%h)
    end if

    a1 = one - a0hat + a0
    a2 = one + ts%k * a1
    ts%tq(0) = abs(a1 / (a0 * a2))
    ts%tq(2) = abs(a2 * xistar_inv / (ts%l(ts%k) * xi_inv))
    if (ts%k > 1) then
       c  = xistar_inv / ts%l(ts%k)
       a3 = a0 + one / ts%k
       a4 = a0hat + xi_inv
       ts%tq(-1) = abs(c * (one - a4 + a3) / a3)
    else
       ts%tq(-1) = one
    end if

    xi_inv = ts%h(0) / sum(ts%h(0:ts%k))
    a5 = a0 - one / (ts%k+1)
    a6 = a0hat - xi_inv
    ts%tq(1) = abs((one - a6 + a5) / a2 / (xi_inv * (ts%k+2) * a5))

    call ewts(ts, ts%y, ts%ewt)
  end subroutine bdf_update

  !
  ! Predict (apply Pascal matrix).
  !
  subroutine bdf_predict(ts)
    type(bdf_ts), intent(inout) :: ts
    integer :: i, j, m
    do i = 0, ts%k
       ts%z0(:,i) = 0          
       do j = i, ts%k
          do m = 1, ts%neq
             ts%z0(m,i) = ts%z0(m,i) + ts%A(i,j) * ts%z(m,j)
          end do
       end do
    end do
  end subroutine bdf_predict

  !
  ! Correct (apply l coeffs) and advance step.
  !
  subroutine bdf_correct(ts)
    type(bdf_ts), intent(inout) :: ts
    integer :: i, m

    do i = 0, ts%k
       do m = 1, ts%neq
          ts%z(m,i) = ts%z0(m,i) + ts%e(m) * ts%l(i)
       end do
    end do

    ts%h     = eoshift(ts%h, -1)
    ts%h(0)  = ts%dt
    ts%t     = ts%t + ts%dt
    ts%n     = ts%n + 1
    ts%k_age = ts%k_age + 1
  end subroutine bdf_correct

  !
  ! Adjust step-size/order to maximize step-size.
  !
  subroutine bdf_adjust(ts, t1)
    type(bdf_ts), intent(inout) :: ts
    real(dp),     intent(in)    :: t1

    real(dp) :: c, error, eta(-1:1), rescale, etamax

    eta   = 0
    error = ts%tq(0) * norm(ts%e, ts%ewt)

    ! compute eta(k-1), eta(k), eta(k+1)
    eta(0) = one / ( (6.d0 * error) ** (one / ts%k) + 1.d-6 )
    if (ts%k_age > ts%k) then
       if (ts%k > 1) then
          error   = ts%tq(-1) * norm(ts%z(:,ts%k), ts%ewt)
          eta(-1) = one / ( (6.d0 * error) ** (one / ts%k) + 1.d-6 )
       end if
       if (ts%k < ts%max_order) then
          c = (ts%tq(2) / ts%tq2save) * (ts%h(0) / ts%h(2)) ** (ts%k+1)
          error  = ts%tq(1) * norm(ts%e - c * ts%e1, ts%ewt)
          eta(1) = one / ( (10.d0 * error) ** (one / (ts%k+2)) + 1.d-6 )
       end if
       ts%k_age = 0
    end if

    ! choose which eta will maximize the time step
    rescale = 0
    etamax  = maxval(eta)
    if (etamax > ts%eta_thresh) then
       if (etamax == eta(-1)) then
          call decrease_order(ts)
       else if (etamax == eta(1)) then
          call increase_order(ts)
       end if
       rescale = etamax
    end if

    if (ts%t + ts%dt > t1) then
       rescale = (t1 - ts%t) / ts%dt
    end if

    if (rescale /= 0) call rescale_timestep(ts, rescale)

    ! save for next step (needed to compute eta(1))
    ts%e1 = ts%e
    ts%tq2save = ts%tq(2)

  end subroutine bdf_adjust

  !
  ! Reset counters, set order to one, init history array.
  !
  subroutine bdf_reset(ts, f, y0, dt, reuse)
    type(bdf_ts),     intent(inout) :: ts
    real(dp),         intent(in)    :: y0(ts%neq), dt
    logical,          intent(in)    :: reuse
    interface
       subroutine f(neq, y, t, yd)
         import dp
         integer,  intent(in)  :: neq
         real(dp), intent(in)  :: y(neq), t
         real(dp), intent(out) :: yd(neq)
       end subroutine f
    end interface

    ts%nfe = 0
    ts%nje = 0
    ts%nlu = 0
    ts%nit = 0
    ts%nse = 0

    ts%y  = y0
    ts%dt = dt
    ts%n  = 1
    ts%k  = 1
    ts%h  = ts%dt

    call f(ts%neq, ts%y, ts%t, ts%yd)
    ts%nfe = ts%nfe + 1

    ts%z(:,0) = ts%y
    ts%z(:,1) = ts%dt * ts%yd

    ts%k_age = 0
    if (.not. reuse) then
       ts%j_age = ts%max_j_age + 1
       ts%p_age = ts%max_p_age + 1
    else 
       ts%j_age = 0
       ts%p_age = 0
    end if

  end subroutine bdf_reset

  !
  ! Return $\alpha_0$.
  !
  function alpha0(k) result(a0)
    integer,  intent(in) :: k
    real(dp) :: a0
    integer  :: j
    a0 = -1
    do j = 2, k
       a0 = a0 - one / j
    end do
  end function alpha0

  !
  ! Return $\hat{\alpha}_{n,0}$.
  !
  function alphahat0(k, h) result(a0)
    integer,  intent(in) :: k
    real(dp), intent(in) :: h(0:k)
    real(dp) :: a0
    integer  :: j
    a0 = -1
    do j = 2, k
       a0 = a0 - h(0) / sum(h(0:j-1))
    end do
  end function alphahat0

  !
  ! Return $\xi^*_k$.
  !
  function xi_star(k, h) result(xi)
    integer,  intent(in) :: k
    real(dp), intent(in) :: h(0:)
    real(dp) :: xi, xi_inv(k-1)
    integer  :: j
    do j = 1, k-1
       xi_inv(j) = h(0) / sum(h(0:j-1))
    end do
    xi = -one / (alpha0(k) + sum(xi_inv))
  end function xi_star

  !
  ! Return 1 / $\xi^*_k$.
  !
  function xi_star_inv(k, h) result(xii)
    integer,  intent(in) :: k
    real(dp), intent(in) :: h(0:)
    real(dp) :: xii, hs
    integer  :: j
    hs = 0.0_dp
    xii = -alpha0(k)
    do j = 0, k-2
       hs = hs + h(j)
       xii = xii - h(0) / hs
    end do
  end function xi_star_inv

  !
  ! Return $\xi_j$.
  !
  function xi_j(h, j) result(xi)
    integer,  intent(in) :: j
    real(dp), intent(in) :: h(0:)
    real(dp) :: xi
    xi = sum(h(0:j-1)) / h(0)
  end function xi_j

  ! 
  ! Pre-compute error weights.
  !
  subroutine ewts(ts, y, ewt)
    type(bdf_ts), intent(in)  :: ts
    real(dp),     intent(in)  :: y(1:)
    real(dp),     intent(out) :: ewt(1:)
    integer :: m
    do m = 1, ts%neq
       ewt(m) = one / (ts%rtol(m) * abs(y(m)) + ts%atol(m))
    end do
  end subroutine ewts

  !
  ! Compute weighted norm of y.
  !
  function norm(y, ewt) result(r)
    real(dp), intent(in) :: y(1:), ewt(1:)
    real(dp) :: r
    integer :: m, n
    n = size(y)
    r = 0.0_dp
    do m = 1, n
       r = r + (y(m)*ewt(m))**2
    end do
    r = sqrt(r/n)
  end function norm


  !
  ! Build/destroy BDF time-stepper.
  !

  subroutine bdf_ts_build(ts, neq, rtol, atol, max_order)
    type(bdf_ts), intent(inout) :: ts
    integer,      intent(in   ) :: max_order, neq
    real(dp),     intent(in   ) :: rtol(neq), atol(neq)

    integer :: k, U(max_order+1, max_order+1), Uk(max_order+1, max_order+1)

    allocate(ts%rtol(neq))
    allocate(ts%atol(neq))
    allocate(ts%z(neq, 0:max_order))
    allocate(ts%z0(neq, 0:max_order))
    allocate(ts%l(0:max_order))
    allocate(ts%h(0:max_order))
    allocate(ts%A(0:max_order, 0:max_order))
    allocate(ts%P(neq, neq))
    allocate(ts%J(neq, neq))
    allocate(ts%y(neq))
    allocate(ts%yd(neq))
    allocate(ts%rhs(neq))
    allocate(ts%e(neq))
    allocate(ts%e1(neq))
    allocate(ts%ewt(neq))
    allocate(ts%b(neq))
    allocate(ts%ipvt(neq))

    ts%neq        = neq
    ts%max_order  = max_order
    ts%max_steps  = 1000000
    ts%max_iters  = 10
    ts%verbose    = 0
    ts%dt_min     = epsilon(ts%dt_min)
    ts%eta_min    = 0.2_dp
    ts%eta_max    = 2.25_dp
    ts%eta_thresh = 1.50_dp
    ts%max_j_age  = 50
    ts%max_p_age  = 20

    ts%k = -1

    ts%rtol = rtol
    ts%atol = atol

    ts%j_age = 666666666
    ts%p_age = 666666666

    ! build pascal matrix A using A = exp(U)
    U = 0
    do k = 1, max_order
       U(k,k+1) = k
    end do
    Uk = U
    call eye_i(ts%A)
    do k = 1, max_order+1
       ts%A  = ts%A + Uk / factorial(k)
       Uk = matmul(U, Uk)
    end do
  end subroutine bdf_ts_build

  subroutine bdf_ts_destroy(ts)
    type(bdf_ts), intent(inout) :: ts
    deallocate(ts%h,ts%l,ts%ewt,ts%rtol,ts%atol)
    deallocate(ts%y,ts%yd,ts%z,ts%z0,ts%A)
    deallocate(ts%P,ts%J,ts%rhs,ts%e,ts%e1,ts%b,ts%ipvt)
  end subroutine bdf_ts_destroy


  !
  ! Various misc. helper functions
  !

  subroutine eye_r(A)
    real(dp), intent(inout) :: A(:,:)
    integer :: i
    A = 0
    do i = 1, size(A, 1)
       A(i,i) = 1
    end do
  end subroutine eye_r

  subroutine eye_i(A)
    integer, intent(inout) :: A(:,:)
    integer :: i
    A = 0
    do i = 1, size(A, 1)
       A(i,i) = 1
    end do
  end subroutine eye_i

  recursive function factorial(n) result(r)
    integer, intent(in) :: n
    integer :: r
    if (n == 1) then
       r = 1
    else
       r = n * factorial(n-1)
    end if
  end function factorial

end module bdf
