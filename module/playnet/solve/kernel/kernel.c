/* kernel.c — the compiled hot loops of planner.scm's native interior-point
 * Newton-PCG backend (§2). The Newton outer loop, central-path schedule, and
 * line search stay in Scheme (cheap, O(iterations), where the policy lives);
 * the O(nnz)-per-iteration flops live here.
 *
 * Same math as §2, byte-for-byte:
 *   slack/value  s_i(x) = const_i + Σ_k val[k]·x[idx[k]]      (term_values)
 *   curvature    cv_i  = des: (s<D) 2w/D²        bar: (s>0) t/s²   (term_coeffs)
 *   gradient     des: (s<D) −2w(D−s)/D² · a_i    bar: (s>0) −t/s · a_i (csr_grad)
 *   Hessian      H = ridge·I + Σ_i cv_i·a_i a_iᵀ  (never formed; matrix-free)
 *   solve        H d = b  by diagonally-preconditioned CG  (pcg_solve)
 *
 * CSR layout (caller-owned, raw buffers, no copies):
 *   ptr[nt+1] int32   idx[nnz] int32   val[nnz] f64
 *   kind[nt]  int32 (0=bar 1=des)   cnst/D/w[nt] f64
 *
 * build:  gcc -O3 -march=native -ffast-math -fPIC -shared kernel.c -o libplanner_kernel.so
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _OPENMP
#include <omp.h>
#endif

/* WHICH CPU THIS BUILD REQUIRES, readable without running any of it.
 *
 * The build is -march=native, so the object is tuned to the machine that
 * compiled it. Loading it elsewhere is fine — dlopen resolves symbols and
 * executes nothing — but the first call into a hot loop compiled for a wider
 * ISA than the running CPU dies on an illegal instruction: SIGILL, no message,
 * no backtrace through the FFI, and nothing naming the actual cause.
 *
 * This is DATA, not code, so reading it is always safe on any CPU. The
 * preprocessor knows exactly which extensions -march enabled, and the names
 * below are spelled as Linux spells them in /proc/cpuinfo, so the loader can
 * compare the two directly. A build that needs nothing special yields the
 * empty string and passes everywhere.
 */
/* ONE OBJECT THAT FITS EVERY CPU IT MIGHT MEET.
 *
 * The alternative to detecting a mismatch is not having one. GCC's
 * target_clones compiles the annotated function once per listed ISA and emits
 * an IFUNC resolver that picks, at load time, the best version the RUNNING cpu
 * supports. So the object is built for no machine in particular and still
 * executes AVX-512 on a machine that has it — portability and the wide
 * registers, rather than a choice between them.
 *
 * Only the leaf numeric loops are cloned. They are where vectorisation pays
 * (the O(nnz)-per-iteration flops this file exists for), they contain no
 * OpenMP, and cloning the whole file would multiply compile time and code size
 * for the bookkeeping around them, which does not vectorise anyway.
 *
 * PK_NO_MULTIVERSION falls back to plain functions, and the `native` build
 * still exists for a machine that wants everything -march=native can give it.
 */
/* CLONE BY ARCHITECTURE LEVEL, NOT BY EXTENSION. The first version of this
 * listed bare features — target_clones("avx512f","avx2","default") — and cost
 * ~11% against -march=native. The reason is that a bare feature name enables
 * exactly that one extension: an "avx2" clone gets AVX2 and none of the rest of
 * what -march=native would have turned on, and no -mtune at all.
 *
 * The psABI architecture LEVELS are the whole set at once, and GCC takes them
 * here as `arch=`:
 *
 *     x86-64-v2   SSE4.2, POPCNT          (~2009, Nehalem)
 *     x86-64-v3   AVX2, FMA, BMI1/2       (~2013, Haswell / Zen 1)
 *     x86-64-v4   AVX-512F/BW/DQ/VL       (~2017, Skylake-X / Zen 4)
 *
 * so each clone is compiled as though -march named that level, and the resolver
 * still picks by what the running cpu reports. `default` stays last and keeps
 * the object correct on anything older than 2009.
 */
#if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__) \
    && !defined(PK_NO_MULTIVERSION)
#define PK_HOT __attribute__((target_clones("arch=x86-64-v4","arch=x86-64-v3", \
                                            "arch=x86-64-v2","default")))
#else
#define PK_HOT
#endif

const char pk_required_isa[] =
#ifdef __AVX512F__
  "avx512f "
#endif
#ifdef __AVX512DQ__
  "avx512dq "
#endif
#ifdef __AVX512BW__
  "avx512bw "
#endif
#ifdef __AVX512VL__
  "avx512vl "
#endif
#ifdef __AVX2__
  "avx2 "
#endif
#ifdef __FMA__
  "fma "
#endif
#ifdef __AVX__
  "avx "
#endif
#ifdef __BMI2__
  "bmi2 "
#endif
#ifdef __SSE4_2__
  "sse4_2 "
#endif
  "";
#include "kernel_kinds.h"   /* GENERATED per-kind φ / φ′ / φ″ — see gen-kernels.scm */

PK_HOT double pk_dot(int n, const double *a, const double *b) {
  double s = 0.0; for (int i = 0; i < n; i++) s += a[i] * b[i]; return s;
}
/* y = x + a·d  (line-search trial point / accepted step) */
PK_HOT void pk_axpy(int n, const double *x, double a, const double *d, double *y) {
  for (int i = 0; i < n; i++) y[i] = x[i] + a * d[i];
}

/* s_i(x) for every form */
PK_HOT void pk_term_values(int nt, const int *ptr, const int *idx, const double *val,
                    const double *cnst, const double *x, double *sv) {
  for (int ti = 0; ti < nt; ti++) {
    double s = cnst[ti];
    const int hi = ptr[ti + 1];
    for (int k = ptr[ti]; k < hi; k++) s += val[k] * x[idx[k]];
    sv[ti] = s;
  }
}

/* rank-1 curvature weight per form at barrier param t */
PK_HOT void pk_term_coeffs(int nt, const int *kind, const double *D, const double *w,
                    double t, const double *sv, double *cv) {
  for (int ti = 0; ti < nt; ti++)
    cv[ti] = pk_kind_curv(kind[ti], sv[ti], t, D[ti], w[ti]);
}

/* gradient of the chain objective (kappa·lab term added in Scheme). g zeroed here. */
PK_HOT void pk_csr_grad(int nt, int n, const int *ptr, const int *idx, const double *val,
                 const int *kind, const double *D, const double *w,
                 double t, const double *sv, double *g) {
  for (int i = 0; i < n; i++) g[i] = 0.0;
  for (int ti = 0; ti < nt; ti++) {
    double gc = pk_kind_grad(kind[ti], sv[ti], t, D[ti], w[ti]);   /* sign folded in */
    if (gc != 0.0) {
      const int lo = ptr[ti], hi = ptr[ti + 1];
      for (int k = lo; k < hi; k++) g[idx[k]] += gc * val[k];
    }
  }
}

/* diag(H) for Jacobi preconditioning */
PK_HOT void pk_csr_diag(int nt, int n, const int *ptr, const int *idx, const double *val,
                 const double *cv, double ridge, double *d) {
  for (int i = 0; i < n; i++) d[i] = ridge;
  for (int ti = 0; ti < nt; ti++) {
    double c = cv[ti];
    if (c == 0.0) continue;
    const int hi = ptr[ti + 1];
    for (int k = ptr[ti]; k < hi; k++) { double vk = val[k]; d[idx[k]] += c * vk * vk; }
  }
}

/* chain part of the objective (kappa·lab·x added in Scheme) */
PK_HOT double pk_obj_value(int nt, const int *kind, const double *D, const double *w,
                    double t, const double *sv) {
  double acc = 0.0;
  for (int ti = 0; ti < nt; ti++)
    acc += pk_kind_value(kind[ti], sv[ti], t, D[ti], w[ti]);
  return acc;
}

/* H·v, matrix-free: r = ridge·v + Σ_i cv_i·a_i (a_iᵀv) */
static void hv(int nt, int n, const int *ptr, const int *idx, const double *val,
               const double *cv, const double *v, double ridge, double *r) {
  for (int i = 0; i < n; i++) r[i] = ridge * v[i];
  for (int ti = 0; ti < nt; ti++) {
    double c = cv[ti];
    if (c == 0.0) continue;
    const int lo = ptr[ti], hi = ptr[ti + 1];
    double dot = 0.0;
    for (int k = lo; k < hi; k++) dot += val[k] * v[idx[k]];
    double cd = c * dot;
    for (int k = lo; k < hi; k++) r[idx[k]] += cd * val[k];
  }
}

/* ───────────────────────────────────────────────────────────────────────────
 * IC(0)-preconditioned CG.  The Jacobi (diagonal) preconditioner is blind to how
 * activities couple through shared scarce forms (the production chain), so CG
 * saturates the iteration cap on ill-conditioned problems. Here we assemble the
 * normal-equations Hessian H = ridge·I + Σ_k cv_k a_k a_kᵀ as a sparse lower-
 * triangular matrix, compute an incomplete Cholesky with ZERO fill (L has H's
 * pattern), and precondition with M = LLᵀ. H·v itself stays matrix-free; L only
 * preconditions. CG then converges in tens, not hundreds, of iterations.
 * ─────────────────────────────────────────────────────────────────────────── */
static int cmp_int(const void *a, const void *b) {
  int x = *(const int*)a, y = *(const int*)b; return (x > y) - (x < y);
}
/* binary-search row s in column r's sorted row slice; -1 if absent */
static inline int find_row(const int *colptr, const int *rowidx, int r, int s) {
  int lo = colptr[r], hi = colptr[r + 1] - 1;
  while (lo <= hi) { int m = (lo + hi) >> 1, v = rowidx[m];
    if (v == s) return m; if (v < s) lo = m + 1; else hi = m - 1; }
  return -1;
}
/* opaque IC(0) preconditioner: symbolic pattern (fixed across Newton steps) +
 * numeric L. Build symbolic once per solve, refactor numerically each step. */
typedef struct { int n, nzL; int *colptr, *rowidx; double *L; } ic0_t;

/* symbolic: lower-triangular pattern of H = Σ_k a_k a_kᵀ (+ all diagonals) */
PK_HOT ic0_t *pk_ic0_symbolic(int nt, int n, const int *ptr, const int *idx) {
  long np = n;                                  /* explicit diagonals */
  for (int ti = 0; ti < nt; ti++) { long m = ptr[ti + 1] - ptr[ti]; np += m * (m + 1) / 2; }
  int *Pi = malloc(np * sizeof(int)), *Pj = malloc(np * sizeof(int));
  long t = 0;
  for (int i = 0; i < n; i++) { Pi[t] = i; Pj[t] = i; t++; }
  for (int ti = 0; ti < nt; ti++) {
    int lo = ptr[ti], hi = ptr[ti + 1];
    for (int x = lo; x < hi; x++) for (int y = lo; y <= x; y++) {
      int a = idx[x], b = idx[y], i = a > b ? a : b, j = a > b ? b : a;
      Pi[t] = i; Pj[t] = j; t++;
    }
  }
  /* bucket by column, sort+dedup each column → CSC lower */
  int *colcnt = calloc(n + 1, sizeof(int));
  for (long k = 0; k < np; k++) colcnt[Pj[k]]++;
  int *cstart = malloc((n + 1) * sizeof(int)); cstart[0] = 0;
  for (int j = 0; j < n; j++) cstart[j + 1] = cstart[j] + colcnt[j];
  int *tmp = malloc(np * sizeof(int)); int *pos = malloc(n * sizeof(int));
  memcpy(pos, cstart, n * sizeof(int));
  for (long k = 0; k < np; k++) tmp[pos[Pj[k]]++] = Pi[k];
  free(Pi); free(Pj); free(colcnt);
  ic0_t *S = malloc(sizeof(ic0_t)); S->n = n;
  S->colptr = malloc((n + 1) * sizeof(int));
  int *rowidx = malloc(np * sizeof(int)); int w = 0; S->colptr[0] = 0;
  for (int j = 0; j < n; j++) {
    int a = cstart[j], b = cstart[j + 1];
    qsort(tmp + a, b - a, sizeof(int), cmp_int);
    int last = -1;
    for (int k = a; k < b; k++) if (tmp[k] != last) { rowidx[w++] = tmp[k]; last = tmp[k]; }
    S->colptr[j + 1] = w;
  }
  free(tmp); free(pos); free(cstart);
  S->nzL = w; S->rowidx = realloc(rowidx, w * sizeof(int));
  S->L = malloc(w * sizeof(double));
  return S;
}
void pk_ic0_free(ic0_t *S) { if (!S) return; free(S->colptr); free(S->rowidx); free(S->L); free(S); }

/* numeric: assemble H = ridge·I + Σ cv·a aᵀ (lower), then in-place incomplete
 * Cholesky with a LOCAL pivot floor τ = ε·max(diag). The move columns (a = −1
 * here, +1 there) give H negative off-diagonals, so a pivot can drop to ~0; the
 * old 1e-15 floor then blew L[i][j] = A[i][j]/√dj up and wrecked the factor
 * (poor directions ⇒ Newton stalled). Flooring at ε·maxdiag keeps L bounded and
 * the factor a good SPD preconditioner — yet leaves a well-conditioned problem
 * (pivots ≫ τ) completely untouched, so the scale case is unchanged. */
PK_HOT void pk_ic0_factor(ic0_t *S, int nt, const int *ptr, const int *idx, const double *val,
                   const double *cv, double ridge) {
  int n = S->n; const int *colptr = S->colptr, *rowidx = S->rowidx; double *A = S->L;
  memset(A, 0, S->nzL * sizeof(double));
  double maxdiag = ridge;
  for (int j = 0; j < n; j++) A[colptr[j]] = ridge;
  for (int ti = 0; ti < nt; ti++) {
    double c = cv[ti]; if (c == 0.0) continue;
    int lo = ptr[ti], hi = ptr[ti + 1];
    for (int x = lo; x < hi; x++) for (int y = lo; y <= x; y++) {
      int a = idx[x], b = idx[y], i = a > b ? a : b, jj = a > b ? b : a;
      A[find_row(colptr, rowidx, jj, i)] += c * val[x] * val[y];
    }
  }
  for (int j = 0; j < n; j++) if (A[colptr[j]] > maxdiag) maxdiag = A[colptr[j]];
  double tau = 1e-6 * maxdiag;
  for (int j = 0; j < n; j++) {                                  /* right-looking IC(0) */
    double dj = A[colptr[j]];
    if (dj < tau) dj = tau;                                       /* local pivot floor */
    double ljj = sqrt(dj); A[colptr[j]] = ljj;
    for (int p = colptr[j] + 1; p < colptr[j + 1]; p++) A[p] /= ljj;
    for (int p = colptr[j] + 1; p < colptr[j + 1]; p++) {
      int r = rowidx[p]; double Lrj = A[p];
      for (int q = p; q < colptr[j + 1]; q++) {
        int s = rowidx[q]; int t = find_row(colptr, rowidx, r, s);
        if (t >= 0) A[t] -= A[q] * Lrj;
      }
    }
  }
}
/* apply M⁻¹ = (LLᵀ)⁻¹ : forward L y = r, back Lᵀ z = y  (in place into z) */
static void ic0_apply(const ic0_t *S, const double *r, double *z) {
  int n = S->n; const int *colptr = S->colptr, *rowidx = S->rowidx; const double *L = S->L;
  for (int i = 0; i < n; i++) z[i] = r[i];
  for (int j = 0; j < n; j++) {                                  /* forward: L y = r */
    z[j] /= L[colptr[j]];
    for (int p = colptr[j] + 1; p < colptr[j + 1]; p++) z[rowidx[p]] -= L[p] * z[j];
  }
  for (int j = n - 1; j >= 0; j--) {                             /* back: Lᵀ z = y */
    double s = z[j];
    for (int p = colptr[j] + 1; p < colptr[j + 1]; p++) s -= L[p] * z[rowidx[p]];
    z[j] = s / L[colptr[j]];
  }
}
/* IC(0)-preconditioned CG. S already factored at the current cv. */
PK_HOT int pk_pcg_ic0(ic0_t *S, int nt, int n, const int *ptr, const int *idx, const double *val,
               const double *cv, const double *b, double ridge, int maxit,
               double *x, double *r, double *z, double *p, double *Hp) {
  for (int i = 0; i < n; i++) { x[i] = 0.0; r[i] = b[i]; }
  ic0_apply(S, r, z);
  for (int i = 0; i < n; i++) p[i] = z[i];
  double rz = 0.0; for (int i = 0; i < n; i++) rz += r[i] * z[i];
  int cap = n + 2; if (maxit < cap) cap = maxit;
  int its = 0;
  for (int k = 0; k < cap; k++) {
    double rr = 0.0; for (int i = 0; i < n; i++) rr += r[i] * r[i];
    if (rr < 1e-14) break;
    hv(nt, n, ptr, idx, val, cv, p, ridge, Hp);
    double pHp = 0.0; for (int i = 0; i < n; i++) pHp += p[i] * Hp[i];
    double al = rz / (pHp > 1e-30 ? pHp : 1e-30);
    its++;
    for (int i = 0; i < n; i++) { x[i] += al * p[i]; r[i] -= al * Hp[i]; }
    ic0_apply(S, r, z);
    double rz2 = 0.0; for (int i = 0; i < n; i++) rz2 += r[i] * z[i];
    double beta = rz2 / rz;
    for (int i = 0; i < n; i++) p[i] = z[i] + beta * p[i];
    rz = rz2;
  }
  return its;
}

/* ───────────────────────────────────────────────────────────────────────────
 * IC(0) + low-rank (Sherman–Morrison–Woodbury) for DENSE-ROW problems.
 * A sector-rich input-output economy has HUB commodities: a basic good consumed
 * by ~200 sectors, or a per-cell labour cap, is one dense constraint row → its
 * rank-1 Hessian term a·aᵀ is a dense block that wrecks IC(0) (which drops the
 * fill those hubs need ⇒ CG saturates). Split H = H_sparse + U C Uᵀ, where U is
 * the few DENSE rows (nnz > thr) and C = diag(cv). Build IC(0) of H_sparse only
 * (well-conditioned) and correct EXACTLY for the dense part:
 *     M⁻¹ = P⁻¹ − W S⁻¹ Wᵀ,   W = P⁻¹U,   S = C⁻¹ + UᵀW   (k×k, k = #dense rows).
 * S is the Hessian of the dual in the hub multipliers — i.e. this IS "price the
 * hub commodities, everyone else decouples". H·v stays matrix-free over ALL terms.
 * ─────────────────────────────────────────────────────────────────────────── */
typedef struct { ic0_t *P; int n, k; int *dt; double *W; double *Sf; double *tk; } ic0w_t;

PK_HOT ic0w_t *pk_ic0w_symbolic(int nt, int n, const int *ptr, const int *idx, int thr) {
  ic0w_t *S = malloc(sizeof(ic0w_t)); S->n = n;
  int k = 0; for (int ti = 0; ti < nt; ti++) if (ptr[ti+1]-ptr[ti] > thr) k++;
  S->k = k; S->dt = malloc((k>0?k:1) * sizeof(int));
  long np = n;                                            /* sparse-only IC(0) pattern */
  for (int ti = 0; ti < nt; ti++) { long m = ptr[ti+1]-ptr[ti]; if (m <= thr) np += m*(m+1)/2; }
  int *Pi = malloc(np*sizeof(int)), *Pj = malloc(np*sizeof(int)); long t = 0;
  for (int i = 0; i < n; i++) { Pi[t]=i; Pj[t]=i; t++; }
  int jd = 0;
  for (int ti = 0; ti < nt; ti++) { int lo = ptr[ti], hi = ptr[ti+1];
    if (hi-lo > thr) { S->dt[jd++] = ti; continue; }
    for (int x=lo;x<hi;x++) for (int y=lo;y<=x;y++){ int a=idx[x],b=idx[y],i=a>b?a:b,j=a>b?b:a; Pi[t]=i;Pj[t]=j;t++; } }
  int *colcnt=calloc(n+1,sizeof(int)); for(long q=0;q<np;q++)colcnt[Pj[q]]++;
  int *cstart=malloc((n+1)*sizeof(int)); cstart[0]=0; for(int j=0;j<n;j++)cstart[j+1]=cstart[j]+colcnt[j];
  int *tmp=malloc(np*sizeof(int)),*pos=malloc(n*sizeof(int)); memcpy(pos,cstart,n*sizeof(int));
  for(long q=0;q<np;q++)tmp[pos[Pj[q]]++]=Pi[q]; free(Pi);free(Pj);free(colcnt);
  ic0_t *P=malloc(sizeof(ic0_t)); P->n=n; P->colptr=malloc((n+1)*sizeof(int));
  int *rowidx=malloc(np*sizeof(int)); int w=0; P->colptr[0]=0;
  for(int j=0;j<n;j++){int a=cstart[j],b=cstart[j+1]; qsort(tmp+a,b-a,sizeof(int),cmp_int); int last=-1;
    for(int q=a;q<b;q++) if(tmp[q]!=last){rowidx[w++]=tmp[q];last=tmp[q];} P->colptr[j+1]=w;}
  free(tmp);free(pos);free(cstart);
  P->nzL=w; P->rowidx=realloc(rowidx,w*sizeof(int)); P->L=malloc(w*sizeof(double)); S->P=P;
  S->W = malloc((long)n*(k>0?k:1)*sizeof(double));
  S->Sf= malloc((long)(k>0?k:1)*(k>0?k:1)*sizeof(double));
  S->tk= malloc((k>0?k:1)*sizeof(double));
  return S;
}
void pk_ic0w_free(ic0w_t *S){ if(!S)return; pk_ic0_free(S->P); free(S->dt); free(S->W); free(S->Sf); free(S->tk); free(S); }

PK_HOT void pk_ic0w_factor(ic0w_t *S, int nt, const int *ptr, const int *idx, const double *val,
                    const double *cv, double ridge, int thr) {
  int n=S->n, k=S->k; ic0_t *P=S->P;
  const int *colptr=P->colptr,*rowidx=P->rowidx; double *A=P->L;
  memset(A,0,P->nzL*sizeof(double));
  double maxdiag=ridge; for(int j=0;j<n;j++)A[colptr[j]]=ridge;
  for(int ti=0;ti<nt;ti++){ double c=cv[ti]; if(c==0.0)continue; int lo=ptr[ti],hi=ptr[ti+1]; if(hi-lo>thr)continue;
    for(int x=lo;x<hi;x++)for(int y=lo;y<=x;y++){int a=idx[x],b=idx[y],i=a>b?a:b,jj=a>b?b:a; A[find_row(colptr,rowidx,jj,i)]+=c*val[x]*val[y];}}
  for(int j=0;j<n;j++) if(A[colptr[j]]>maxdiag)maxdiag=A[colptr[j]];
  double tau=1e-6*maxdiag;
  for(int j=0;j<n;j++){ double dj=A[colptr[j]]; if(dj<tau)dj=tau; double ljj=sqrt(dj); A[colptr[j]]=ljj;
    for(int p=colptr[j]+1;p<colptr[j+1];p++)A[p]/=ljj;
    for(int p=colptr[j]+1;p<colptr[j+1];p++){int r=rowidx[p];double Lrj=A[p];
      for(int q=p;q<colptr[j+1];q++){int s=rowidx[q];int tt=find_row(colptr,rowidx,r,s); if(tt>=0)A[tt]-=A[q]*Lrj;}}}
  if(k==0) return;
  double *u=malloc(n*sizeof(double));                         /* W = P⁻¹U */
  for(int jj=0;jj<k;jj++){ int ti=S->dt[jj]; int lo=ptr[ti],hi=ptr[ti+1];
    for(int i=0;i<n;i++)u[i]=0.0; for(int x=lo;x<hi;x++)u[idx[x]]+=val[x];
    ic0_apply(P,u,S->W + (long)jj*n); }
  free(u);
  double *Sf=S->Sf;                                           /* S = C⁻¹ + UᵀW (row-major, symmetric) */
  for(int i=0;i<k;i++){ int ti=S->dt[i]; int lo=ptr[ti],hi=ptr[ti+1];
    for(int j=0;j<k;j++){ double s=0.0; const double *wj=S->W+(long)j*n;
      for(int x=lo;x<hi;x++) s+=val[x]*wj[idx[x]]; Sf[(long)i*k+j]=s; }
    double c=cv[ti]; Sf[(long)i*k+i] += 1.0/(c>1e-12?c:1e-12); }
  for(int i=0;i<k;i++){                                        /* Cholesky (lower, in place) */
    for(int j=0;j<=i;j++){ double s=Sf[(long)i*k+j];
      for(int p=0;p<j;p++) s-=Sf[(long)i*k+p]*Sf[(long)j*k+p];
      if(i==j){ Sf[(long)i*k+i]= s>1e-300?sqrt(s):1e-150; }
      else    { Sf[(long)i*k+j]= s/Sf[(long)j*k+j]; } } }
}
static void ic0w_apply(const ic0w_t *S, const double *v, double *z){
  ic0_apply(S->P, v, z); int k=S->k, n=S->n; if(k==0)return;
  double *t=S->tk; const double *Sf=S->Sf;
  for(int j=0;j<k;j++){ double s=0.0; const double *wj=S->W+(long)j*n; for(int i=0;i<n;i++)s+=wj[i]*v[i]; t[j]=s; }
  for(int i=0;i<k;i++){ double s=t[i]; for(int p=0;p<i;p++)s-=Sf[(long)i*k+p]*t[p]; t[i]=s/Sf[(long)i*k+i]; }
  for(int i=k-1;i>=0;i--){ double s=t[i]; for(int p=i+1;p<k;p++)s-=Sf[(long)p*k+i]*t[p]; t[i]=s/Sf[(long)i*k+i]; }
  for(int j=0;j<k;j++){ double tj=t[j]; const double *wj=S->W+(long)j*n; for(int i=0;i<n;i++)z[i]-=wj[i]*tj; }
}
PK_HOT int pk_pcg_ic0w(ic0w_t *S, int nt, int n, const int *ptr, const int *idx, const double *val,
                const double *cv, const double *b, double ridge, int maxit,
                double *x, double *r, double *z, double *p, double *Hp){
  for(int i=0;i<n;i++){x[i]=0.0;r[i]=b[i];}
  ic0w_apply(S,r,z); for(int i=0;i<n;i++)p[i]=z[i];
  double rz=0.0; for(int i=0;i<n;i++)rz+=r[i]*z[i];
  int cap=n+2; if(maxit<cap)cap=maxit; int its=0;
  for(int kk=0;kk<cap;kk++){ double rr=0.0; for(int i=0;i<n;i++)rr+=r[i]*r[i]; if(rr<1e-14)break;
    hv(nt,n,ptr,idx,val,cv,p,ridge,Hp); double pHp=0.0; for(int i=0;i<n;i++)pHp+=p[i]*Hp[i];
    double al=rz/(pHp>1e-30?pHp:1e-30); its++;
    for(int i=0;i<n;i++){x[i]+=al*p[i];r[i]-=al*Hp[i];}
    ic0w_apply(S,r,z); double rz2=0.0; for(int i=0;i<n;i++)rz2+=r[i]*z[i];
    double beta=rz2/rz; for(int i=0;i<n;i++)p[i]=z[i]+beta*p[i]; rz=rz2; }
  return its;
}

/* ───────────────────────────────────────────────────────────────────────────
 * SSOR (symmetric Gauss–Seidel) preconditioner, MATRIX-FREE.
 * The recipe graph is exactly the sparse coupling Cockshott–Cottrell sweep with
 * Gauss–Seidel on the Leontief system. As a CG preconditioner: M = (D+L)D⁻¹(D+Lᵀ),
 * D=diag(H)+ridge, L = strict-lower part of H. Applied via RUNNING term-dot-products
 * s_ℓ = a_ℓᵀy updated incrementally as the sweep advances — so H is NEVER assembled
 * and a dense HUB row costs only O(its nnz) per sweep (no fill, no dense block). It
 * captures the off-diagonal recipe coupling that Jacobi misses ⇒ far fewer CG iters.
 * Uses the variable→terms transpose (CSC: cscptr/cscidx=term, cscval=a_ℓ[var]).
 * ─────────────────────────────────────────────────────────────────────────── */
static void ssor_apply(int n, int nt, const int *cscptr, const int *cscidx, const double *cscval,
                       const double *cv, const double *diag, const double *r, double *z,
                       double *y, double *s) {
  for (int t = 0; t < nt; t++) s[t] = 0.0;
  for (int i = 0; i < n; i++) {                          /* forward: (D+L) y = r */
    double acc = 0.0; const int hi = cscptr[i + 1];
    for (int q = cscptr[i]; q < hi; q++) { int t = cscidx[q]; acc += cv[t] * cscval[q] * s[t]; }
    double yi = (r[i] - acc) / diag[i]; y[i] = yi;
    for (int q = cscptr[i]; q < hi; q++) s[cscidx[q]] += cscval[q] * yi;
  }
  for (int i = 0; i < n; i++) y[i] *= diag[i];           /* w = D y */
  for (int t = 0; t < nt; t++) s[t] = 0.0;
  for (int i = n - 1; i >= 0; i--) {                     /* backward: (D+Lᵀ) z = w */
    double acc = 0.0; const int hi = cscptr[i + 1];
    for (int q = cscptr[i]; q < hi; q++) { int t = cscidx[q]; acc += cv[t] * cscval[q] * s[t]; }
    double zi = (y[i] - acc) / diag[i]; z[i] = zi;
    for (int q = cscptr[i]; q < hi; q++) s[cscidx[q]] += cscval[q] * zi;
  }
}
PK_HOT int pk_pcg_ssor(int nt, int n, const int *ptr, const int *idx, const double *val,
                const double *cv, const int *cscptr, const int *cscidx, const double *cscval,
                const double *diag, const double *b, double ridge, int maxit,
                double *x, double *r, double *z, double *p, double *Hp, double *y, double *s) {
  for (int i = 0; i < n; i++) { x[i] = 0.0; r[i] = b[i]; }
  ssor_apply(n, nt, cscptr, cscidx, cscval, cv, diag, r, z, y, s);
  for (int i = 0; i < n; i++) p[i] = z[i];
  double rz = 0.0; for (int i = 0; i < n; i++) rz += r[i] * z[i];
  int cap = n + 2; if (maxit < cap) cap = maxit; int its = 0;
  for (int k = 0; k < cap; k++) {
    double rr = 0.0; for (int i = 0; i < n; i++) rr += r[i] * r[i]; if (rr < 1e-14) break;
    hv(nt, n, ptr, idx, val, cv, p, ridge, Hp);
    double pHp = 0.0; for (int i = 0; i < n; i++) pHp += p[i] * Hp[i];
    double al = rz / (pHp > 1e-30 ? pHp : 1e-30); its++;
    for (int i = 0; i < n; i++) { x[i] += al * p[i]; r[i] -= al * Hp[i]; }
    ssor_apply(n, nt, cscptr, cscidx, cscval, cv, diag, r, z, y, s);
    double rz2 = 0.0; for (int i = 0; i < n; i++) rz2 += r[i] * z[i];
    double beta = rz2 / rz; for (int i = 0; i < n; i++) p[i] = z[i] + beta * p[i]; rz = rz2;
  }
  return its;
}

/* ───────────────────────────────────────────────────────────────────────────
 * §2d — OPENMP-PARALLEL Jacobi-CG.  The CG inner loop (matvec × ~290 iters/step)
 * is the whole cost on a realistically-coupled economy; parallelizing it across
 * cores is the laptop's multicore win.  The matvec scatter r[idx]+=… races under
 * naive OpenMP, so we use the TWO-PHASE form: (1) parallel over FORMS, gather each
 * form's dot dₜ=aₜᵀv and cd[t]=cv·dₜ (race-free — each form writes its own cd);
 * (2) parallel over VARIABLES via the CSC transpose, r[i]=ridge·vᵢ+Σ cd[t]·val
 * (race-free — each variable writes its own r[i]).  The vector ops use reductions.
 * ─────────────────────────────────────────────────────────────────────────── */

/* CSC transpose of the form-matrix: per variable i, the (form, coeff) entries
 * touching it. Caller allocates cscptr[n+1], cscidx[nnz], cscval[nnz]. */
PK_HOT void pk_build_csc(int nt, int n, const int *ptr, const int *idx, const double *val,
                  int *cscptr, int *cscidx, double *cscval) {
  int nnz = ptr[nt];
  for (int i = 0; i <= n; i++) cscptr[i] = 0;
  for (int k = 0; k < nnz; k++) cscptr[idx[k] + 1]++;
  for (int i = 0; i < n; i++) cscptr[i + 1] += cscptr[i];
  int *pos = malloc(n * sizeof(int));
  for (int i = 0; i < n; i++) pos[i] = cscptr[i];
  for (int ti = 0; ti < nt; ti++)
    for (int k = ptr[ti]; k < ptr[ti + 1]; k++) {
      int i = idx[k], p = pos[i]++; cscidx[p] = ti; cscval[p] = val[k];
    }
  free(pos);
}

/* OpenMP Jacobi-preconditioned CG. Same math/iteration count as pk_pcg, parallel.
 * CRITICAL: the ENTIRE solve runs in ONE `omp parallel` region — the thread team
 * is created ONCE, and the loops within use `omp for` (a BARRIER, not a fork/join)
 * between them. Opening a fresh parallel region per loop (≈6 per CG iter × 30k
 * iters) is pure overhead and runs MANY times slower than serial; this pattern
 * pays the team-creation cost once and amortizes it over the whole solve. */
int pk_pcg_omp(int nt, int n, const int *ptr, const int *idx, const double *val,
               const double *cv, const int *cscptr, const int *cscidx, const double *cscval,
               const double *b, const double *diag, double ridge, int maxit,
               double *x, double *r, double *z, double *p, double *Hp, double *cd) {
  int cap = n + 2; if (maxit < cap) cap = maxit;
  int its = 0;
  double rz = 0.0, rr = 0.0, pHp = 0.0, rz2 = 0.0, al = 0.0, beta = 0.0;
  #pragma omp parallel
  {
    #pragma omp for schedule(static)
    for (int i = 0; i < n; i++) { x[i] = 0.0; r[i] = b[i]; z[i] = r[i] / diag[i]; p[i] = z[i]; }
    #pragma omp for schedule(static) reduction(+:rz)
    for (int i = 0; i < n; i++) rz += r[i] * z[i];
    for (int k = 0; k < cap; k++) {
      #pragma omp single
      { rr = 0.0; }
      #pragma omp for schedule(static) reduction(+:rr)
      for (int i = 0; i < n; i++) rr += r[i] * r[i];
      if (rr < 1e-14) break;                               /* all threads see same rr (barrier) */
      /* H·p, two-phase: phase 1 over forms → cd, phase 2 over variables → Hp */
      #pragma omp for schedule(static)
      for (int ti = 0; ti < nt; ti++) {
        double c = cv[ti];
        if (c == 0.0) { cd[ti] = 0.0; continue; }
        double dot = 0.0; int hi = ptr[ti + 1];
        for (int q = ptr[ti]; q < hi; q++) dot += val[q] * p[idx[q]];
        cd[ti] = c * dot;
      }
      #pragma omp for schedule(static)
      for (int i = 0; i < n; i++) {
        double s = ridge * p[i]; int hi = cscptr[i + 1];
        for (int q = cscptr[i]; q < hi; q++) s += cd[cscidx[q]] * cscval[q];
        Hp[i] = s;
      }
      #pragma omp single
      { pHp = 0.0; }
      #pragma omp for schedule(static) reduction(+:pHp)
      for (int i = 0; i < n; i++) pHp += p[i] * Hp[i];
      #pragma omp single
      { al = rz / (pHp > 1e-30 ? pHp : 1e-30); its++; }
      #pragma omp for schedule(static)
      for (int i = 0; i < n; i++) { x[i] += al * p[i]; r[i] -= al * Hp[i]; }
      #pragma omp single
      { rz2 = 0.0; }
      #pragma omp for schedule(static) reduction(+:rz2)
      for (int i = 0; i < n; i++) { z[i] = r[i] / diag[i]; rz2 += r[i] * z[i]; }
      #pragma omp single
      { beta = rz2 / rz; rz = rz2; }
      #pragma omp for schedule(static)
      for (int i = 0; i < n; i++) p[i] = z[i] + beta * p[i];
    }
  }
  return its;
}
int pk_omp_threads(void) {
#ifdef _OPENMP
  return omp_get_max_threads();
#else
  return 1;
#endif
}

/* ───────────────────────────────────────────────────────────────────────────
 * §2e — FULL SOLVE in C + COARSE-GRAINED OpenMP over REGIONS.  Fine-grained
 * parallelism of the CG loop is overhead-bound (30k tiny iterations); the ONLY
 * granularity that pays is a WHOLE region solve per thread (ms-seconds of work).
 * pk_solve ports solve-native-c-core (central path + Newton + line search, Jacobi
 * CG) into C so an entire interior-point solve is one call; pk_solve_many_same
 * runs N independent solves in `omp parallel for` — coarse, so the overhead
 * amortizes. This is the federation/decomposition engine's parallel core.
 * ─────────────────────────────────────────────────────────────────────────── */

PK_HOT int pk_pcg(int nt, int n, const int *ptr, const int *idx, const double *val,
           const double *cv, const double *b, const double *diag, double ridge,
           int maxit, double *x, double *r, double *z, double *p, double *Hp);  /* fwd */

/* fraction-to-the-boundary: largest η keeping every BARRIER slack (bar/frag/held) ≥ 1% of its
 * current value along d — the standard interior-point safeguard that keeps the iterate strictly
 * inside the barriers and bounds the step, so a far start can never roam across a wall. sv must be
 * s(x). held (kind 4) diverges at its own wall exactly as frag diverges at its tip — kind 3 was
 * missing here once (see the comment at its primal-dual call site below) and held repeated it. */
PK_HOT static double pk_frac_to_boundary(int nt, const int *ptr, const int *idx, const double *val,
                                  const int *kind, const double *sv, const double *d) {
  double cap = 1.0;
  for (int ti = 0; ti < nt; ti++) {
    if (kind[ti] == 0 || kind[ti] == 3 || kind[ti] == 4) {  /* bar, frag and held all carry a wall */
      double ds = 0.0;                                    /* directional derivative Σ coeff·d */
      for (int j = ptr[ti]; j < ptr[ti + 1]; j++) ds += val[j] * d[idx[j]];
      if (ds < 0.0) { double e = -0.99 * sv[ti] / ds; if (e < cap) cap = e; }
    }
  }
  return cap;
}

/* full single-region interior-point solve. Jacobi-CG. x0 must be strictly
 * bar-feasible (warm starts are; round-0 via Scheme phase-I). x is in/out.
 * scratch (caller-allocated): sv[nt],cv[nt],g[n],b[n],diag[n],d[n],y[n],r[n],
 * z[n],p[n],hp[n]. Returns the Newton-step count. */
/* FINAL CENTRAL-PATH PARAMETER.
 * The barrier weight t is walked down to this floor and no further, so it is not
 * a pure implementation detail: the centering term it leaves behind is felt in
 * the plan. On a NON-BINDING wall the residual +t/x gradient is balanced only by
 * the free-time thrift kappa*l, so production settles near 2t/(kappa*l) ABOVE
 * demand rather than at demand -- visible surplus on an abundant input.
 *
 * It was hardcoded here AND declared as *kern-tmin* in planner.scm: two copies of
 * one constant, so setting the Scheme one moved nothing and the knob read as live
 * while being inert. Scheme is now authoritative and pushes it through
 * pk_set_tmin. See tests/solve/test-centering-floor.scm. */
static double pk_tmin = 0.02;

void pk_set_tmin(double v) { if (v > 0.0) pk_tmin = v; }
double pk_get_tmin(void)   { return pk_tmin; }

/* The REST of the central-path schedule, pushed from Scheme the same way
 * (solver.scm sync-kern-dials!): contraction sigma, the mid/final Newton cap
 * split, and the inner tolerance's three dials — the final level reads
 * max(abs, rel*gscale) with gscale = 1 + ||grad|| at the solve's first step
 * (solver.scm inner-tol / *kern-newton-mid* / *kern-newton-final*), an
 * intermediate level max(1e-6, tau*t). The defaults are the flat schedule
 * this core carried hardcoded, so an unsynced caller is byte-identical. */
static double pk_sigma = 0.5;
static int    pk_newton_mid = 40, pk_newton_final = 40;
static double pk_inner_abs = 1e-6, pk_inner_rel = 0.0, pk_inner_tau = 0.0;
void pk_set_schedule(double sigma, int mid, int fin,
                     double inner_abs, double inner_rel, double inner_tau) {
  if (sigma > 0.0 && sigma < 1.0) pk_sigma = sigma;
  if (mid > 0) pk_newton_mid = mid;
  if (fin > 0) pk_newton_final = fin;
  if (inner_abs > 0.0) pk_inner_abs = inner_abs;
  if (inner_rel >= 0.0) pk_inner_rel = inner_rel;
  if (inner_tau >= 0.0) pk_inner_tau = inner_tau;
}

PK_HOT int pk_solve(int nt, int n, int nlab,
             const int *ptr, const int *idx, const double *val, const int *kind,
             const double *cnst, const double *D, const double *w,
             const int *lab_idx, const double *lab_val, double kappa, double ridge,
             double tstart, double *x,
             double *sv, double *cv, double *g, double *b, double *diag,
             double *d, double *y, double *r, double *z, double *p, double *hp) {
  double t = tstart; int ntot = 0;
  double gscale = 1.0; int first = 1;                           /* 1 + ||grad|| at the solve's first step */
  for (;;) {                                                    /* central path */
    int final = (t <= pk_tmin * 1.0001);                        /* the dial-driven schedule (pk_set_schedule): */
    int cap = final ? pk_newton_final : pk_newton_mid;          /* polish hard only at the floor, and read the */
    for (int it = 0; ; ) {                                      /* Newton at this t */
      pk_term_values(nt, ptr, idx, val, cnst, x, sv);
      pk_csr_grad(nt, n, ptr, idx, val, kind, D, w, t, sv, g);
      for (int k = 0; k < nlab; k++) g[lab_idx[k]] += kappa * lab_val[k];
      double gn = 0.0; for (int i = 0; i < n; i++) gn += g[i] * g[i]; gn = sqrt(gn);
      if (first) { gscale = 1.0 + gn; first = 0; }
      double tol = final ? fmax(pk_inner_abs, pk_inner_rel * gscale)   /* final tolerance off the program's own scale */
                         : fmax(1e-6, pk_inner_tau * t);
      if (it >= cap || gn < tol) break;                         /* converged at t */
      pk_term_coeffs(nt, kind, D, w, t, sv, cv);
      for (int i = 0; i < n; i++) b[i] = -g[i];
      pk_csr_diag(nt, n, ptr, idx, val, cv, ridge, diag);
      int cap = n + 2;   /* CG's own exact bound for an n-dimensional SPD system; see solver.scm *kern-cgcap* for why this is not a smaller flat number */
      pk_pcg(nt, n, ptr, idx, val, cv, b, diag, ridge, cap, d, r, z, p, hp);
      ntot++;
      double Lx = 0.0; for (int k = 0; k < nlab; k++) Lx += lab_val[k] * x[lab_idx[k]];
      double f0 = pk_obj_value(nt, kind, D, w, t, sv) + kappa * Lx;   /* sv = s(x) */
      double Ld = 0.0; for (int k = 0; k < nlab; k++) Ld += lab_val[k] * d[lab_idx[k]];
      double eta = pk_frac_to_boundary(nt, ptr, idx, val, kind, sv, d);   /* sv = s(x) here; never step a barrier to (near) zero */
      if (eta > 1.0) eta = 1.0;
      int accepted = 0;
      for (;;) {                                                /* line search */
        for (int i = 0; i < n; i++) y[i] = x[i] + eta * d[i];
        pk_term_values(nt, ptr, idx, val, cnst, y, sv);
        double fy = pk_obj_value(nt, kind, D, w, t, sv) + kappa * (Lx + eta * Ld);
        if (fy < 1e11 && fy < f0 - 1e-9) { memcpy(x, y, (size_t)n * sizeof(double)); it++; accepted = 1; break; }
        if (eta < 1e-9) break;
        eta *= 0.5;
      }
      if (!accepted) break;                                     /* stuck ⇒ advance path */
    }
    if (t <= pk_tmin) break;
    t *= pk_sigma; if (t < pk_tmin) t = pk_tmin;
  }
  return ntot;
}

/* Augmented-KKT (sparse saddle [G Aᵀ; A −Θ⁻¹] + preconditioned MINRES) was tried as
 * an alternative to the normal-equations Newton solve and VALIDATED NOT A WIN: with a
 * cheap diagonal preconditioner MINRES needs ~4–7× more iters and fails near the
 * optimum (Θ⁻¹=s/y→0 ill-conditions the indefinite saddle), so the SPD normal equations
 * stay better for our matrix-free IPM. Full implementation + validation harness in git
 * history (commit 196c0bf); a competitive version needs a constraint/factorization
 * preconditioner or primal-dual regularization (Friedlander–Orban). */

/* ───────────────────────────────────────────────────────────────────────────
 * pk_solve_pd — matrix-free PRIMAL-DUAL Mehrotra predictor-corrector.
 * 'bar terms (kind 0) are the constraints s≥0 with duals y; kinds 1-3 the smooth
 * objective f. Newton matrix M = ∇²f_obj + Σ_bar (y/s)·a aᵀ — the SAME matrix-free
 * Hv, only cv[bar]=y/s. Predictor RHS = −∇f_obj (gradient at t=0 kills the barrier);
 * corrector reuses M with the adaptive-σ + 2nd-order RHS. μ=sᵀy/m → 0 drives
 * convergence (no t-schedule). Validated ~18× fewer outer iters than path-following
 * (bench-mehrotra.scm). x = strictly-feasible start (s>0), updated in place. */
/* MU_OUT: the duality gap at the halt, s^T y / m — the CERTIFICATE.
 * It was computed here and discarded, which left the caller able to trust a plan
 * but never to CHECK one. A plan without its gap is an assertion; a plan with it
 * is a proof anyone can re-run. Pass NULL if you genuinely do not want it. */
/* The Newton system's solve, chosen once per call: matrix-free Jacobi CG (S == NULL —
 * the standing path), or the sparse Cholesky of the normal equations (S from
 * pk_chol_symbolic: the pattern fixed, refactored numerically each step as cv moves)
 * used as CG's preconditioner. With maxdeg the factor holds the SPARSE skeleton only —
 * on a two-stage program the recourse blocks — and the dense first-stage columns ride
 * in CG: the block preconditioner the robust extensive form asks for, cg/step → few. */
struct chol_s;
int pk_chol_factor(struct chol_s *S, int nt, const int *ptr, const int *idx,
                   const double *val, const double *cv, double ridge);
int pk_pcg_chol(struct chol_s *S, int nt, int n, const int *ptr, const int *idx,
                const double *val, const double *cv, const double *b,
                double ridge, int maxit,
                double *x, double *r, double *z, double *p, double *Hp);
static int pd_core(struct chol_s *S, int nt, int n, int nlab, const int *ptr, const int *idx, const double *val,
                const int *kind, const double *cnst, const double *D, const double *w,
                const int *lab_idx, const double *lab_val, double kappa, double ridge,
                double tol, int maxit, int omp, double *x, double *mu_out,
                double *y_out);
PK_HOT int pk_solve_pd(int nt, int n, int nlab, const int *ptr, const int *idx, const double *val,
                const int *kind, const double *cnst, const double *D, const double *w,
                const int *lab_idx, const double *lab_val, double kappa, double ridge,
                double tol, int maxit, int omp, double *x, double *mu_out,
                double *y_out) {
  return pd_core(NULL, nt, n, nlab, ptr, idx, val, kind, cnst, D, w, lab_idx, lab_val,
                 kappa, ridge, tol, maxit, omp, x, mu_out, y_out);
}
static int pd_core(struct chol_s *S, int nt, int n, int nlab, const int *ptr, const int *idx, const double *val,
                const int *kind, const double *cnst, const double *D, const double *w,
                const int *lab_idx, const double *lab_val, double kappa, double ridge,
                double tol, int maxit, int omp, double *x, double *mu_out,
                double *y_out) {
  int m = 0; for (int t = 0; t < nt; t++) if (kind[t] == 0) m++;
  int mm = m ? m : 1;
  int *bpos = malloc((size_t)nt * sizeof(int));
  { int mi = 0; for (int t = 0; t < nt; t++) bpos[t] = (kind[t] == 0) ? mi++ : -1; }
  double *sv = malloc(nt*sizeof(double)), *cv = malloc(nt*sizeof(double));
  double *gf = malloc(n*sizeof(double)), *b = malloc(n*sizeof(double)), *diag = malloc(n*sizeof(double));
  double *dx = malloc(n*sizeof(double)), *r = malloc(n*sizeof(double)), *z = malloc(n*sizeof(double));
  double *p = malloc(n*sizeof(double)), *hp = malloc(n*sizeof(double)), *tmpn = malloc(n*sizeof(double));
  double *s = malloc(mm*sizeof(double)), *yy = malloc(mm*sizeof(double));
  double *dsa = malloc(mm*sizeof(double)), *dya = malloc(mm*sizeof(double));
  double *ds = malloc(mm*sizeof(double)), *dy = malloc(mm*sizeof(double));
  /* OMP CG needs the variable→terms transpose (CSC) built once + a cd scratch */
  long nnz = ptr[nt];
  int *cscptr = NULL, *cscidx = NULL; double *cscval = NULL, *cd = NULL;
  if (omp) { cscptr = malloc((size_t)(n+1)*sizeof(int)); cscidx = malloc((size_t)nnz*sizeof(int));
             cscval = malloc((size_t)nnz*sizeof(double)); cd = malloc(nt*sizeof(double));
             pk_build_csc(nt, n, ptr, idx, val, cscptr, cscidx, cscval); }
  for (int i = 0; i < m; i++) yy[i] = 1.0;
  int cap = n + 2;   /* CG's own exact bound for an n-dimensional SPD system; see solver.scm *kern-cgcap* for why this is not a smaller flat number */
  int it = 0;
  double bestmu = 1e300; int stall = 0;
  double mu = 1e300;                       /* the gap at the halt — reported via mu_out */
  for (; it < maxit; it++) {
    pk_term_values(nt, ptr, idx, val, cnst, x, sv);                       /* slacks */
    for (int t = 0; t < nt; t++) if (bpos[t] >= 0) s[bpos[t]] = sv[t];
    mu = 0.0; for (int i = 0; i < m; i++) mu += s[i] * yy[i]; mu /= mm;
    if (mu < tol) break;
    /* CG-noisy directions can't drive μ below ~1e-6; once it is already small and
     * stops improving (no 10% gain in 4 iters) we are at the optimum to CG accuracy
     * — stop. GATED on μ<1e-4 so the early high-μ centering phase never trips it. */
    if (mu < 1e-4) { if (mu < 0.9 * bestmu) { bestmu = mu; stall = 0; } else if (++stall >= 4) break; }
    pk_csr_grad(nt, n, ptr, idx, val, kind, D, w, 0.0, sv, gf);           /* ∇f_obj (t=0) */
    for (int k = 0; k < nlab; k++) gf[lab_idx[k]] += kappa * lab_val[k];
    for (int t = 0; t < nt; t++)                                          /* cv: bar→y/s, obj→curv */
      cv[t] = (bpos[t] >= 0) ? (yy[bpos[t]] / (sv[t] > 1e-12 ? sv[t] : 1e-12))
                             : pk_kind_curv(kind[t], sv[t], 0.0, D[t], w[t]);
    pk_csr_diag(nt, n, ptr, idx, val, cv, ridge, diag);
    double rid = ridge;                                         /* the absolute guard, as in pk_solve */
    for (int i = 0; i < n; i++) b[i] = -gf[i];                            /* PREDICTOR: M dx = -∇f */
    if (S) pk_chol_factor(S, nt, ptr, idx, val, cv, rid);       /* the step's own M, once */
    if (S)        pk_pcg_chol(S, nt, n, ptr, idx, val, cv, b, rid, cap, dx, r, z, p, hp);
    else if (omp) pk_pcg_omp(nt, n, ptr, idx, val, cv, cscptr, cscidx, cscval, b, diag, rid, cap, dx, r, z, p, hp, cd);
    else          pk_pcg(nt, n, ptr, idx, val, cv, b, diag, rid, cap, dx, r, z, p, hp);
    for (int t = 0; t < nt; t++) if (bpos[t] >= 0) {                      /* ds_aff = A dx */
      double a = 0.0; for (int k = ptr[t]; k < ptr[t+1]; k++) a += val[k]*dx[idx[k]]; dsa[bpos[t]] = a; }
    for (int i = 0; i < m; i++) dya[i] = -yy[i] - (yy[i]/(s[i]>1e-12?s[i]:1e-12))*dsa[i];
    double aa = 1.0;
    for (int i = 0; i < m; i++) { if (dsa[i] < 0.0) { double q = -s[i]/dsa[i]; if (q < aa) aa = q; }
                                  if (dya[i] < 0.0) { double q = -yy[i]/dya[i]; if (q < aa) aa = q; } }
    double muaf = 0.0; for (int i = 0; i < m; i++) muaf += (s[i]+aa*dsa[i])*(yy[i]+aa*dya[i]); muaf /= mm;
    double sig = (mu > 1e-30) ? (muaf/mu)*(muaf/mu)*(muaf/mu) : 0.0;
    for (int i = 0; i < n; i++) tmpn[i] = 0.0;                            /* CORRECTOR RHS */
    for (int t = 0; t < nt; t++) if (bpos[t] >= 0) { int j = bpos[t]; double si = s[j]>1e-12?s[j]:1e-12;
      double vt = (dsa[j]*dya[j])/si - sig*mu/si;
      for (int k = ptr[t]; k < ptr[t+1]; k++) tmpn[idx[k]] += vt*val[k]; }
    for (int i = 0; i < n; i++) b[i] = -gf[i] - tmpn[i];
    if (S)        pk_pcg_chol(S, nt, n, ptr, idx, val, cv, b, rid, cap, dx, r, z, p, hp);
    else if (omp) pk_pcg_omp(nt, n, ptr, idx, val, cv, cscptr, cscidx, cscval, b, diag, rid, cap, dx, r, z, p, hp, cd);
    else          pk_pcg(nt, n, ptr, idx, val, cv, b, diag, rid, cap, dx, r, z, p, hp);
    for (int t = 0; t < nt; t++) if (bpos[t] >= 0) {                      /* ds = A dx */
      double a = 0.0; for (int k = ptr[t]; k < ptr[t+1]; k++) a += val[k]*dx[idx[k]]; ds[bpos[t]] = a; }
    for (int i = 0; i < m; i++) { double si = s[i]>1e-12?s[i]:1e-12;
      dy[i] = (-(s[i]*yy[i] + dsa[i]*dya[i] - sig*mu) - yy[i]*ds[i]) / si; }
    double al = 1.0;
    for (int i = 0; i < m; i++) { if (ds[i] < 0.0) { double q = -s[i]/ds[i]; if (q < al) al = q; }
                                  if (dy[i] < 0.0) { double q = -yy[i]/dy[i]; if (q < al) al = q; } }
    /* …and every OTHER barrier too, not just the kind-0 constraints tracked in s[].
     * A `frag` term (kind 3) is carried in the smooth objective here, and its
     * gradient is defined as ZERO once its slack goes non-positive — so once the
     * iterate steps past a fragility tip nothing pushes it back, and the solve
     * happily converges outside the barrier and certifies the result. Measured on
     * the frag rig (tip 10, optimum 9.0840): the primal-dual step returned
     * x = 43.74 with mu = 6.6e-7, an ecological limit passed by a factor of four
     * and reported as proven. pk_frac_to_boundary already covers kind 0 AND 3 —
     * the primal path-follower has always called it; this one never did.
     * Regression: tests/solve/test-certificate.scm. */
    { double fb = pk_frac_to_boundary(nt, ptr, idx, val, kind, sv, dx);
      if (fb < al) al = fb; }
    al *= 0.99;
    for (int i = 0; i < n; i++) x[i] += al*dx[i];
    for (int i = 0; i < m; i++) { yy[i] += al*dy[i]; if (yy[i] < 1e-12) yy[i] = 1e-12; }
    if (getenv("PLANNER_PD_DEBUG")) fprintf(stderr, "  pd it=%2d  mu=%.3e  sig=%.3f  alpha=%.4f\n", it, mu, sig, al);
  }
  if (mu_out) *mu_out = mu;
  /* Y_OUT: the dual iterate, laid out BY TERM (0 for non-constraint terms).
   * This method carries a real y and converges it alongside x; without it a
   * caller must invent one, and a residual measured against an invented dual is
   * meaningless — measured at 20,966% of the objective where the same program
   * through the path-follower certifies 0.023%. The dual is half the answer.
   * READ BEFORE THE FREES: bpos and yy are both about to be released. */
  if (y_out) for (int t = 0; t < nt; t++) y_out[t] = (bpos[t] >= 0) ? yy[bpos[t]] : 0.0;
  free(bpos); free(sv); free(cv); free(gf); free(b); free(diag); free(dx); free(r); free(z); free(p);
  free(hp); free(tmpn); free(s); free(yy); free(dsa); free(dya); free(ds); free(dy);
  if (omp) { free(cscptr); free(cscidx); free(cscval); free(cd); }
  return it;
}

/* solve N INDEPENDENT regions in parallel (coarse-grained OpenMP). Here all N
 * share the SAME read-only CSR (a benchmark/validation of the parallel scaling);
 * each has its own x (nreg×n contiguous) and scratch (nreg×(2nt+9n) contiguous).
 * Returns the total Newton steps. */
int pk_solve_many_same(int nreg, int nt, int n, int nlab,
    const int *ptr, const int *idx, const double *val, const int *kind,
    const double *cnst, const double *D, const double *w,
    const int *lab_idx, const double *lab_val, double kappa, double ridge,
    double tstart, double *x, double *scratch) {
  long per = (long)2 * nt + (long)9 * n;
  int total = 0;
  #pragma omp parallel for schedule(dynamic) reduction(+:total)
  for (int i = 0; i < nreg; i++) {
    double *xi = x + (long)i * n;
    double *s = scratch + (long)i * per;
    double *sv = s, *cv = sv + nt, *g = cv + nt, *bb = g + n, *diag = bb + n,
           *d = diag + n, *yy = d + n, *r = yy + n, *z = r + n, *p = z + n, *hp = p + n;
    total += pk_solve(nt, n, nlab, ptr, idx, val, kind, cnst, D, w,
                      lab_idx, lab_val, kappa, ridge, tstart, xi,
                      sv, cv, g, bb, diag, d, yy, r, z, p, hp);
  }
  return total;
}

/* solve N DIFFERENT regions in parallel (the real decomposition). Per-region data
 * via arrays-of-pointers; each region's scratch[i] is one (2·nt[i]+9·n[i]) block.
 * The Scheme coordinator owns the resident buffers and updates the proximal-form
 * cnst/w in place between calls; only x[i] is read/written (warm-started). */
int pk_solve_many(int nreg, const int *nts, const int *ns, const int *nlabs,
    const int *const *ptrs, const int *const *idxs, const double *const *vals, const int *const *kinds,
    const double *const *cnsts, const double *const *Ds, const double *const *ws,
    const int *const *labis, const double *const *labvs, double kappa, double ridge,
    double tstart, double *const *xs, double *const *scratches) {
  int total = 0;
  #pragma omp parallel for schedule(dynamic) reduction(+:total)
  for (int i = 0; i < nreg; i++) {
    int nt = nts[i], n = ns[i];
    double *s = scratches[i];
    double *sv = s, *cv = sv + nt, *g = cv + nt, *b = g + n, *diag = b + n,
           *d = diag + n, *y = d + n, *r = y + n, *z = r + n, *p = z + n, *hp = p + n;
    total += pk_solve(nt, n, nlabs[i], ptrs[i], idxs[i], vals[i], kinds[i], cnsts[i], Ds[i], ws[i],
                      labis[i], labvs[i], kappa, ridge, tstart, xs[i],
                      sv, cv, g, b, diag, d, y, r, z, p, hp);
  }
  return total;
}

/* mean delivered/demand over the desire (kind==1) forms, clamped to 1 - the met%
 * fraction, computed straight from the CSR so the coordinator need not keep the
 * Scheme `forms` lists resident (direct-CSR: marshal once, free the forms ⇒ the
 * ~3x memory cut, ~250 → ~80 B/nonzero). */
PK_HOT double pk_meanfill(int nt, const int *ptr, const int *idx, const double *val,
                   const int *kind, const double *cnst, const double *D, const double *x) {
  double sum = 0.0; int nd = 0;
  for (int ti = 0; ti < nt; ti++) {
    if (kind[ti] != 1) continue;
    double s = cnst[ti]; int hi = ptr[ti + 1];
    for (int k = ptr[ti]; k < hi; k++) s += val[k] * x[idx[k]];
    double f = s / D[ti]; if (f > 1.0) f = 1.0;
    sum += f; nd++;
  }
  return nd ? sum / nd : 0.0;
}

/* ───────────────────────────────────────────────────────────────────────────
 * §2c — SPARSE DIRECT factor.  The simulations showed CG is mesh-coupling-bound:
 * on a realistic space×time×product lattice, storage (period→period) and
 * transport (region→region) chains couple activities across the whole mesh, so a
 * LOCAL preconditioner (Jacobi, IC0-zero-fill) leaves CG churning ~290 iters/step
 * at the cap. The cure production convex solvers use: a genuine sparse Cholesky of
 * the normal equations H = ridge·I + Σ cv_k a_k a_kᵀ, factored ONCE-symbolic /
 * refactored-numeric each Newton step (the pattern is fixed; only cv changes), so
 * the linear solve is one forward/back substitution — cg/step → 1, exactly, and no
 * stall. Up-looking cs_chol (CSparse-style), with an optional Reverse Cuthill-McKee
 * fill-reducing ordering for the lattice. H is SPD (ridge>0), so plain Cholesky.
 * ─────────────────────────────────────────────────────────────────────────── */
typedef struct chol_s {
  int n;
  int maxdeg;                /* forms with degree > maxdeg are EXCLUDED from   */
                             /* the factor (the dense local-resource cliques,  */
                             /* e.g. labour caps): factor the sparse skeleton   */
                             /* only → near-linear fill; CG handles the dense   */
                             /* rank-1 terms matrix-free. <=0 ⇒ include all.    */
  int *pinv;                 /* pinv[old]=new position (NULL ⇒ identity)      */
  int *perm;                 /* perm[new]=old                                 */
  /* permuted upper-triangular pattern of H, CSC (col j holds rows i≤j), sorted */
  int *Cp, *Ci; double *Cx; int Cnnz;
  int *diagp;                /* diagp[j] = Cx slot of the (j,j) diagonal       */
  /* per-pair accumulation map: off[ti..ti+1] index map[]; map[k]=Cx slot      */
  long *off; int *map; long npairs;
  int *parent;               /* elimination tree                              */
  /* L factor, lower CSC, unit-free (diagonal stored explicitly at Lp[j])      */
  int *Lp, *Li; double *Lx;
  /* numeric/symbolic workspaces                                              */
  double *x; int *cwork, *s, *w;
} chol_t;

/* binary search row r in column-c sorted slice of Ci; -1 if absent */
static inline int csc_find(const int *Cp, const int *Ci, int c, int r) {
  int lo = Cp[c], hi = Cp[c + 1] - 1;
  while (lo <= hi) { int m = (lo + hi) >> 1, v = Ci[m];
    if (v == r) return m; if (v < r) lo = m + 1; else hi = m - 1; }
  return -1;
}

/* elimination tree of symmetric H from its upper-CSC pattern (CSparse cs_etree) */
static void chol_etree(int n, const int *Cp, const int *Ci, int *parent, int *anc) {
  for (int k = 0; k < n; k++) {
    parent[k] = -1; anc[k] = -1;
    for (int p = Cp[k]; p < Cp[k + 1]; p++) {
      int i = Ci[p];
      while (i != -1 && i < k) { int inext = anc[i]; anc[i] = k;
        if (inext == -1) parent[i] = k; i = inext; }
    }
  }
}
/* nonzero pattern of row k of L (the i<k that reach k), pushed to s[top..n-1].
 * w[] is a per-k marker: w[i]==k ⇔ visited this k (k strictly increasing). */
static int chol_ereach(int n, int k, const int *Cp, const int *Ci,
                       const int *parent, int *s, int *w) {
  int top = n; w[k] = k;
  for (int p = Cp[k]; p < Cp[k + 1]; p++) {
    int i = Ci[p]; if (i > k) continue;
    int len = 0;
    for (; w[i] != k; i = parent[i]) { s[len++] = i; w[i] = k; }
    while (len > 0) s[--top] = s[--len];
  }
  return top;
}

/* ── Reverse Cuthill-McKee ordering from a symmetric adjacency (adjp,adji) ──
 * BFS from a low-degree seed per component, neighbours visited in increasing
 * degree; RCM = reverse of that order. Cuts bandwidth ⇒ cuts Cholesky fill on
 * the lattice. perm[new]=old, pinv[old]=new. */
static void rcm_order(int n, const int *adjp, const int *adji, int *perm, int *pinv) {
  int *deg = malloc(n * sizeof(int));
  for (int i = 0; i < n; i++) { deg[i] = adjp[i + 1] - adjp[i]; pinv[i] = -1; }
  int *queue = malloc(n * sizeof(int));
  int order = 0;
  for (int start = 0; start < n; start++) {
    if (pinv[start] != -1) continue;
    /* seed = lowest-degree unvisited node in this component (scan from start) */
    int seed = start;
    for (int i = start; i < n; i++) if (pinv[i] == -1 && deg[i] < deg[seed]) seed = i;
    int qh = 0, qt = 0; queue[qt++] = seed; pinv[seed] = order++; perm[pinv[seed]] = seed;
    while (qh < qt) {
      int u = queue[qh++];
      int lo = adjp[u], hi = adjp[u + 1], cnt = 0;
      /* gather unvisited neighbours, insertion-sort by degree */
      static int *nb = 0; static int nbcap = 0;
      if (hi - lo > nbcap) { nbcap = hi - lo; nb = realloc(nb, nbcap * sizeof(int)); }
      for (int p = lo; p < hi; p++) { int v = adji[p];
        if (pinv[v] == -1) { int j = cnt++; while (j > 0 && deg[nb[j-1]] > deg[v]) { nb[j] = nb[j-1]; j--; } nb[j] = v; } }
      for (int j = 0; j < cnt; j++) { int v = nb[j];
        if (pinv[v] == -1) { pinv[v] = order++; perm[pinv[v]] = v; queue[qt++] = v; } }
    }
  }
  /* reverse: RCM */
  for (int i = 0; i < n; i++) { int r = n - 1 - pinv[i]; pinv[i] = r; }
  for (int i = 0; i < n; i++) perm[pinv[i]] = i;
  free(deg); free(queue);
}

/* build symmetric adjacency (no diagonal) of the variable graph from the forms:
 * a,b adjacent ⇔ they co-occur in some form. Returns CSR (adjp,adji). */
static void build_adj(int nt, int n, const int *ptr, const int *idx, int maxdeg,
                      int **adjp_out, int **adji_out) {
  /* count then fill, with per-node dedup via a marker */
  int *cnt = calloc(n + 1, sizeof(int));
  /* overcount directed edges (each form of size m gives m*(m-1)) then compress.
   * Excluded dense forms (degree>maxdeg) are skipped — RCM orders the skeleton. */
  long total = 0;
  for (int ti = 0; ti < nt; ti++) { long m = ptr[ti + 1] - ptr[ti];
    if (maxdeg > 0 && m > maxdeg) continue; total += m * (m - 1); }
  int *Ei = malloc((total > 0 ? total : 1) * sizeof(int));
  int *Ej = malloc((total > 0 ? total : 1) * sizeof(int));
  long e = 0;
  for (int ti = 0; ti < nt; ti++) {
    int lo = ptr[ti], hi = ptr[ti + 1];
    if (maxdeg > 0 && hi - lo > maxdeg) continue;
    for (int a = lo; a < hi; a++) for (int b = lo; b < hi; b++) if (a != b) {
      Ei[e] = idx[a]; Ej[e] = idx[b]; e++;
    }
  }
  for (long k = 0; k < e; k++) cnt[Ei[k]]++;
  int *start = malloc((n + 1) * sizeof(int)); start[0] = 0;
  for (int i = 0; i < n; i++) start[i + 1] = start[i] + cnt[i];
  int *tmp = malloc((e > 0 ? e : 1) * sizeof(int));
  int *pos = malloc(n * sizeof(int)); memcpy(pos, start, n * sizeof(int));
  for (long k = 0; k < e; k++) tmp[pos[Ei[k]]++] = Ej[k];
  free(Ei); free(Ej);
  /* dedup each node's neighbour list */
  int *adjp = malloc((n + 1) * sizeof(int)); adjp[0] = 0;
  int *adji = malloc((e > 0 ? e : 1) * sizeof(int)); int w = 0;
  for (int i = 0; i < n; i++) {
    int a = start[i], b = start[i + 1];
    qsort(tmp + a, b - a, sizeof(int), cmp_int);
    int last = -1;
    for (int k = a; k < b; k++) if (tmp[k] != last) { adji[w++] = tmp[k]; last = tmp[k]; }
    adjp[i + 1] = w;
  }
  free(cnt); free(start); free(tmp); free(pos);
  *adjp_out = adjp; *adji_out = realloc(adji, (w > 0 ? w : 1) * sizeof(int));
}

/* symbolic: permutation + permuted-upper H pattern + etree + L column counts +
 * per-pair accumulation map. Done ONCE per solve (pattern fixed across steps). */
/* BORDER COLUMNS. A column touching more than colmax forms couples blocks — on a
 * two-stage program the first-stage columns, present in every future's rows — and
 * keeping it in the factor fills L across every block it joins. With colmax > 0
 * such a column keeps only its diagonal in the factor: the factor holds the
 * block-diagonal skeleton (each future's recourse rows), and CG carries the
 * border matrix-free — the Schur-complement decomposition as a preconditioner.
 * 0 ⇒ no column excluded (the path-follower's standing read). */
static int pk_chol_colmax_v = 0;
void pk_chol_colmax(int v) { pk_chol_colmax_v = v < 0 ? 0 : v; }
PK_HOT chol_t *pk_chol_symbolic(int nt, int n, const int *ptr, const int *idx,
                         int use_rcm, int maxdeg) {
  chol_t *S = calloc(1, sizeof(chol_t)); S->n = n; S->maxdeg = maxdeg;
  /* permutation */
  if (use_rcm) {
    int *adjp, *adji; build_adj(nt, n, ptr, idx, maxdeg, &adjp, &adji);
    S->perm = malloc(n * sizeof(int)); S->pinv = malloc(n * sizeof(int));
    rcm_order(n, adjp, adji, S->perm, S->pinv);
    free(adjp); free(adji);
  }
  int *pinv = S->pinv;                       /* NULL ⇒ identity */
  /* border columns: degree over the included forms */
  int colmax = pk_chol_colmax_v; char *border = NULL;
  if (colmax > 0) {
    int *cdeg = calloc(n, sizeof(int));
    for (int ti = 0; ti < nt; ti++) { long m = ptr[ti + 1] - ptr[ti];
      if (maxdeg > 0 && m > maxdeg) continue;
      for (int x = ptr[ti]; x < ptr[ti + 1]; x++) cdeg[idx[x]]++; }
    border = calloc(n, 1); long nb = 0;
    for (int j = 0; j < n; j++) if (cdeg[j] > colmax) { border[j] = 1; nb++; }
    free(cdeg);
    if (getenv("PLANNER_PD_DEBUG")) fprintf(stderr, "  [chol] border columns: %ld of %d (colmax %d)\n", nb, n, colmax);
  }
  /* enumerate upper-permuted pairs (i≥j → store (min,max) as (row≤col)) */
  long np = n;
  for (int ti = 0; ti < nt; ti++) { long m = ptr[ti + 1] - ptr[ti];
    if (maxdeg > 0 && m > maxdeg) continue; np += m * (m + 1) / 2; }
  S->npairs = np;
  int *Pi = malloc(np * sizeof(int)), *Pj = malloc(np * sizeof(int));
  long t = 0;
  for (int i = 0; i < n; i++) { int pi = pinv ? pinv[i] : i; Pi[t] = pi; Pj[t] = pi; t++; }
  S->off = malloc((nt + 1) * sizeof(long));
  for (int ti = 0; ti < nt; ti++) {
    S->off[ti] = t;
    int lo = ptr[ti], hi = ptr[ti + 1];
    if (maxdeg > 0 && hi - lo > maxdeg) continue;            /* excluded: 0 pairs */
    for (int x = lo; x < hi; x++) for (int y = lo; y <= x; y++) {
      int a = idx[x], b = idx[y]; int pa = pinv ? pinv[a] : a, pb = pinv ? pinv[b] : b;
      int col = pa > pb ? pa : pb, row = pa > pb ? pb : pa;   /* upper: row≤col */
      if (border && a != b && (border[a] || border[b])) { Pi[t] = -1; Pj[t] = -1; t++; continue; } /* off the factor */
      Pi[t] = row; Pj[t] = col; t++;
    }
  }
  S->off[nt] = t;
  /* bucket by column, sort+dedup → upper CSC pattern */
  int *colcnt = calloc(n + 1, sizeof(int));
  for (long k = 0; k < np; k++) if (Pj[k] >= 0) colcnt[Pj[k]]++;
  int *cstart = malloc((n + 1) * sizeof(int)); cstart[0] = 0;
  for (int j = 0; j < n; j++) cstart[j + 1] = cstart[j] + colcnt[j];
  int *tmp = malloc(np * sizeof(int)); int *pos = malloc(n * sizeof(int));
  memcpy(pos, cstart, n * sizeof(int));
  for (long k = 0; k < np; k++) if (Pj[k] >= 0) tmp[pos[Pj[k]]++] = Pi[k];
  S->Cp = malloc((n + 1) * sizeof(int));
  int *Ci = malloc(np * sizeof(int)); int w = 0; S->Cp[0] = 0;
  for (int j = 0; j < n; j++) {
    int a = cstart[j], b = cstart[j + 1];
    qsort(tmp + a, b - a, sizeof(int), cmp_int);
    int last = -1;
    for (int k = a; k < b; k++) if (tmp[k] != last) { Ci[w++] = tmp[k]; last = tmp[k]; }
    S->Cp[j + 1] = w;
  }
  free(tmp); free(pos); free(cstart); free(colcnt);
  S->Cnnz = w; S->Ci = realloc(Ci, w * sizeof(int)); S->Cx = malloc(w * sizeof(double));
  /* diagonal slot per column (upper CSC ⇒ row==col is the LAST, largest entry) */
  S->diagp = malloc(n * sizeof(int));
  for (int j = 0; j < n; j++) S->diagp[j] = S->Cp[j + 1] - 1;
  /* per-pair Cx slot map */
  S->map = malloc(np * sizeof(int));
  for (long k = 0; k < np; k++) {
    int col = Pj[k], row = Pi[k];
    S->map[k] = (col < 0) ? -1 : csc_find(S->Cp, S->Ci, col, row);
  }
  free(Pi); free(Pj); free(border);
  /* etree + symbolic column counts (ereach) */
  S->parent = malloc(n * sizeof(int));
  S->s = malloc(n * sizeof(int)); S->w = malloc(n * sizeof(int));
  S->cwork = malloc(n * sizeof(int)); S->x = malloc(n * sizeof(double));
  int *anc = S->cwork;                                  /* reuse as scratch */
  chol_etree(n, S->Cp, S->Ci, S->parent, anc);
  int *count = malloc(n * sizeof(int));
  for (int i = 0; i < n; i++) { count[i] = 1; S->w[i] = -1; }
  for (int k = 0; k < n; k++) {
    int top = chol_ereach(n, k, S->Cp, S->Ci, S->parent, S->s, S->w);
    for (; top < n; top++) count[S->s[top]]++;
  }
  S->Lp = malloc((n + 1) * sizeof(int)); S->Lp[0] = 0;
  for (int i = 0; i < n; i++) S->Lp[i + 1] = S->Lp[i] + count[i];
  free(count);
  S->Li = malloc((S->Lp[n] > 0 ? S->Lp[n] : 1) * sizeof(int));
  S->Lx = malloc((S->Lp[n] > 0 ? S->Lp[n] : 1) * sizeof(double));
  return S;
}
PK_HOT long pk_chol_lnnz(const chol_t *S) { return S ? S->Lp[S->n] : 0; }
void pk_chol_free(chol_t *S) {
  if (!S) return;
  free(S->pinv); free(S->perm); free(S->Cp); free(S->Ci); free(S->Cx); free(S->diagp);
  free(S->off); free(S->map); free(S->parent); free(S->Lp); free(S->Li); free(S->Lx);
  free(S->x); free(S->cwork); free(S->s); free(S->w); free(S);
}

/* numeric: refill Cx from cv (pattern fixed), then up-looking Cholesky.
 * Returns 0 on success. d≤0 (roundoff on a near-singular direction) is floored. */
PK_HOT int pk_chol_factor(chol_t *S, int nt, const int *ptr, const int *idx,
                   const double *val, const double *cv, double ridge) {
  int n = S->n; const int *Cp = S->Cp, *Ci = S->Ci; double *Cx = S->Cx;
  memset(Cx, 0, S->Cnnz * sizeof(double));
  for (int j = 0; j < n; j++) Cx[S->diagp[j]] = ridge;
  int maxdeg = S->maxdeg;
  for (int ti = 0; ti < nt; ti++) {
    double c = cv[ti];
    int lo = ptr[ti], hi = ptr[ti + 1];
    if (c == 0.0) continue;
    if (maxdeg > 0 && hi - lo > maxdeg) continue;            /* excluded form */
    long k = S->off[ti];
    for (int x = lo; x < hi; x++) for (int y = lo; y <= x; y++) {
      if (S->map[k] >= 0) Cx[S->map[k]] += c * val[x] * val[y];
      k++;
    }
  }
  /* up-looking Cholesky (CSparse cs_chol): diagonal stored at Lp[j], first */
  int *Lp = S->Lp, *Li = S->Li; double *Lx = S->Lx;
  int *cwork = S->cwork, *s = S->s, *w = S->w; double *x = S->x;
  double maxd = ridge; for (int j = 0; j < n; j++) if (Cx[S->diagp[j]] > maxd) maxd = Cx[S->diagp[j]];
  double floorv = 1e-12 * maxd;
  for (int i = 0; i < n; i++) { w[i] = -1; cwork[i] = Lp[i]; x[i] = 0.0; }
  for (int k = 0; k < n; k++) {
    int top = chol_ereach(n, k, Cp, Ci, S->parent, s, w);
    for (int p = Cp[k]; p < Cp[k + 1]; p++) if (Ci[p] <= k) x[Ci[p]] = Cx[p];
    double d = x[k]; x[k] = 0.0;
    for (; top < n; top++) {
      int i = s[top];
      double lki = x[i] / Lx[Lp[i]];          /* Lp[i] = L(i,i) */
      x[i] = 0.0;
      for (int p = Lp[i] + 1; p < cwork[i]; p++) x[Li[p]] -= Lx[p] * lki;
      d -= lki * lki;
      int p = cwork[i]++; Li[p] = k; Lx[p] = lki;
    }
    if (d < floorv) d = floorv;
    int p = cwork[k]++; Li[p] = k; Lx[p] = sqrt(d);
  }
  return 0;
}
/* solve H d = b via the factor: permute, forward L, back Lᵀ, unpermute. */
PK_HOT void pk_chol_solve(chol_t *S, const double *b, double *out) {
  int n = S->n, *Lp = S->Lp, *Li = S->Li; double *Lx = S->Lx;
  int *pinv = S->pinv; double *y = S->x;            /* reuse x as the rhs/work */
  for (int i = 0; i < n; i++) y[pinv ? pinv[i] : i] = b[i];
  for (int j = 0; j < n; j++) {                     /* forward L y = Pb */
    y[j] /= Lx[Lp[j]];
    for (int p = Lp[j] + 1; p < Lp[j + 1]; p++) y[Li[p]] -= Lx[p] * y[j];
  }
  for (int j = n - 1; j >= 0; j--) {                /* back Lᵀ y = y */
    double tt = y[j];
    for (int p = Lp[j] + 1; p < Lp[j + 1]; p++) tt -= Lx[p] * y[Li[p]];
    y[j] = tt / Lx[Lp[j]];
  }
  for (int i = 0; i < n; i++) out[i] = y[pinv ? pinv[i] : i];
}

/* Cholesky-preconditioned CG: solve the FULL H d = b, where H includes the dense
 * local-resource terms (labour caps) via matrix-free hv, but the preconditioner
 * M = chol factor of the SPARSE SKELETON only (S built with maxdeg). The factor
 * captures the inter-cell storage/transport coupling exactly (the part that made
 * Jacobi-CG churn to ~290 iters); CG then needs only a handful of iterations to
 * absorb the few dense rank-1 cliques. S already factored at the current cv. */
PK_HOT int pk_pcg_chol(chol_t *S, int nt, int n, const int *ptr, const int *idx,
                const double *val, const double *cv, const double *b,
                double ridge, int maxit,
                double *x, double *r, double *z, double *p, double *Hp) {
  for (int i = 0; i < n; i++) { x[i] = 0.0; r[i] = b[i]; }
  pk_chol_solve(S, r, z);
  for (int i = 0; i < n; i++) p[i] = z[i];
  double rz = 0.0; for (int i = 0; i < n; i++) rz += r[i] * z[i];
  int cap = n + 2; if (maxit < cap) cap = maxit;
  int its = 0;
  for (int k = 0; k < cap; k++) {
    double rr = 0.0; for (int i = 0; i < n; i++) rr += r[i] * r[i];
    if (rr < 1e-14) break;
    hv(nt, n, ptr, idx, val, cv, p, ridge, Hp);
    double pHp = 0.0; for (int i = 0; i < n; i++) pHp += p[i] * Hp[i];
    double al = rz / (pHp > 1e-30 ? pHp : 1e-30);
    its++;
    for (int i = 0; i < n; i++) { x[i] += al * p[i]; r[i] -= al * Hp[i]; }
    pk_chol_solve(S, r, z);
    double rz2 = 0.0; for (int i = 0; i < n; i++) rz2 += r[i] * z[i];
    double beta = rz2 / rz;
    for (int i = 0; i < n; i++) p[i] = z[i] + beta * p[i];
    rz = rz2;
  }
  return its;
}

/* diagonally-preconditioned CG: solve H d = b. x_out preallocated (n), scratch
 * arrays (r,z,p,Hp each n) supplied by caller to avoid per-call malloc. Returns
 * iterations. Mirrors §2 pcg: cap min(300,n+2), stop when ‖r‖² < 1e-14. */
PK_HOT int pk_pcg(int nt, int n, const int *ptr, const int *idx, const double *val,
           const double *cv, const double *b, const double *diag,
           double ridge, int maxit,
           double *x, double *r, double *z, double *p, double *Hp) {
  for (int i = 0; i < n; i++) { x[i] = 0.0; r[i] = b[i]; z[i] = r[i] / diag[i]; p[i] = z[i]; }
  double rz = 0.0; for (int i = 0; i < n; i++) rz += r[i] * z[i];
  int cap = n + 2; if (maxit < cap) cap = maxit;
  int its = 0;
  for (int k = 0; k < cap; k++) {
    double rr = 0.0; for (int i = 0; i < n; i++) rr += r[i] * r[i];
    if (rr < 1e-14) break;
    hv(nt, n, ptr, idx, val, cv, p, ridge, Hp);
    double pHp = 0.0; for (int i = 0; i < n; i++) pHp += p[i] * Hp[i];
    double al = rz / (pHp > 1e-30 ? pHp : 1e-30);
    its++;
    for (int i = 0; i < n; i++) { x[i] += al * p[i]; r[i] -= al * Hp[i]; }
    double rz2 = 0.0; for (int i = 0; i < n; i++) { z[i] = r[i] / diag[i]; rz2 += r[i] * z[i]; }
    double beta = rz2 / rz;
    for (int i = 0; i < n; i++) p[i] = z[i] + beta * p[i];
    rz = rz2;
  }
  return its;
}

/* pk_solve_pd with the sparse Cholesky preconditioner S (pk_chol_symbolic, built once
 * on the program's pattern by the caller; freed by the caller). See pd_core. */
PK_HOT int pk_solve_pd_chol(chol_t *S, int nt, int n, int nlab, const int *ptr, const int *idx, const double *val,
                const int *kind, const double *cnst, const double *D, const double *w,
                const int *lab_idx, const double *lab_val, double kappa, double ridge,
                double tol, int maxit, double *x, double *mu_out, double *y_out) {
  return pd_core(S, nt, n, nlab, ptr, idx, val, kind, cnst, D, w, lab_idx, lab_val,
                 kappa, ridge, tol, maxit, 0, x, mu_out, y_out);
}
