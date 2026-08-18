!===============================================================================
! mpas_remap_state_v3_restart.F90
!
! High-performance direct native MPAS -> MPAS atmospheric-state remapper.
!
! MULTIDIMENSIONAL I/O SAFETY + PERFORMANCE:
!   Whole NetCDF fields are read into buffers whose dimensions follow
!   the NetCDF-Fortran ordering (e.g. level,cell), then transposed in
!   parallel into computational arrays (cell,level).  Writes perform
!   the reverse transpose.  This preserves V2 semantics with V3 speed.
!
! Horizontal operators:
!   conservative : rho, rho*theta, rho*qv/qc/qr/qi/qs/qg
!   bilinear     : reconstructed winds, w, surface_pressure
!
! Performance design:
!   * whole-field NetCDF reads/writes
!   * OpenMP over full (destination-cell,level) domains
!   * no NetCDF calls inside OpenMP regions
!   * no nested OpenMP
!
! Usage:
!   mpas_remap_state_v3 SOURCE TARGET_TEMPLATE W_SMOOTH W_CONSERVE OUTPUT
!===============================================================================

module mr_kinds
  use iso_fortran_env, only : real64, int32, int64, output_unit
  implicit none
  integer, parameter :: dp=real64, i4=int32, i8=int64
end module mr_kinds

module mr_error
  use netcdf
  use mr_kinds, only : output_unit
  implicit none
contains
  subroutine ncok(status,where)
    integer,intent(in) :: status
    character(len=*),intent(in) :: where
    if(status /= nf90_noerr) then
      write(*,'(a)') 'FATAL NetCDF ['//trim(where)//']: '//trim(nf90_strerror(status))
      error stop 2
    end if
  end subroutine ncok

  subroutine fatal(msg)
    character(len=*),intent(in) :: msg
    write(*,'(a)') 'FATAL: '//trim(msg)
    error stop 2
  end subroutine fatal

  subroutine say(msg)
    character(len=*),intent(in) :: msg
    write(*,'(a)') trim(msg)
    flush(output_unit)
  end subroutine say
end module mr_error

module mr_weights
  use netcdf
  use mr_kinds
  use mr_error
  implicit none

  type :: csr_weights
    integer(i8) :: nsrc=0, ndst=0, nlink=0
    integer(i8), allocatable :: rowptr(:)
    integer(i4), allocatable :: col(:)
    real(dp),    allocatable :: w(:)
  end type csr_weights

contains

  subroutine read_esmf_weights(path,W,expected_nsrc,expected_ndst)
    character(len=*),intent(in) :: path
    type(csr_weights),intent(out) :: W
    integer,intent(in) :: expected_nsrc,expected_ndst
    integer :: ncid,vr,vc,vs,dimid,nlinks,nd
    integer :: ids(nf90_max_var_dims)
    integer(i4),allocatable :: row(:),col(:)
    integer(i8),allocatable :: cnt(:),cur(:)
    real(dp),allocatable :: s(:)
    integer(i8) :: i,r,p

    call say('Reading weights: '//trim(path))
    call ncok(nf90_open(trim(path),nf90_nowrite,ncid),'open weight file')
    call ncok(nf90_inq_varid(ncid,'row',vr),'row')
    call ncok(nf90_inq_varid(ncid,'col',vc),'col')
    call ncok(nf90_inq_varid(ncid,'S',vs),'S')
    call ncok(nf90_inquire_variable(ncid,vr,ndims=nd,dimids=ids),'row layout')
    if(nd /= 1) call fatal('weight row must be 1-D')
    dimid=ids(1)
    call ncok(nf90_inquire_dimension(ncid,dimid,len=nlinks),'n_s')

    allocate(row(nlinks),col(nlinks),s(nlinks))
    call ncok(nf90_get_var(ncid,vr,row),'read row')
    call ncok(nf90_get_var(ncid,vc,col),'read col')
    call ncok(nf90_get_var(ncid,vs,s),'read S')
    call ncok(nf90_close(ncid),'close weights')

    if(minval(row) < 1 .or. maxval(row) > expected_ndst) &
      call fatal('ESMF row index outside destination nCells')
    if(minval(col) < 1 .or. maxval(col) > expected_nsrc) &
      call fatal('ESMF col index outside source nCells')

    W%nsrc=int(expected_nsrc,i8)
    W%ndst=int(expected_ndst,i8)
    W%nlink=int(nlinks,i8)

    allocate(cnt(W%ndst),cur(W%ndst),W%rowptr(W%ndst+1))
    cnt=0_i8
    do i=1,W%nlink
      cnt(row(i))=cnt(row(i))+1_i8
    end do
    if(any(cnt == 0_i8)) call fatal('weight matrix has unmapped destination cells')

    W%rowptr(1)=1_i8
    do r=1,W%ndst
      W%rowptr(r+1)=W%rowptr(r)+cnt(r)
    end do

    allocate(W%col(W%nlink),W%w(W%nlink))
    cur=W%rowptr(1:W%ndst)
    do i=1,W%nlink
      r=int(row(i),i8)
      p=cur(r)
      W%col(p)=col(i)
      W%w(p)=s(i)
      cur(r)=cur(r)+1_i8
    end do

    deallocate(row,col,s,cnt,cur)
    write(*,'(a,i0,a,i0,a,i0)') '  nsrc=',W%nsrc,' ndst=',W%ndst,' links=',W%nlink
  end subroutine read_esmf_weights

  subroutine apply_conserve_3d(W,src,dst)
    type(csr_weights),intent(in) :: W
    real(dp),intent(in) :: src(:,:)
    real(dp),intent(out) :: dst(:,:)
    integer :: k,nlev
    integer(i8) :: j,p
    real(dp) :: a

    if(size(src,1,kind=i8) /= W%nsrc) call fatal('conservative source nCells mismatch')
    if(size(dst,1,kind=i8) /= W%ndst) call fatal('conservative target nCells mismatch')
    if(size(src,2) /= size(dst,2)) call fatal('conservative level mismatch')
    nlev=size(src,2)

    !$omp parallel do collapse(2) default(shared) private(k,j,p,a) schedule(static)
    do k=1,nlev
      do j=1,W%ndst
        a=0.0_dp
        do p=W%rowptr(j),W%rowptr(j+1)-1
          a=a+W%w(p)*src(W%col(p),k)
        end do
        dst(j,k)=a
      end do
    end do
    !$omp end parallel do
  end subroutine apply_conserve_3d

  subroutine apply_smooth_3d(W,src,dst)
    type(csr_weights),intent(in) :: W
    real(dp),intent(in) :: src(:,:)
    real(dp),intent(out) :: dst(:,:)
    integer :: k,nlev
    integer(i8) :: j,p
    real(dp) :: a

    if(size(src,1,kind=i8) /= W%nsrc) call fatal('smooth source nCells mismatch')
    if(size(dst,1,kind=i8) /= W%ndst) call fatal('smooth target nCells mismatch')
    if(size(src,2) /= size(dst,2)) call fatal('smooth level mismatch')
    nlev=size(src,2)

    !$omp parallel do collapse(2) default(shared) private(k,j,p,a) schedule(static)
    do k=1,nlev
      do j=1,W%ndst
        a=0.0_dp
        do p=W%rowptr(j),W%rowptr(j+1)-1
          a=a+W%w(p)*src(W%col(p),k)
        end do
        dst(j,k)=a
      end do
    end do
    !$omp end parallel do
  end subroutine apply_smooth_3d

  subroutine apply_smooth_2d(W,src,dst)
    type(csr_weights),intent(in) :: W
    real(dp),intent(in) :: src(:)
    real(dp),intent(out) :: dst(:)
    integer(i8) :: j,p
    real(dp) :: a

    if(size(src,kind=i8) /= W%nsrc) call fatal('smooth 2-D source nCells mismatch')
    if(size(dst,kind=i8) /= W%ndst) call fatal('smooth 2-D target nCells mismatch')

    !$omp parallel do default(shared) private(j,p,a) schedule(static)
    do j=1,W%ndst
      a=0.0_dp
      do p=W%rowptr(j),W%rowptr(j+1)-1
        a=a+W%w(p)*src(W%col(p))
      end do
      dst(j)=a
    end do
    !$omp end parallel do
  end subroutine apply_smooth_2d
end module mr_weights

module mr_netcdf
  use netcdf
  use mr_kinds
  use mr_error
  use mr_weights, only : csr_weights, apply_smooth_2d, apply_smooth_3d
  implicit none
contains

  logical function has_var(ncid,name)
    integer,intent(in) :: ncid
    character(len=*),intent(in) :: name
    integer :: vid
    has_var=(nf90_inq_varid(ncid,trim(name),vid) == nf90_noerr)
  end function has_var

  integer function dlen(ncid,name)
    integer,intent(in) :: ncid
    character(len=*),intent(in) :: name
    integer :: did
    call ncok(nf90_inq_dimid(ncid,trim(name),did),'dim '//trim(name))
    call ncok(nf90_inquire_dimension(ncid,did,len=dlen),'len '//trim(name))
  end function dlen

  subroutine var_layout(ncid,name,vid,nd,dnames)
    integer,intent(in) :: ncid
    character(len=*),intent(in) :: name
    integer,intent(out) :: vid,nd
    character(len=nf90_max_name),allocatable,intent(out) :: dnames(:)
    integer :: ids(nf90_max_var_dims),i

    call ncok(nf90_inq_varid(ncid,trim(name),vid),'var '//trim(name))
    call ncok(nf90_inquire_variable(ncid,vid,ndims=nd,dimids=ids),'layout '//trim(name))
    allocate(dnames(nd))
    do i=1,nd
      call ncok(nf90_inquire_dimension(ncid,ids(i),name=dnames(i)),'dimension name')
    end do
  end subroutine var_layout



  subroutine read_cell_3d(ncid,name,ncells,nlev,a)
    integer,intent(in) :: ncid,ncells,nlev
    character(len=*),intent(in) :: name
    real(dp),intent(out) :: a(ncells,nlev)

    integer :: vid,nd,i,k,pos_cell,pos_lev
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_cell=0
    pos_lev=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nCells')
        pos_cell=i
        ct(i)=ncells
      case('nVertLevels')
        pos_lev=i
        ct(i)=nlev
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        call fatal(trim(name)//' unsupported 3-D dimension '//trim(dn(i)))
      end select
    end do

    if(pos_cell == 0 .or. pos_lev == 0) then
      call fatal(trim(name)//' missing nCells/nVertLevels')
    end if

    if(pos_lev < pos_cell) then
      allocate(tmp(nlev,ncells))
      call ncok(nf90_get_var(ncid,vid,tmp,start=st,count=ct), &
                'read whole '//trim(name))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do k=1,nlev
        do i=1,ncells
          a(i,k)=tmp(k,i)
        end do
      end do
      !$omp end parallel do

      deallocate(tmp)
    else
      call ncok(nf90_get_var(ncid,vid,a,start=st,count=ct), &
                'read whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine read_cell_3d


  subroutine write_cell_3d(ncid,name,ncells,nlev,a)
    integer,intent(in) :: ncid,ncells,nlev
    character(len=*),intent(in) :: name
    real(dp),intent(in) :: a(ncells,nlev)

    integer :: vid,nd,i,k,pos_cell,pos_lev
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    if(.not.has_var(ncid,name)) then
      call say('WARNING target has no '//trim(name)//'; skipping')
      return
    end if

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_cell=0
    pos_lev=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nCells')
        pos_cell=i
        ct(i)=ncells
      case('nVertLevels')
        pos_lev=i
        ct(i)=nlev
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        call fatal(trim(name)//' unsupported 3-D dimension '//trim(dn(i)))
      end select
    end do

    if(pos_cell == 0 .or. pos_lev == 0) then
      call fatal(trim(name)//' missing nCells/nVertLevels')
    end if

    if(pos_lev < pos_cell) then
      allocate(tmp(nlev,ncells))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do i=1,ncells
        do k=1,nlev
          tmp(k,i)=a(i,k)
        end do
      end do
      !$omp end parallel do

      call ncok(nf90_put_var(ncid,vid,tmp,start=st,count=ct), &
                'write whole '//trim(name))
      deallocate(tmp)
    else
      call ncok(nf90_put_var(ncid,vid,a,start=st,count=ct), &
                'write whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine write_cell_3d


  subroutine read_interface_3d(ncid,name,ncells,nlevp1,a)
    integer,intent(in) :: ncid,ncells,nlevp1
    character(len=*),intent(in) :: name
    real(dp),intent(out) :: a(ncells,nlevp1)

    integer :: vid,nd,i,k,pos_cell,pos_lev
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_cell=0
    pos_lev=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nCells')
        pos_cell=i
        ct(i)=ncells
      case('nVertLevelsP1')
        pos_lev=i
        ct(i)=nlevp1
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        call fatal(trim(name)//' unsupported interface dimension '//trim(dn(i)))
      end select
    end do

    if(pos_cell == 0 .or. pos_lev == 0) then
      call fatal(trim(name)//' missing nCells/nVertLevelsP1')
    end if

    if(pos_lev < pos_cell) then
      allocate(tmp(nlevp1,ncells))
      call ncok(nf90_get_var(ncid,vid,tmp,start=st,count=ct), &
                'read whole '//trim(name))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do k=1,nlevp1
        do i=1,ncells
          a(i,k)=tmp(k,i)
        end do
      end do
      !$omp end parallel do

      deallocate(tmp)
    else
      call ncok(nf90_get_var(ncid,vid,a,start=st,count=ct), &
                'read whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine read_interface_3d


  subroutine write_interface_3d(ncid,name,ncells,nlevp1,a)
    integer,intent(in) :: ncid,ncells,nlevp1
    character(len=*),intent(in) :: name
    real(dp),intent(in) :: a(ncells,nlevp1)

    integer :: vid,nd,i,k,pos_cell,pos_lev
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    if(.not.has_var(ncid,name)) return

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_cell=0
    pos_lev=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nCells')
        pos_cell=i
        ct(i)=ncells
      case('nVertLevelsP1')
        pos_lev=i
        ct(i)=nlevp1
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        call fatal(trim(name)//' unsupported interface dimension '//trim(dn(i)))
      end select
    end do

    if(pos_lev < pos_cell) then
      allocate(tmp(nlevp1,ncells))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do i=1,ncells
        do k=1,nlevp1
          tmp(k,i)=a(i,k)
        end do
      end do
      !$omp end parallel do

      call ncok(nf90_put_var(ncid,vid,tmp,start=st,count=ct), &
                'write whole '//trim(name))
      deallocate(tmp)
    else
      call ncok(nf90_put_var(ncid,vid,a,start=st,count=ct), &
                'write whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine write_interface_3d

  subroutine read_surface_2d(ncid,name,ncells,a)
    integer,intent(in) :: ncid,ncells
    character(len=*),intent(in) :: name
    real(dp),intent(out) :: a(ncells)
    integer :: vid,nd,i
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd)); st=1; ct=1
    do i=1,nd
      select case(trim(dn(i)))
      case('nCells'); ct(i)=ncells
      case('Time');   st(i)=1; ct(i)=1
      case default; call fatal(trim(name)//' unsupported surface dimension '//trim(dn(i)))
      end select
    end do
    call ncok(nf90_get_var(ncid,vid,a,start=st,count=ct),'read '//trim(name))
    deallocate(st,ct,dn)
  end subroutine read_surface_2d

  subroutine write_surface_2d(ncid,name,ncells,a)
    integer,intent(in) :: ncid,ncells
    character(len=*),intent(in) :: name
    real(dp),intent(in) :: a(ncells)
    integer :: vid,nd,i
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)

    if(.not.has_var(ncid,name)) return
    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd)); st=1; ct=1
    do i=1,nd
      select case(trim(dn(i)))
      case('nCells'); ct(i)=ncells
      case('Time');   st(i)=1; ct(i)=1
      case default; call fatal(trim(name)//' unsupported surface dimension '//trim(dn(i)))
      end select
    end do
    call ncok(nf90_put_var(ncid,vid,a,start=st,count=ct),'write '//trim(name))
    deallocate(st,ct,dn)
  end subroutine write_surface_2d



  subroutine write_edge_3d(ncid,name,nedges,nlev,a)
    integer,intent(in) :: ncid,nedges,nlev
    character(len=*),intent(in) :: name
    real(dp),intent(in) :: a(nedges,nlev)

    integer :: vid,nd,i,k,pos_edge,pos_lev
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    if(.not.has_var(ncid,name)) then
      call say('WARNING target has no '//trim(name)//'; skipping')
      return
    end if

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_edge=0
    pos_lev=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nEdges')
        pos_edge=i
        ct(i)=nedges
      case('nVertLevels')
        pos_lev=i
        ct(i)=nlev
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        call fatal(trim(name)//' unsupported edge dimension '//trim(dn(i)))
      end select
    end do

    if(pos_edge == 0 .or. pos_lev == 0) then
      call fatal(trim(name)//' missing nEdges/nVertLevels')
    end if

    if(pos_lev < pos_edge) then
      allocate(tmp(nlev,nedges))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do i=1,nedges
        do k=1,nlev
          tmp(k,i)=a(i,k)
        end do
      end do
      !$omp end parallel do

      call ncok(nf90_put_var(ncid,vid,tmp,start=st,count=ct), &
                'write whole '//trim(name))
      deallocate(tmp)
    else
      call ncok(nf90_put_var(ncid,vid,a,start=st,count=ct), &
                'write whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine write_edge_3d

  subroutine read_target_geometry(ncid,ncells,nedges,lat,lon,coe,enorm)
    integer,intent(in) :: ncid,ncells,nedges
    real(dp),intent(out) :: lat(ncells),lon(ncells),enorm(3,nedges)
    integer(i4),intent(out) :: coe(2,nedges)
    integer :: vid

    call ncok(nf90_inq_varid(ncid,'latCell',vid),'latCell')
    call ncok(nf90_get_var(ncid,vid,lat),'read latCell')
    call ncok(nf90_inq_varid(ncid,'lonCell',vid),'lonCell')
    call ncok(nf90_get_var(ncid,vid,lon),'read lonCell')
    call ncok(nf90_inq_varid(ncid,'cellsOnEdge',vid),'cellsOnEdge')
    call ncok(nf90_get_var(ncid,vid,coe),'read cellsOnEdge')
    call ncok(nf90_inq_varid(ncid,'edgeNormalVectors',vid),'edgeNormalVectors')
    call ncok(nf90_get_var(ncid,vid,enorm),'read edgeNormalVectors')
  end subroutine read_target_geometry

  subroutine copy_time_metadata(ncs,nct)
    integer,intent(in) :: ncs,nct
    integer :: vs,vt,status
    character(len=64) :: txt

    if(has_var(ncs,'xtime') .and. has_var(nct,'xtime')) then
      txt=' '
      call ncok(nf90_inq_varid(ncs,'xtime',vs),'source xtime')
      call ncok(nf90_inq_varid(nct,'xtime',vt),'target xtime')
      call ncok(nf90_get_var(ncs,vs,txt),'read source xtime')
      call ncok(nf90_put_var(nct,vt,txt),'write target xtime')
      call say('Output xtime       : '//trim(txt))
    end if

    if(has_var(ncs,'initial_time') .and. has_var(nct,'initial_time')) then
      txt=' '
      call ncok(nf90_inq_varid(ncs,'initial_time',vs),'source initial_time')
      call ncok(nf90_inq_varid(nct,'initial_time',vt),'target initial_time')
      call ncok(nf90_get_var(ncs,vs,txt),'read source initial_time')
      call ncok(nf90_put_var(nct,vt,txt),'write target initial_time')
    end if

    txt=' '
    status=nf90_get_att(ncs,nf90_global,'config_start_time',txt)
    if(status == nf90_noerr) &
      call ncok(nf90_put_att(nct,nf90_global,'config_start_time',trim(txt)),'write config_start_time')

    txt=' '
    status=nf90_get_att(ncs,nf90_global,'config_stop_time',txt)
    if(status == nf90_noerr) &
      call ncok(nf90_put_att(nct,nf90_global,'config_stop_time',trim(txt)),'write config_stop_time')
  end subroutine copy_time_metadata

  subroutine ensure_reconstructed_winds(ncid)
    integer,intent(in) :: ncid
    integer :: did_time,did_cells,did_lev,vid_u,vid_v,dims(3)
    logical :: need_u,need_v

    need_u=.not.has_var(ncid,'uReconstructZonal')
    need_v=.not.has_var(ncid,'uReconstructMeridional')
    if(.not.need_u .and. .not.need_v) return

    call say('Creating missing reconstructed wind variables in target')
    call ncok(nf90_inq_dimid(ncid,'Time',did_time),'dimension Time')
    call ncok(nf90_inq_dimid(ncid,'nCells',did_cells),'dimension nCells')
    call ncok(nf90_inq_dimid(ncid,'nVertLevels',did_lev),'dimension nVertLevels')

    ! Fortran dimension order is reverse of ncdump/C order.
    dims=(/did_lev,did_cells,did_time/)

    call ncok(nf90_redef(ncid),'redef target')

    if(need_u) then
      call ncok(nf90_def_var(ncid,'uReconstructZonal',nf90_float,dims,vid_u),'define uReconstructZonal')
      call ncok(nf90_put_att(ncid,vid_u,'units','m s^{-1}'),'uReconstructZonal units')
      call ncok(nf90_put_att(ncid,vid_u,'long_name', &
        'Zonal component of reconstructed horizontal velocity at cell centers'),'uReconstructZonal long_name')
    end if

    if(need_v) then
      call ncok(nf90_def_var(ncid,'uReconstructMeridional',nf90_float,dims,vid_v),'define uReconstructMeridional')
      call ncok(nf90_put_att(ncid,vid_v,'units','m s^{-1}'),'uReconstructMeridional units')
      call ncok(nf90_put_att(ncid,vid_v,'long_name', &
        'Meridional component of reconstructed horizontal velocity at cell centers'),'uReconstructMeridional long_name')
    end if

    call ncok(nf90_enddef(ncid),'enddef target')
  end subroutine ensure_reconstructed_winds



  subroutine read_cell_extra_3d(ncid,name,ncells,nextra,a)
    integer,intent(in) :: ncid,ncells,nextra
    character(len=*),intent(in) :: name
    real(dp),intent(out) :: a(ncells,nextra)

    integer :: vid,nd,i,k,pos_cell,pos_extra,nother
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_cell=0
    pos_extra=0
    nother=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nCells')
        pos_cell=i
        ct(i)=ncells
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        nother=nother+1
        pos_extra=i
        ct(i)=nextra
      end select
    end do

    if(nother /= 1 .or. pos_cell == 0) then
      call fatal(trim(name)//' unsupported extra-dimension layout')
    end if

    if(pos_extra < pos_cell) then
      allocate(tmp(nextra,ncells))
      call ncok(nf90_get_var(ncid,vid,tmp,start=st,count=ct), &
                'read whole '//trim(name))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do k=1,nextra
        do i=1,ncells
          a(i,k)=tmp(k,i)
        end do
      end do
      !$omp end parallel do

      deallocate(tmp)
    else
      call ncok(nf90_get_var(ncid,vid,a,start=st,count=ct), &
                'read whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine read_cell_extra_3d


  subroutine write_cell_extra_3d(ncid,name,ncells,nextra,a)
    integer,intent(in) :: ncid,ncells,nextra
    character(len=*),intent(in) :: name
    real(dp),intent(in) :: a(ncells,nextra)

    integer :: vid,nd,i,k,pos_cell,pos_extra,nother
    integer,allocatable :: st(:),ct(:)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: tmp(:,:)

    if(.not.has_var(ncid,name)) return

    call var_layout(ncid,name,vid,nd,dn)
    allocate(st(nd),ct(nd))
    st=1
    ct=1
    pos_cell=0
    pos_extra=0
    nother=0

    do i=1,nd
      select case(trim(dn(i)))
      case('nCells')
        pos_cell=i
        ct(i)=ncells
      case('Time')
        st(i)=1
        ct(i)=1
      case default
        nother=nother+1
        pos_extra=i
        ct(i)=nextra
      end select
    end do

    if(nother /= 1 .or. pos_cell == 0) then
      call fatal(trim(name)//' unsupported extra-dimension layout')
    end if

    if(pos_extra < pos_cell) then
      allocate(tmp(nextra,ncells))

      !$omp parallel do collapse(2) default(shared) private(i,k) schedule(static)
      do i=1,ncells
        do k=1,nextra
          tmp(k,i)=a(i,k)
        end do
      end do
      !$omp end parallel do

      call ncok(nf90_put_var(ncid,vid,tmp,start=st,count=ct), &
                'write whole '//trim(name))
      deallocate(tmp)
    else
      call ncok(nf90_put_var(ncid,vid,a,start=st,count=ct), &
                'write whole '//trim(name))
    end if

    deallocate(st,ct,dn)
  end subroutine write_cell_extra_3d

  subroutine remap_cell_field_smooth(ncs,nct,name,W,nsrc,ndst)
    integer,intent(in) :: ncs,nct,nsrc,ndst
    character(len=*),intent(in) :: name
    type(csr_weights),intent(in) :: W

    integer :: vs,vt,nds,ndt,i,nextra_s,nextra_t
    integer :: ids(nf90_max_var_dims)
    character(len=nf90_max_name),allocatable :: dns(:),dnt(:)
    real(dp),allocatable :: s2(:),d2(:)
    real(dp),allocatable :: s3(:,:),d3(:,:)

    if(.not.has_var(ncs,name)) then
      call say('  skip '//trim(name)//' (missing in source)')
      return
    end if

    if(.not.has_var(nct,name)) then
      call say('  skip '//trim(name)//' (missing in target)')
      return
    end if

    call var_layout(ncs,name,vs,nds,dns)
    call var_layout(nct,name,vt,ndt,dnt)

    if(nds /= ndt) then
      call say('  skip '//trim(name)//' (source/target rank mismatch)')
      deallocate(dns,dnt)
      return
    end if

    ! Count dimensions other than Time and nCells.
    nextra_s=0
    do i=1,nds
      if(trim(dns(i)) /= 'Time' .and. trim(dns(i)) /= 'nCells') then
        nextra_s=nextra_s+1
      end if
    end do

    ! Surface field: Time,nCells (or just nCells).
    if(nextra_s == 0) then
      allocate(s2(nsrc),d2(ndst))
      call read_surface_2d(ncs,name,nsrc,s2)
      call apply_smooth_2d(W,s2,d2)
      call write_surface_2d(nct,name,ndst,d2)
      deallocate(s2,d2,dns,dnt)
      call say('  remapped '//trim(name))
      return
    end if

    if(nextra_s /= 1) then
      call say('  skip '//trim(name)//' (more than one extra dimension)')
      deallocate(dns,dnt)
      return
    end if

    ! General Time,nCells,<one extra dimension>.
    nextra_s=-1
    nextra_t=-1

    call ncok(nf90_inquire_variable(ncs,vs,dimids=ids),'layout '//trim(name))

    do i=1,nds
      if(trim(dns(i)) /= 'Time' .and. trim(dns(i)) /= 'nCells') then
        nextra_s=dlen(ncs,trim(dns(i)))
      end if
    end do

    call ncok(nf90_inquire_variable(nct,vt,dimids=ids),'target layout '//trim(name))

    do i=1,ndt
      if(trim(dnt(i)) /= 'Time' .and. trim(dnt(i)) /= 'nCells') then
        nextra_t=dlen(nct,trim(dnt(i)))
      end if
    end do

    if(nextra_s < 1 .or. nextra_t < 1 .or. nextra_s /= nextra_t) then
      call say('  skip '//trim(name)//' (unsupported/mismatched extra dimension)')
      deallocate(dns,dnt)
      return
    end if

    allocate(s3(nsrc,nextra_s),d3(ndst,nextra_t))
    call read_cell_extra_3d(ncs,name,nsrc,nextra_s,s3)
    call apply_smooth_3d(W,s3,d3)
    call write_cell_extra_3d(nct,name,ndst,nextra_t,d3)
    deallocate(s3,d3,dns,dnt)

    call say('  remapped '//trim(name))
  end subroutine remap_cell_field_smooth


  subroutine zero_cell_field(ncid,name,ncells)
    integer,intent(in) :: ncid,ncells
    character(len=*),intent(in) :: name

    integer :: vid,nd,i,nextra
    integer :: ids(nf90_max_var_dims)
    character(len=nf90_max_name),allocatable :: dn(:)
    real(dp),allocatable :: z2(:),z3(:,:)

    if(.not.has_var(ncid,name)) return

    call var_layout(ncid,name,vid,nd,dn)

    if(nd == 1 .or. nd == 2) then
      allocate(z2(ncells))
      z2=0.0_dp
      call write_surface_2d(ncid,name,ncells,z2)
      deallocate(z2,dn)
      call say('  reset '//trim(name))
      return
    end if

    nextra=-1
    do i=1,nd
      if(trim(dn(i)) /= 'Time' .and. trim(dn(i)) /= 'nCells') then
        nextra=dlen(ncid,trim(dn(i)))
      end if
    end do

    if(nextra < 1) then
      call say('  skip reset '//trim(name)//' (unsupported dimensions)')
      deallocate(dn)
      return
    end if

    allocate(z3(ncells,nextra))
    z3=0.0_dp
    call write_cell_extra_3d(ncid,name,ncells,nextra,z3)
    deallocate(z3,dn)

    call say('  reset '//trim(name))
  end subroutine zero_cell_field


end module mr_netcdf

module mr_physics
  use mr_kinds
  use mr_weights
  use mr_error
  implicit none

  real(dp),parameter :: rgas=287.0_dp
  real(dp),parameter :: rv=461.6_dp
  real(dp),parameter :: cp=7.0_dp*rgas/2.0_dp
  real(dp),parameter :: p0=1.0e5_dp
  real(dp),parameter :: rvord=rv/rgas
  real(dp),parameter :: rcv=rgas/(cp-rgas)

contains

  subroutine positive_3d(a)
    real(dp),intent(inout) :: a(:,:)
    !$omp parallel workshare
    a=max(a,0.0_dp)
    !$omp end parallel workshare
  end subroutine positive_3d

  subroutine rho_weighted_3d(W,rhos,xs,rhot,xt)
    type(csr_weights),intent(in) :: W
    real(dp),intent(in) :: rhos(:,:),xs(:,:),rhot(:,:)
    real(dp),intent(out) :: xt(:,:)
    real(dp),allocatable :: msrc(:,:),mdst(:,:)

    allocate(msrc(size(rhos,1),size(rhos,2)))
    allocate(mdst(size(rhot,1),size(rhot,2)))

    !$omp parallel workshare
    msrc=rhos*xs
    !$omp end parallel workshare

    call apply_conserve_3d(W,msrc,mdst)

    !$omp parallel workshare
    where(rhot > 1.0e-14_dp)
      xt=mdst/rhot
    elsewhere
      xt=0.0_dp
    end where
    !$omp end parallel workshare

    deallocate(msrc,mdst)
  end subroutine rho_weighted_3d

  subroutine rebuild_thermo_3d(rho,theta,qv,zz,rho_base,theta_base, &
                               rho_zz,theta_m,rho_p,rtheta_base,rtheta_p, &
                               exner,exner_base,pressure_p,pressure_base)
    real(dp),intent(in) :: rho(:,:),theta(:,:),qv(:,:),zz(:,:)
    real(dp),intent(in) :: rho_base(:,:),theta_base(:,:)
    real(dp),intent(out) :: rho_zz(:,:),theta_m(:,:),rho_p(:,:)
    real(dp),intent(out) :: rtheta_base(:,:),rtheta_p(:,:)
    real(dp),intent(out) :: exner(:,:),exner_base(:,:),pressure_p(:,:),pressure_base(:,:)
    integer :: k,nlev
    integer(i8) :: j
    real(dp) :: zloc,rtb,rtp,exn,exb

    nlev=size(rho,2)
    !$omp parallel do collapse(2) default(shared) private(k,j,zloc,rtb,rtp,exn,exb) schedule(static)
    do k=1,nlev
      do j=1,size(rho,1,kind=i8)
        zloc=max(zz(j,k),1.0e-12_dp)
        theta_m(j,k)=theta(j,k)*(1.0_dp+rvord*qv(j,k))
        rho_zz(j,k)=rho(j,k)/zloc
        rho_p(j,k)=rho_zz(j,k)-rho_base(j,k)
        rtb=theta_base(j,k)*rho_base(j,k)
        rtp=theta_m(j,k)*rho_p(j,k)+rho_base(j,k)*(theta_m(j,k)-theta_base(j,k))
        rtheta_base(j,k)=rtb
        rtheta_p(j,k)=rtp
        exn=(zloc*(rgas/p0)*max(rtp+rtb,1.0e-20_dp))**rcv
        exb=(zloc*(rgas/p0)*max(rtb,1.0e-20_dp))**rcv
        exner(j,k)=exn
        exner_base(j,k)=exb
        pressure_p(j,k)=zloc*rgas*(exn*rtp+rtb*(exn-exb))
        pressure_base(j,k)=zloc*rgas*exb*rtb
      end do
    end do
    !$omp end parallel do
  end subroutine rebuild_thermo_3d

  subroutine reconstruct_edge_u_3d(lat,lon,coe,enorm,ue,vn,uedge)
    real(dp),intent(in) :: lat(:),lon(:),enorm(:,:)
    integer(i4),intent(in) :: coe(:,:)
    real(dp),intent(in) :: ue(:,:),vn(:,:)
    real(dp),intent(out) :: uedge(:,:)
    integer :: k,nlev,c1,c2
    integer(i8) :: e
    real(dp) :: v1(3),v2(3),v(3),east(3),north(3),la,lo

    nlev=size(ue,2)
    !$omp parallel do collapse(2) default(shared) private(k,e,c1,c2,v1,v2,v,east,north,la,lo) schedule(static)
    do k=1,nlev
      do e=1,size(uedge,1,kind=i8)
        c1=coe(1,e); c2=coe(2,e)
        v1=0.0_dp; v2=0.0_dp

        if(c1 > 0) then
          la=lat(c1); lo=lon(c1)
          east=(/-sin(lo),cos(lo),0.0_dp/)
          north=(/-sin(la)*cos(lo),-sin(la)*sin(lo),cos(la)/)
          v1=ue(c1,k)*east+vn(c1,k)*north
        end if

        if(c2 > 0) then
          la=lat(c2); lo=lon(c2)
          east=(/-sin(lo),cos(lo),0.0_dp/)
          north=(/-sin(la)*cos(lo),-sin(la)*sin(lo),cos(la)/)
          v2=ue(c2,k)*east+vn(c2,k)*north
        end if

        if(c1 > 0 .and. c2 > 0) then
          v=0.5_dp*(v1+v2)
        else if(c1 > 0) then
          v=v1
        else if(c2 > 0) then
          v=v2
        else
          v=0.0_dp
        end if

        uedge(e,k)=dot_product(v,enorm(:,e))
      end do
    end do
    !$omp end parallel do
  end subroutine reconstruct_edge_u_3d

  subroutine compute_ru_3d(coe,u,rho_zz,ru)
    integer(i4),intent(in) :: coe(:,:)
    real(dp),intent(in) :: u(:,:),rho_zz(:,:)
    real(dp),intent(out) :: ru(:,:)
    integer :: k,nlev,c1,c2
    integer(i8) :: e

    nlev=size(u,2)
    !$omp parallel do collapse(2) default(shared) private(k,e,c1,c2) schedule(static)
    do k=1,nlev
      do e=1,size(u,1,kind=i8)
        c1=coe(1,e); c2=coe(2,e)
        if(c1 > 0 .and. c2 > 0) then
          ru(e,k)=0.5_dp*u(e,k)*(rho_zz(c1,k)+rho_zz(c2,k))
        else if(c1 > 0) then
          ru(e,k)=u(e,k)*rho_zz(c1,k)
        else if(c2 > 0) then
          ru(e,k)=u(e,k)*rho_zz(c2,k)
        else
          ru(e,k)=0.0_dp
        end if
      end do
    end do
    !$omp end parallel do
  end subroutine compute_ru_3d
end module mr_physics

program mpas_remap_state_v3_restart
  use netcdf
  use mr_kinds
  use mr_error
  use mr_weights
  use mr_netcdf
  use mr_physics
  implicit none

  character(len=1024) :: srcfile,tplfile,wsfile,wcfile,outfile
  character(len=4096) :: cmd
  integer :: ncs,nct,nsrc,ndst,nlevs,nlevt,nintf_s,nintf_t,nedges,iq
  type(csr_weights) :: Ws,Wc

  real(dp),allocatable :: src3(:,:),dst3(:,:),rhos(:,:),rhot(:,:),theta_t(:,:),qv_t(:,:)
  real(dp),allocatable :: ue(:,:),vn(:,:),uedge(:,:),ruedge(:,:),wsrc(:,:),wdst(:,:)
  real(dp),allocatable :: surf_src(:),surf_dst(:)
  real(dp),allocatable :: lat(:),lon(:),enorm(:,:)
  integer(i4),allocatable :: coe(:,:)
  real(dp),allocatable :: zz(:,:),rho_base(:,:),theta_base(:,:)
  real(dp),allocatable :: rho_zz(:,:),theta_m(:,:),rho_p(:,:),rtheta_base(:,:),rtheta_p(:,:)
  real(dp),allocatable :: exner(:,:),exner_base(:,:),pressure_p(:,:),pressure_base(:,:)
  character(len=8),dimension(6) :: qname

  integer :: jf
  character(len=32),dimension(52) :: remap_state
  character(len=32),dimension(34) :: reset_state

  if(command_argument_count() /= 5) then
    write(*,'(a)') 'Usage: mpas_remap_state_v3_restart SOURCE TARGET_TEMPLATE W_SMOOTH W_CONSERVE OUTPUT'
    error stop 2
  end if

  call get_command_argument(1,srcfile)
  call get_command_argument(2,tplfile)
  call get_command_argument(3,wsfile)
  call get_command_argument(4,wcfile)
  call get_command_argument(5,outfile)

  call say('============================================================')
  call say('Direct MPAS -> MPAS remapper V3-RESTART')
  call say('source          : '//trim(srcfile))
  call say('target template : '//trim(tplfile))
  call say('smooth weights  : '//trim(wsfile))
  call say('conserve weights: '//trim(wcfile))
  call say('output          : '//trim(outfile))
  call say('============================================================')

  cmd='cp -p "'//trim(tplfile)//'" "'//trim(outfile)//'"'
  call execute_command_line(trim(cmd),wait=.true.)

  call ncok(nf90_open(trim(srcfile),nf90_nowrite,ncs),'open source')
  call ncok(nf90_open(trim(outfile),nf90_write,nct),'open output')
  call ensure_reconstructed_winds(nct)

  nsrc=dlen(ncs,'nCells'); ndst=dlen(nct,'nCells')
  nlevs=dlen(ncs,'nVertLevels'); nlevt=dlen(nct,'nVertLevels')
  nintf_s=dlen(ncs,'nVertLevelsP1'); nintf_t=dlen(nct,'nVertLevelsP1')
  nedges=dlen(nct,'nEdges')

  if(nlevs /= nlevt) call fatal('V3 requires identical nVertLevels')
  if(nintf_s /= nintf_t) call fatal('V3 requires identical nVertLevelsP1')

  call read_esmf_weights(trim(wsfile),Ws,nsrc,ndst)
  call read_esmf_weights(trim(wcfile),Wc,nsrc,ndst)

  qname=(/'qv      ','qc      ','qr      ','qi      ','qs      ','qg      '/)

  ! Time-dependent physics / land / surface state that should follow the
  ! 12-km valid-time state rather than remain from the target template.
  !
  ! Static categorical/geometry fields such as landmask, ivgtyp, isltyp,
  ! xland, dzs, mesh connectivity, zgrid, etc. deliberately remain from
  ! the destination template.
  remap_state=(/ &
    'relhum                          ', &
    'sfc_albbck                      ', &
    'skintemp                        ', &
    'snow                            ', &
    'snowc                           ', &
    'snowh                           ', &
    'sst                             ', &
    'tmn                             ', &
    'vegfra                          ', &
    'seaice                          ', &
    'xice                            ', &
    'u10                             ', &
    'v10                             ', &
    'q2                              ', &
    't2m                             ', &
    'th2m                            ', &
    'precipw                         ', &
    'sh2o                            ', &
    'smois                           ', &
    'tslb                            ', &
    'smcrel                          ', &
    'canwat                          ', &
    'sfc_albedo                      ', &
    'sfc_emiss                       ', &
    'sfc_emibck                      ', &
    'sstsk                           ', &
    'sstsk_dtc                       ', &
    'sstsk_dtw                       ', &
    'z0                              ', &
    'tyear_mean                      ', &
    'tlag                            ', &
    'o3vmr                           ', &
    're_cloud                        ', &
    're_ice                          ', &
    're_snow                         ', &
    'ust                             ', &
    'ustm                            ', &
    'zol                             ', &
    'znt                             ', &
    'hfx                             ', &
    'qfx                             ', &
    'lh                              ', &
    'hpbl                            ', &
    'wstar                           ', &
    't_oml                           ', &
    't_oml_initial                   ', &
    't_oml_200m_initial              ', &
    'h_oml                           ', &
    'h_oml_initial                   ', &
    'hu_oml                          ', &
    'hv_oml                          ', &
    'grdflx                          ' /)

  ! Forecast accumulators and transient/tendency memory must not retain the
  ! unrelated target-template valid time.  They are restarted from zero.
  reset_state=(/ &
    'tend_sfc_pressure               ', &
    'rt_diabatic_tend                ', &
    'nsteps_accum                    ', &
    'ndays_accum                     ', &
    'tday_accum                      ', &
    'tyear_accum                     ', &
    'refl10cm_max                    ', &
    'i_rainnc                        ', &
    'rainncv                         ', &
    'rainnc                          ', &
    'snowncv                         ', &
    'snownc                          ', &
    'graupelncv                      ', &
    'graupelnc                       ', &
    'sr                              ', &
    'i_rainc                         ', &
    'cuprec                          ', &
    'rainc                           ', &
    'raincv                          ', &
    'dtaux3d                         ', &
    'dtauy3d                         ', &
    'rubldiff                        ', &
    'rvbldiff                        ', &
    'rthcuten                        ', &
    'rqvcuten                        ', &
    'rqccuten                        ', &
    'rqicuten                        ', &
    'rqvdynten                       ', &
    'rthdynten                       ', &
    'rucuten                         ', &
    'rvcuten                         ', &
    'rublten                         ', &
    'rvblten                         ', &
    'rthblten                        ' /)

  allocate(lat(ndst),lon(ndst),enorm(3,nedges),coe(2,nedges))
  call read_target_geometry(nct,ndst,nedges,lat,lon,coe,enorm)
  call copy_time_metadata(ncs,nct)

  allocate(rhos(nsrc,nlevs),rhot(ndst,nlevt),theta_t(ndst,nlevt),qv_t(ndst,nlevt))
  allocate(src3(nsrc,nlevs),dst3(ndst,nlevt))
  allocate(ue(ndst,nlevt),vn(ndst,nlevt),uedge(nedges,nlevt),ruedge(nedges,nlevt))
  allocate(zz(ndst,nlevt),rho_base(ndst,nlevt),theta_base(ndst,nlevt))
  allocate(rho_zz(ndst,nlevt),theta_m(ndst,nlevt),rho_p(ndst,nlevt))
  allocate(rtheta_base(ndst,nlevt),rtheta_p(ndst,nlevt),exner(ndst,nlevt),exner_base(ndst,nlevt))
  allocate(pressure_p(ndst,nlevt),pressure_base(ndst,nlevt))

  call say('Reading rho')
  call read_cell_3d(ncs,'rho',nsrc,nlevs,rhos)
  call say('Conservative remap: rho across all levels')
  call apply_conserve_3d(Wc,rhos,rhot)
  !$omp parallel workshare
  rhot=max(rhot,1.0e-12_dp)
  !$omp end parallel workshare
  call write_cell_3d(nct,'rho',ndst,nlevt,rhot)

  call say('Reading theta')
  call read_cell_3d(ncs,'theta',nsrc,nlevs,src3)
  call say('Conservative rho-weighted remap: theta across all levels')
  call rho_weighted_3d(Wc,rhos,src3,rhot,theta_t)
  call write_cell_3d(nct,'theta',ndst,nlevt,theta_t)

  qv_t=0.0_dp
  do iq=1,size(qname)
    call say('Processing '//trim(qname(iq)))
    if(has_var(ncs,trim(qname(iq)))) then
      call read_cell_3d(ncs,trim(qname(iq)),nsrc,nlevs,src3)
      call positive_3d(src3)
      call rho_weighted_3d(Wc,rhos,src3,rhot,dst3)
      call positive_3d(dst3)
    else
      call say('  source missing '//trim(qname(iq))//'; setting target to zero')
      dst3=0.0_dp
    end if
    if(trim(qname(iq)) == 'qv') qv_t=dst3
    call write_cell_3d(nct,trim(qname(iq)),ndst,nlevt,dst3)
  end do

  call say('Reading target base/reference thermodynamics')
  call read_cell_3d(nct,'zz',ndst,nlevt,zz)
  call read_cell_3d(nct,'rho_base',ndst,nlevt,rho_base)
  call read_cell_3d(nct,'theta_base',ndst,nlevt,theta_base)

  call say('Rebuilding dependent thermodynamics across all levels')
  call rebuild_thermo_3d(rhot,theta_t,qv_t,zz,rho_base,theta_base, &
    rho_zz,theta_m,rho_p,rtheta_base,rtheta_p,exner,exner_base,pressure_p,pressure_base)

  call write_cell_3d(nct,'rho_zz',ndst,nlevt,rho_zz)
  call write_cell_3d(nct,'theta_m',ndst,nlevt,theta_m)
  call write_cell_3d(nct,'rho_p',ndst,nlevt,rho_p)
  call write_cell_3d(nct,'rtheta_base',ndst,nlevt,rtheta_base)
  call write_cell_3d(nct,'rtheta_p',ndst,nlevt,rtheta_p)
  call write_cell_3d(nct,'exner',ndst,nlevt,exner)
  call write_cell_3d(nct,'exner_base',ndst,nlevt,exner_base)
  call write_cell_3d(nct,'pressure_p',ndst,nlevt,pressure_p)
  call write_cell_3d(nct,'pressure_base',ndst,nlevt,pressure_base)

  call say('Reading/remapping uReconstructZonal across all levels')
  call read_cell_3d(ncs,'uReconstructZonal',nsrc,nlevs,src3)
  call apply_smooth_3d(Ws,src3,ue)
  call write_cell_3d(nct,'uReconstructZonal',ndst,nlevt,ue)

  call say('Reading/remapping uReconstructMeridional across all levels')
  call read_cell_3d(ncs,'uReconstructMeridional',nsrc,nlevs,src3)
  call apply_smooth_3d(Ws,src3,vn)
  call write_cell_3d(nct,'uReconstructMeridional',ndst,nlevt,vn)

  call say('Reconstructing native target edge-normal u across all levels')
  call reconstruct_edge_u_3d(lat,lon,coe,enorm,ue,vn,uedge)
  call write_edge_3d(nct,'u',nedges,nlevt,uedge)

  if(has_var(nct,'ru')) then
    call say('Rebuilding ru across all levels')
    call compute_ru_3d(coe,uedge,rho_zz,ruedge)
    call write_edge_3d(nct,'ru',nedges,nlevt,ruedge)
  end if

  if(has_var(ncs,'w') .and. has_var(nct,'w')) then
    allocate(wsrc(nsrc,nintf_s),wdst(ndst,nintf_t))
    call say('Reading/remapping w across all interface levels')
    call read_interface_3d(ncs,'w',nsrc,nintf_s,wsrc)
    call apply_smooth_3d(Ws,wsrc,wdst)
    call write_interface_3d(nct,'w',ndst,nintf_t,wdst)
    deallocate(wsrc,wdst)
  end if

  allocate(surf_src(nsrc),surf_dst(ndst))
  call say('Reading/remapping surface_pressure')
  call read_surface_2d(ncs,'surface_pressure',nsrc,surf_src)
  call apply_smooth_2d(Ws,surf_src,surf_dst)
  call write_surface_2d(nct,'surface_pressure',ndst,surf_dst)
  deallocate(surf_src,surf_dst)

  !-------------------------------------------------------------------------
  ! LAND / SURFACE / PHYSICS STATE
  !-------------------------------------------------------------------------
  call say('Remapping time-dependent land/surface/physics state')

  do jf=1,size(remap_state)
    call remap_cell_field_smooth( &
      ncs,nct,trim(remap_state(jf)),Ws,nsrc,ndst)
  end do

  !-------------------------------------------------------------------------
  ! RESET STALE FORECAST ACCUMULATORS / TRANSIENT TENDENCIES
  !-------------------------------------------------------------------------
  call say('Resetting forecast accumulators and transient tendencies')

  do jf=1,size(reset_state)
    call zero_cell_field(nct,trim(reset_state(jf)),ndst)
  end do

  ! IMPORTANT:
  ! ru_p, rw, rw_p, circulation and other coupled dycore quantities are
  ! deliberately not manufactured here.  The first MPAS restart from this
  ! converted state MUST use config_do_DAcycling=.true.; MPAS then executes
  ! its native atm_init_coupled_diagnostics path and rebuilds the coupled
  ! state before dynamics.

  call ncok(nf90_close(ncs),'close source')
  call ncok(nf90_close(nct),'close output')

  call say('============================================================')
  call say('SUCCESS: '//trim(outfile))
  call say('FIRST MPAS RUN REQUIREMENT:')
  call say('  config_do_restart   = true')
  call say('  config_do_DAcycling = true')
  call say('After MPAS writes its first native restart, normal restart cycling may resume.')
  call say('============================================================')
end program mpas_remap_state_v3_restart
