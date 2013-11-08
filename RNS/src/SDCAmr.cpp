/*
 * Multilevel SDC + AMR controller.
 */

#include <SDCAmr.H>
#include <MultiFab.H>
#include <ParmParse.H>
#include <StateDescriptor.H>
#include <AmrLevel.H>
#include <Interpolater.H>
#include <FabArray.H>

#include "RNS.H"
#include "RNS_F.H"

#ifdef BL_USE_ARRAYVIEW
#include <ArrayView.H>
#endif

using namespace std;

BEGIN_EXTERN_C

/*
 * Spatial interpolation between MultiFabs.
 */
void mlsdc_amr_interpolate(void *F, void *G, sdc_state *state, void *ctxF, void *ctxG)
{
  MultiFab& UF      = *((MultiFab*) F);
  MultiFab& UG      = *((MultiFab*) G);
  RNS&      levelF  = *((RNS*) ctxF);
  RNS&      levelG  = *((RNS*) ctxG);

  const IntVect         ratio = levelG.fineRatio();
  const DescriptorList& dl    = levelF.get_desc_lst();
  const Array<BCRec>&   bcs   = dl[0].getBCs();
  const int             ncomp = dl[0].nComp();
  Interpolater&         map   = *dl[0].interp();

  Array<BCRec>          bcr(ncomp);

  // make a coarse version (UC) of the fine multifab (UF)
  BoxArray crseba(UF.size());
  for (int i=0; i<crseba.size(); i++)
    crseba.set(i, map.CoarseBox(UF.fabbox(i), ratio));
  MultiFab UC(crseba, ncomp, 0);

#ifndef NDEBUG
  UC.setVal(NAN);
  UF.setVal(NAN,UF.nGrow());
#endif

  UC.copy(UG);
  levelG.fill_boundary(UC, state->t, RNS::set_PhysBoundary);

  BL_ASSERT(UC.contains_nan() == false);

  // now that UF is completely contained within UC, cycle through each
  // FAB in UF and interpolate from the corresponding FAB in UC
// #ifdef _OPENMP
// #pragma omp parallel for
// #endif
  for (MFIter mfi(UF); mfi.isValid(); ++mfi) {
    BoxLib::setBC(UF[mfi].box(), levelF.Domain(), 0, 0, ncomp, bcs, bcr);
    Geometry fine_geom(UF[mfi].box());
    Geometry crse_geom(UC[mfi].box());

    map.interp(UC[mfi], 0, UF[mfi], 0, ncomp, UF[mfi].box(), ratio,
               crse_geom, fine_geom, bcr, 0, 0);
  }

  levelF.fill_boundary(UF, state->t, RNS::set_PhysBoundary);

  BL_ASSERT(UF.contains_nan() == false);
}


/*
 * Spatial restriction between MultiFabs.
 */
void mlsdc_amr_restrict(void *F, void *G, sdc_state *state, void *ctxF, void *ctxG)
{
  MultiFab& UF      = *((MultiFab*) F);
  MultiFab& UG      = *((MultiFab*) G);
  RNS&      levelF  = *((RNS*) ctxF);
  RNS&      levelG  = *((RNS*) ctxG);

  if (state->kind == SDC_SOLUTION)
    levelF.fill_boundary(UF, state->t, RNS::use_FillBoundary);

  levelG.avgDown(UG, UF);

  if (state->kind == SDC_SOLUTION)
    levelG.fill_boundary(UG, state->t, RNS::use_FillBoundary);
}

END_EXTERN_C


void SDCAmr::timeStep (int  level,
		       Real time,
		       int  iteration,
		       int  niter,
		       Real stop_time)
{
  BL_ASSERT(level == 0);

  if (sweepers[0] == NULL) rebuild_mlsdc();
  int lev_top = std::min(finest_level, max_level-1);

  // regrid
  for (int i=level; i<=lev_top; i++) {
    const int old_finest = finest_level;
    if (okToRegrid(i)) {
      regrid(i,time);
      amr_level[0].computeNewDt(finest_level, sub_cycle, n_cycle, ref_ratio,
                                dt_min, dt_level, stop_time, 1);
      for (int k=i; k<=finest_level; k++)
	level_count[k] = 0;
    }
    if (old_finest > finest_level)
      lev_top = std::min(finest_level, max_level-1);
  }

  // set intial conditions
  for (int lev=0; lev<=finest_level; lev++) {
    AmrLevel& amrlevel = getLevel(lev);
    const DescriptorList& dl = amrlevel.get_desc_lst();
    for (int st=0; st<dl.size(); st++) {
      MultiFab& Unew = amrlevel.get_new_data(st);
      RNS *rns = dynamic_cast<RNS*>(&amrlevel);
      int fill_boundary_type = (lev == 0) ? RNS::use_FillBoundary : RNS::use_FillCoarsePatch;
      rns->fill_boundary(Unew, time, fill_boundary_type);
      MultiFab& U0   = *((MultiFab*) mg.sweepers[lev]->nset->Q[0]);
#ifndef NDEBUG
      U0.setVal(NAN, U0.nGrow());
#endif
      MultiFab::Copy(U0, Unew, 0, 0, U0.nComp(), U0.nGrow());
      BL_ASSERT(U0.contains_nan() == false);
    }
  }

  // spread and iterate (XXX: spread from qend if step>0)
  if (verbose > 0 && ParallelDescriptor::IOProcessor()) {
    cout << "MLSDC advancing with dt: " << dt_level[0] << endl;
  }

  // set times
  for (int lev=0; lev<=finest_level; lev++) {
    AmrLevel& amrlevel = getLevel(lev);
    const DescriptorList& dl = amrlevel.get_desc_lst();
    for (int st=0; st<dl.size(); st++) {
      amrlevel.get_state_data(st).setTimeLevel(time+dt_level[0], dt_level[0], dt_level[0]);
    }
  }


  sdc_mg_spread(&mg, time, dtLevel(0), 0);
  for (int k=0; k<max_iters; k++) {
    sdc_mg_sweep(&mg, time, dt_level[0], (k==max_iters-1) ? SDC_MG_LAST_SWEEP : 0);

    // echo residuals
    if (verbose > 0) {
      for (int lev=0; lev<=finest_level; lev++) {
        int       nnodes = mg.sweepers[lev]->nset->nnodes;
        MultiFab& R      = *((MultiFab*) mg.sweepers[lev]->nset->R[nnodes-2]);
	double    r0     = R.norm0();
	double    r2     = R.norm2();

	if (ParallelDescriptor::IOProcessor()) {
	  cout << "MLSDC iter: " << k << ", level: " << lev
	       << ", res norm0: " << r0 << ", res norm2: " << r2 << endl;
	}
      }
    }
  }

  // copy final solution from SDCLib to 'new data'
  for (int lev=0; lev<=finest_level; lev++) {
    AmrLevel& amrlevel = getLevel(lev);
    const DescriptorList& dl = amrlevel.get_desc_lst();
    for (int st=0; st<dl.size(); st++) {
      int nnodes = mg.sweepers[lev]->nset->nnodes;
      MultiFab& Unew = amrlevel.get_new_data(st);
      MultiFab& Uend = *((MultiFab*)mg.sweepers[lev]->nset->Q[nnodes-1]);
      MultiFab::Copy(Unew, Uend, 0, 0, Uend.nComp(), Uend.nGrow());
    }
  }

  level_steps[level]++;
  level_count[level]++;

  if (verbose > 0 && ParallelDescriptor::IOProcessor()){
    std::cout << "Advanced "
              << amr_level[level].countCells()
              << " cells at level "
              << level
              << std::endl;
  }
}

sdc_sweeper* rns_sdc_build_level(int lev)
{
  int nnodes0 = 3;
  int trat    = 2;
  int nnodes  = 1 + (nnodes0 - 1) * ((int) pow(trat, lev));

  sdc_nodes* nodes = sdc_nodes_create(nnodes, SDC_GAUSS_LOBATTO);
  sdc_imex*  imex  = sdc_imex_create(nodes, sdc_f1eval, sdc_f2eval, sdc_f2comp);

  sdc_nodes_destroy(nodes);
  sdc_imex_setup(imex, NULL, NULL);
  sdc_hooks_add(imex->hooks, SDC_HOOK_POST_STEP, sdc_poststep_hook);

  return (sdc_sweeper*) imex;
}

void SDCAmr::rebuild_mlsdc()
{
  // reset previous and clear sweepers etc
  sdc_mg_reset(&mg);
  for (unsigned int lev=0; lev<=max_level; lev++) {
    if (sweepers[lev] != NULL) {
      sweepers[lev]->destroy(sweepers[lev]);
      delete (mf_encap*) encaps[lev]->ctx;
      delete encaps[lev];
      sweepers[lev] = NULL;
    }
  }

  // rebuild
  for (int lev=0; lev<=finest_level; lev++) {
    encaps[lev] = build_encap(lev);
    sweepers[lev] = rns_sdc_build_level(lev);
    sweepers[lev]->nset->ctx   = &getLevel(lev);
    sweepers[lev]->nset->encap = encaps[lev];
    sdc_mg_add_level(&mg, sweepers[lev], mlsdc_amr_interpolate, mlsdc_amr_restrict);
  }
  sdc_mg_setup(&mg);
  sdc_mg_allocate(&mg);

  if (verbose > 0 && ParallelDescriptor::IOProcessor())
    std::cout << "Rebuilt MLSDC: " << mg.nlevels << std::endl;
}

void SDCAmr::regrid (int  lbase,
		     Real time,
		     bool initial)
{
  Amr::regrid(lbase, time, initial);
  rebuild_mlsdc();
}

SDCAmr::SDCAmr ()
{
  ParmParse ppsdc("mlsdc");
  if (!ppsdc.query("max_iters", max_iters)) max_iters = 22;
  if (!ppsdc.query("max_trefs", max_trefs)) max_trefs = 3;

  // sdc_log_set_stdout(SDC_LOG_DEBUG);
  sdc_mg_build(&mg, max_level+1);
  sdc_hooks_add(mg.hooks, SDC_HOOK_POST_TRANS, sdc_poststep_hook);

  sweepers.resize(max_level+1);
  encaps.resize(max_level+1);

  for (unsigned int i=0; i<=max_level; i++)
    sweepers[i] = NULL;

  if (max_level > 0) {
      for (int i=0; i<=max_level; i++) {
	  if (blockingFactor(i) < 4) {
	      BoxLib::Abort("For AMR runs, set blocking_factor to at least 4.");
	  }
      }
  }
}


SDCAmr::~SDCAmr()
{
  sdc_mg_destroy(&mg);
}
