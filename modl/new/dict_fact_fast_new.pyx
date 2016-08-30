# encoding: utf-8

cimport cython

import numpy as np
cimport numpy as np

from libc.stdio cimport printf
from libc.math cimport pow, ceil, floor, fmin, fmax, fabs
from posix.time cimport gettimeofday, timeval, timezone, suseconds_t

from cython.parallel import parallel, prange
from scipy.linalg.cython_blas cimport dgemm, dger, daxpy, ddot, dasum, dgemv
from scipy.linalg.cython_lapack cimport dposv

from .randomkit.random_fast cimport rk_interval, RandomStateMemoryView
from .._utils.enet_proj_fast cimport enet_projection_inplace, enet_norm

cdef char UP = 'U'
cdef char NTRANS = 'N'
cdef char TRANS = 'T'
cdef int zero = 0
cdef int one = 1
cdef double fzero = 0
cdef double fone = 1
cdef double fmone = -1

cdef double abs_max(int n, double* a) nogil:
    """np.max(np.abs(a))"""
    cdef int i
    cdef double m = fabs(a[0])
    cdef double d
    for i in range(1, n):
        d = fabs(a[i])
        if d > m:
            m = d
    return m


cdef inline double fsign(double f) nogil:
    if f == 0:
        return 0
    elif f > 0:
        return 1.0
    else:
        return -1.0

cdef double max(int n, double* a) nogil:
    """np.max(a)"""
    cdef int i
    cdef double m = a[0]
    cdef double d
    for i in range(1, n):
        d = a[i]
        if d > m:
            m = d
    return m

cpdef double get_simple_weights(long count, long batch_size,
           double learning_rate, double offset) nogil:
    cdef long i
    cdef double w = 1
    for i in range(count + 1 - batch_size, count + 1):
        w *= (1 - pow((1 + offset) / (offset + i), learning_rate))
    w = 1 - w
    return w

@cython.final
cdef class Sampler(object):
    cdef long n_features
    cdef long len_subset
    cdef long subset_sampling

    cdef long[:] feature_range
    cdef long[:] temp_subset
    cdef long lim_sup
    cdef long lim_inf

    cdef RandomStateMemoryView random_state

    def __init__(self, long n_features, long len_subset, long subset_sampling,
                 int random_state):
        self.n_features = n_features
        self.len_subset = len_subset
        self.subset_sampling = subset_sampling
        self.random_state = RandomStateMemoryView(seed=random_state)
        self.random_state.seed()

        self.feature_range = np.arange(n_features, dtype='long')
        self.temp_subset = np.zeros(len_subset, dtype='long')
        self.lim_sup = 0
        self.lim_inf = 0

        self.random_state.shuffle(self.feature_range)

    cpdef long[:] yield_subset(self):
        cdef long remainder
        if self.subset_sampling == 2:
            self.random_state.shuffle(self.feature_range)
            self.lim_inf = 0
            self.lim_sup = self.len_subset
        else:
            if self.n_features != self.len_subset:
                self.lim_inf = self.lim_sup
                remainder = self.n_features - self.lim_inf
                if remainder == 0:
                    self.random_state.shuffle(self.feature_range)
                    self.lim_inf = 0
                elif remainder < self.len_subset:
                    self.temp_subset[:remainder] = self.feature_range[:remainder]
                    self.feature_range[:remainder] = self.feature_range[self.lim_inf:]
                    self.feature_range[self.lim_inf:] = self.temp_subset[:remainder]
                    self.random_state.shuffle(self.feature_range[remainder:])
                    self.lim_inf = 0
                self.lim_sup = self.lim_inf + self.len_subset
            else:
                self.lim_inf = 0
                self.lim_sup = self.n_features
        return self.feature_range[self.lim_inf:self.lim_sup]


cdef class DictFactNew(object):

    cdef readonly long batch_size
    cdef readonly double learning_rate
    cdef readonly double offset
    cdef readonly double sample_learning_rate
    cdef readonly double reduction
    cdef readonly double alpha
    cdef readonly double l1_ratio
    cdef readonly double pen_l1_ratio
    cdef readonly double tol
    cdef readonly long solver
    cdef readonly long subset_sampling
    cdef readonly long dict_subset_sampling
    cdef readonly long weights
    cdef readonly long max_n_iter
    cdef readonly long n_samples
    cdef readonly long n_features
    cdef readonly long n_components
    cdef readonly long len_subset
    cdef readonly long verbose
    cdef readonly long n_threads

    cdef readonly double[::1, :] D
    cdef readonly double[:, ::1] code
    cdef readonly double[::1, :] A
    cdef readonly double[::1, :] B
    cdef readonly double[::1, :] G

    cdef readonly long random_seed


    cdef double[::1, :, :] G_average
    cdef double[::1, :] Dx_average

    cdef long[:] sample_counter
    cdef long[:] feature_counter
    cdef long total_counter

    cdef double[::1, :] this_X
    cdef double[::1, :] full_X
    cdef double[::1, :] D_subset

    cdef double[::1, :] Dx
    cdef double[::1, :] G_temp
    cdef double[::1, :] R
    cdef double[:] norm_temp

    cdef double[:] proj_temp
    cdef double[:, ::1] H
    cdef double[:, ::1] XtA


    cdef Sampler feature_sampler_1
    cdef Sampler feature_sampler_2
    cdef long[:] D_range

    cdef RandomStateMemoryView random_state


    def __init__(self,
                 double[:, :] dict_init,
                 long n_samples,
                 double alpha=1.0,
                 double l1_ratio=0.,
                 double pen_l1_ratio=0.,
                 double tol=1e-3,
                 # Hyper-parameters
                 double learning_rate=1.,
                 double sample_learning_rate=0.5,
                 long batch_size=1,
                 double offset=0,
                 # Reduction parameter
                 long reduction=1,
                 long solver=1,
                 long weights=1,
                 long subset_sampling=1,
                 long dict_subset_sampling=1,
                 # Dict parameter
                 # Generic parameters
                 long max_n_iter=0,
                 long random_seed=0,
                 long verbose=0,
                 long n_threads=1):
        self.n_samples = n_samples
        self.n_components = dict_init.shape[0]
        self.n_features = dict_init.shape[1]

        self.len_subset = int(ceil(self.n_features / reduction))

        self.batch_size = batch_size
        self.learning_rate = learning_rate
        self.offset = offset
        self.sample_learning_rate = sample_learning_rate

        self.reduction = reduction
        self.alpha = alpha
        self.l1_ratio = l1_ratio
        self.pen_l1_ratio = pen_l1_ratio
        self.tol = tol

        self.solver = solver
        self.subset_sampling = subset_sampling
        self.dict_subset_sampling = dict_subset_sampling
        self.weights = weights

        self.max_n_iter = max_n_iter

        self.random_seed = random_seed
        self.verbose = verbose

        self.n_threads = n_threads

        self.random_state = RandomStateMemoryView(seed=self.random_seed)
        self.random_state.seed()

        self.D = np.array(dict_init, order='F')
        self.code = np.zeros((self.n_samples, self.n_components))

        self.A = np.zeros((self.n_components, self.n_components),
                   order='F')
        self.B = np.zeros((self.n_components, self.n_features), order="F")

        if self.solver == 2:
            self.G = self.D_.dot(self.D_.T).T

        if self.solver == 3:
            self.G_average = np.zeros((self.n_components,
                                        self.n_components, self.n_samples),
                                       order="F")

        self.total_counter = 0
        self.sample_counter = np.zeros(self.n_samples, dtype='long')
        self.feature_counter = np.zeros(self.n_features, dtype='long')

        self.this_X = np.empty((self.batch_size, self.n_features),
                                    order='F')
        self.D_subset = np.empty((self.n_components, self.n_features),
                                  order='F')
        self.Dx = np.empty((self.n_components, self.batch_size),
                            order='F')
        self.G_temp = np.empty((self.n_components, self.n_components),
                                order='F')

        self.R = np.empty((self.n_components, self.n_features), order='F')
        self.norm_temp = np.zeros(self.n_components)
        self.proj_temp = np.zeros(self.n_features)

        self.H = np.empty((self.batch_size, self.n_components))
        self.XtA = np.empty((self.batch_size, self.n_components))

        self.D_range = np.arange(self.n_components, dtype='long')

        random_seed = self.random_state.randint(1000)
        self.feature_sampler_1 = Sampler(self.n_features, self.len_subset,
                                    self.subset_sampling, random_seed)
        if self.dict_subset_sampling == 2:
            random_seed = self.random_state.randint(1000)
            self.feature_sampler_2 = Sampler(self.n_features, self.len_subset,
                                        self.subset_sampling, random_seed)

    @cython.final
    cpdef partial_fit(self, double[:, ::1] X, long[:] sample_indices):
        cdef int this_n_samples = X.shape[0]
        cdef int n_batches = int(ceil(this_n_samples / self.batch_size))
        cdef int start = 0
        cdef int stop = 0
        cdef int len_batch = 0

        cdef int old_total_counter = self.total_counter
        cdef int new_verbose_iter = 0

        cdef int i, ii, jj, j

        cdef long[:] subset

        with nogil:
            for i in range(n_batches):
                if self.verbose and self.total_counter\
                        - old_total_counter >= new_verbose_iter:
                    print("Iteration %i" % self.total_counter)
                    new_verbose_iter += self.n_samples // self.verbose
                start = i * self.batch_size
                stop = start + self.batch_size
                if stop > this_n_samples:
                    stop = this_n_samples
                len_batch = stop - start

                self.total_counter += len_batch

                subset = self.feature_sampler_1.yield_subset()
                for jj in range(subset.shape[0]):
                    j = subset[jj]
                    self.feature_counter[j] += len_batch

                for ii in range(len_batch):
                    i = sample_indices[ii]
                    self.sample_counter[i] += 1
                self.update_code(subset, X[start:stop],
                                 sample_indices[start:stop])
                self.random_state.shuffle(self.D_range)

                if self.dict_subset_sampling == 2:
                    subset = self.feature_sampler_2.yield_subset()
                self.update_dict(subset)

    cdef int update_code(self, long[:] subset, double[:, ::1] X,
     long[:] sample_indices) nogil except *:
        """
        Compute code for a mini-batch and update algorithm statistics accordingly

        Parameters
        ----------
        X: masked data matrix
        this_subset: indices (loci) of masked data
        alpha: regularization parameter
        learning_rate: decrease rate in the learning sequence (in [.5, 1])
        offset: offset in the learning se   quence
        D_: Dictionary
        A_: algorithm variable
        B_: algorithm variable
        counter_: algorithm variable
        G: algorithm variable
        T: algorithm variable
        impute: Online update of Gram matrix
        D_subset : Temporary array. Holds the subdictionary
        Dx: Temporary array. Holds the codes for the mini batch
        G_temp: emporary array. Holds the Gram matrix.
        subset_mask: Holds the binary mask for visited features
        weights: Temporary array. Holds the update weights

        """
        cdef int len_batch = sample_indices.shape[0]
        cdef int len_subset = subset.shape[0]
        cdef int n_components = self.n_components
        cdef int n_samples = self.n_samples
        cdef int n_features = self.n_features
        cdef double reduction = float(self.n_features) / self.len_subset
        cdef int subset_thread_size = int(ceil(float(self.n_features)
                                               / self.n_threads))

        cdef double* D_subset_ptr = &self.D_subset[0, 0]
        cdef double* D_ptr = &self.D[0, 0]
        cdef double* A_ptr = &self.A[0, 0]
        cdef double* B_ptr = &self.B[0, 0]

        cdef double* G_ptr

        cdef double* Dx_ptr = &self.Dx[0, 0]
        cdef double* G_temp_ptr = &self.G_temp[0, 0]
        cdef double* this_X_ptr = &self.this_X[0, 0]
        cdef double* X_ptr = &X[0, 0]

        cdef int info = 0
        cdef int ii, jj, i, j, k, m, p, q
        cdef int nnz
        cdef double v
        cdef int last = 0
        cdef double one_m_w, w_sample, w_batch, w_norm, w_A, w_B
        cdef int this_subset_thread_size
        cdef double this_X_norm
        cdef timeval tv0, tv1
        cdef timezone tz
        cdef suseconds_t aggregation_time, coding_time, prepare_time

        if self.solver == 2:
             G_ptr = &self.G[0, 0]

        gettimeofday(&tv0, &tz)
        for ii in range(len_batch):
            for jj in range(self.len_subset):
                j = subset[jj]
                self.this_X[ii, jj] = X[ii, j]

        for jj in range(self.len_subset):
            j = subset[jj]
            for k in range(self.n_components):
                self.D_subset[k, jj] = self.D[k, j]
        this_X_norm = ddot(&len_subset, this_X_ptr, &one, this_X_ptr, &one) * reduction
        for jj in range(len_subset):
            for ii in range(len_batch):
                self.this_X[ii, jj] *= reduction


        # Dx = np.dot(D_subset, this_X.T)
        dgemm(&NTRANS, &TRANS,
              &n_components, &len_batch, &len_subset,
              &fone,
              D_subset_ptr, &n_components,
              this_X_ptr, &len_batch,
              &fzero,
              Dx_ptr, &n_components
              )

        if self.solver == 1:
            dgemm(&NTRANS, &TRANS,
                  &n_components, &n_components, &len_subset,
                  &reduction,
                  D_subset_ptr, &n_components,
                  D_subset_ptr, &n_components,
                  &fzero,
                  G_temp_ptr, &n_components
                  )
        else:
            for ii in range(len_batch):
                i = sample_indices[ii]
                w_sample = pow(self.sample_counter[i], -self.sample_learning_rate)
                for p in range(n_components):
                    self.Dx_average[i, p] *= 1 - w_sample
                    self.Dx_average[i, p] += self.Dx[p, ii] * w_sample
                    self.Dx[p, ii] = self.Dx_average[i, p]
            if self.solver == 3:
                dgemm(&NTRANS, &TRANS,
                      &n_components, &n_components, &len_subset,
                      &reduction,
                      D_subset_ptr, &n_components,
                      D_subset_ptr, &n_components,
                      &fzero,
                      G_temp_ptr, &n_components
                      )
                for ii in range(len_batch):
                    i = sample_indices[ii]
                    for p in range(n_components):
                        for q in range(n_components):
                            self.G_average[p, q, i] *= 1 - w_sample
                            self.G_average[p, q, i] += self.G_temp[p, q] * w_sample
            else:
                if self.pen_l1_ratio == 0:
                    for p in range(n_components):
                        for q in range(n_components):
                            self.G_temp[p, q] = self.G[p, q]
                else:
                    self.G_temp = self.G
        gettimeofday(&tv1, &tz)
        prepare_time = tv1.tv_usec - tv0.tv_usec
        gettimeofday(&tv0, &tz)
        if self.pen_l1_ratio == 0:
            if self.solver == 3:
                for ii in range(len_batch):
                    i = sample_indices[ii]
                    for p in range(n_components):
                        for q in range(n_components):
                            self.G_temp[p, q] = self.G_average[p, q, i]
                        self.G_temp[p, p] += self.alpha
                    dposv(&UP, &n_components, &len_batch, G_temp_ptr, &n_components,
                          Dx_ptr + ii * n_components, &one,
                          &info)
                    for p in range(n_components):
                        self.G_temp[p, p] -= self.alpha
                if info != 0:
                    return -1
            else:
                for p in range(n_components):
                    self.G_temp[p, p] += self.alpha
                dposv(&UP, &n_components, &len_batch, G_temp_ptr, &n_components,
                      Dx_ptr, &n_components,
                      &info)
                if info != 0:
                    return -1
            for ii in range(len_batch):
                i = sample_indices[ii]
                for k in range(n_components):
                    self.code[i, k] = self.Dx[k, ii]

        else:
            with parallel(num_threads=self.n_threads):
                for ii in prange(len_batch, schedule='static'):
                    i = sample_indices[ii]
                    enet_coordinate_descent_gram_(
                        self.code[i], self.alpha * self.pen_l1_ratio,
                                  self.alpha * (1 - self.pen_l1_ratio),
                        self.G_average[:, :, i] if self.solver == 3 else self.G_temp,
                        self.Dx[:, ii],
                        this_X_norm,
                        self.H[ii],
                        self.XtA[ii],
                        1000,
                        self.tol, self.random_state, 0, 0)
                    for p in range(n_components):
                        self.Dx[p, ii] = self.code[i, p]
        for jj in range(len_subset):
            for ii in range(len_batch):
                self.this_X[ii, jj] /= reduction
        gettimeofday(&tv1, &tz)
        coding_time = tv1.tv_usec - tv0.tv_usec

        gettimeofday(&tv0, &tz)
        w_A = get_simple_weights(self.total_counter, len_batch, self.learning_rate,
                                  self.offset)

        # Dx = this_code
        w_batch = w_A / len_batch
        one_m_w = 1 - w_A
        # A_ *= 1 - w_A
        # A_ += this_code.dot(this_code.T) * w_A / batch_size
        dgemm(&NTRANS, &TRANS,
              &n_components, &n_components, &len_batch,
              &w_batch,
              Dx_ptr, &n_components,
              Dx_ptr, &n_components,
              &one_m_w,
              A_ptr, &n_components
              )
        if self.weights == 1:
            with parallel(num_threads=self.n_threads):
                for ii in prange(0, n_features, subset_thread_size,
                                 schedule='static'):
                    if n_features - ii < subset_thread_size:
                        this_subset_thread_size = n_features - ii
                    else:
                        this_subset_thread_size = subset_thread_size
                    dgemm(&NTRANS, &NTRANS,
                          &n_components, &this_subset_thread_size, &len_batch,
                          &w_batch,
                          Dx_ptr, &n_components,
                          X_ptr + ii * len_batch, &len_batch,
                          &one_m_w,
                          B_ptr + ii * n_components, &n_components)
        else:
            # B += this_X.T.dot(P[row_batch]) * {w_B} / batch_size
            # Reuse D_subset as B_subset
            for jj in range(len_subset):
                j = subset[jj]
                if self.weights == 2:
                    w_B = fmin(1., w_A
                               * float(self.total_counter)
                               / self.feature_counter[j])
                else:
                    w_B = fmin(1, w_A * reduction)
                for k in range(n_components):
                    self.D_subset[k, jj] = self.B[k, j] * (1. - w_B)
                for ii in range(len_batch):
                    self.this_X[ii, jj] *= w_B / len_batch
            dgemm(&NTRANS, &NTRANS,
                  &n_components, &len_subset, &len_batch,
                  &fone,
                  Dx_ptr, &n_components,
                  this_X_ptr, &len_batch,
                  &fone,
                  D_subset_ptr, &n_components)
            for jj in range(len_subset):
                j = subset[jj]
                for k in range(n_components):
                    self.B[k, j] = self.D_subset[k, jj]
        gettimeofday(&tv1, &tz)
        aggregation_time = tv1.tv_usec - tv0.tv_usec
        printf('Prepare time %i us, coding time %i us,'
               ' aggregation time %i us\n',
               prepare_time, coding_time, aggregation_time)
        return 0

    cdef void update_dict(self,
                      long[:] subset) nogil except *:
        cdef int len_subset = subset.shape[0]
        cdef int n_components = self.D.shape[0]
        cdef int n_cols = self.D.shape[1]
        cdef double* D_ptr = &self.D[0, 0]
        cdef double* D_subset_ptr = &self.D_subset[0, 0]
        cdef double* A_ptr = &self.A[0, 0]
        cdef double* R_ptr = &self.R[0, 0]
        cdef double* G_ptr
        cdef double old_norm = 0
        cdef unsigned long k, kk, j, jj

        cdef timeval tv0, tv1
        cdef timezone tz
        cdef suseconds_t gram_time, bcd_time

        if self.solver == 2:
             G_ptr = &self.G[0, 0]

        for k in range(n_components):
            for jj in range(len_subset):
                j = subset[jj]
                self.D_subset[k, jj] = self.D[k, j]
                self.R[k, jj] = self.B[k, j]

        gettimeofday(&tv0, &tz)
        for kk in range(self.n_components):
            k = self.D_range[kk]
            self.norm_temp[k] = enet_norm(self.D_subset[k, :len_subset], self.l1_ratio)
        if self.solver == 2:
            dgemm(&NTRANS, &TRANS,
                  &n_components, &n_components, &len_subset,
                  &fmone,
                  D_subset_ptr, &n_components,
                  D_subset_ptr, &n_components,
                  &fone,
                  G_ptr, &n_components
                  )
        gettimeofday(&tv1, &tz)
        gram_time = tv1.tv_usec - tv0.tv_usec

        gettimeofday(&tv0, &tz)

        # R = B - AQ
        dgemm(&NTRANS, &NTRANS,
              &n_components, &len_subset, &n_components,
              &fmone,
              A_ptr, &n_components,
              D_subset_ptr, &n_components,
              &fone,
              R_ptr, &n_components)

        for kk in range(self.n_components):
            k = self.D_range[kk]
            dger(&n_components, &len_subset, &fone,
                 A_ptr + k * n_components,
                 &one, D_subset_ptr + k, &n_components, R_ptr, &n_components)

            for jj in range(len_subset):
                if self.A[k, k] > 1e-20:
                    self.D_subset[k, jj] = self.R[k, jj] / self.A[k, k]
                    # print(D_subset[k, jj])

            enet_projection_inplace(self.D_subset[k, :len_subset],
                                    self.proj_temp[:len_subset],
                                    self.norm_temp[k], self.l1_ratio)
            for jj in range(len_subset):
                self.D_subset[k, jj] = self.proj_temp[jj]
            # R -= A[:, k] Q[:, k].T
            dger(&n_components, &len_subset, &fmone,
                 A_ptr + k * n_components,
                 &one, D_subset_ptr + k, &n_components, R_ptr, &n_components)

        for jj in range(len_subset):
            j = subset[jj]
            for kk in range(n_components):
                self.D[kk, j] = self.D_subset[kk, jj]
        gettimeofday(&tv1, &tz)
        bcd_time = tv1.tv_usec - tv0.tv_usec

        gettimeofday(&tv0, &tz)

        if self.solver == 2:
            dgemm(&NTRANS, &TRANS,
                  &n_components, &n_components, &len_subset,
                  &fone,
                  D_subset_ptr, &n_components,
                  D_subset_ptr, &n_components,
                  &fone,
                  G_ptr, &n_components
                  )
        gettimeofday(&tv1, &tz)
        gram_time += tv1.tv_usec - tv0.tv_usec

        printf('Gram time %i us, BCD time %i us\n', gram_time, bcd_time)

    @cython.final
    cpdef double[:, ::1] transform(self, double[:, ::1] X):
        cdef int n_samples = X.shape[0]
        cdef int i
        cdef double X_norm
        cdef double * X_ptr = &X[0, 0]

        cdef double[:, ::1] code = np.empty((n_samples, self.n_components))

        cdef double[:, ::1] H = np.empty((n_samples, self.n_components))
        cdef double[:, ::1] XtA = np.empty((n_samples, self.n_components))

        with nogil, parallel(num_threads=self.n_threads):
            for i in prange(n_samples, schedule='static'):
                X_norm = ddot(&n_samples, X_ptr + i * n_samples,
                              &one, X_ptr +  + i * n_samples, &one)
                with gil:
                    enet_coordinate_descent_gram_(
                                self.code[i], self.alpha * self.l1_ratio,
                                            self.alpha * (1 - self.l1_ratio),
                                self.G, self.Dx[:, i], X_norm,
                                H[i],
                                XtA[i],
                                1000,
                                self.tol, self.random_state, 0, 0)
        return code

cdef void enet_coordinate_descent_gram_(double[:] w, double alpha, double beta,
                                 double[::1, :] Q,
                                 double[:] q,
                                 double y_norm2,
                                 double[:] H,
                                 double[:] XtA,
                                 int max_iter, double tol,
                                 RandomStateMemoryView random_state,
                                 bint random, bint positive):
    """Cython version of the coordinate descent algorithm
        for Elastic-Net regression

        We minimize

        (1/2) * w^T Q w - q^T w + alpha norm(w, 1) + (beta/2) * norm(w, 2)^2

        which amount to the Elastic-Net problem when:
        Q = X^T X (Gram matrix)
        q = X^T y
    """

    # get the data information into easy vars
    cdef int n_features = Q.shape[0]

    # initial value "Q w" which will be kept of up to date in the iterations
    # cdef double[:] XtA = np.zeros(n_features)
    # cdef double[:] H = np.dot(Q, w)

    cdef double tmp
    cdef double w_ii
    cdef double mw_ii
    cdef double d_w_max
    cdef double w_max
    cdef double d_w_ii
    cdef double gap = tol + 1.0
    cdef double d_w_tol = tol
    cdef double dual_norm_XtA
    cdef unsigned int ii
    cdef unsigned int n_iter = 0
    cdef unsigned int f_iter

    cdef double* w_ptr = &w[0]
    cdef double* Q_ptr = &Q[0, 0]
    cdef double* q_ptr = &q[0]
    cdef double* H_ptr = &H[0]
    cdef double* XtA_ptr = &XtA[0]
    cdef double w_norm2
    cdef double const
    cdef double q_dot_w

    tol = tol * y_norm2

    dgemv(&NTRANS,
          &n_features, &n_features,
          &fone,
          Q_ptr, &n_features,
          w_ptr, &one,
          &fzero,
          H_ptr, &one
          )

    for n_iter in range(max_iter):
        w_max = 0.0
        d_w_max = 0.0
        for f_iter in range(n_features):  # Loop over coordinates
            if random:
                ii = random_state.randint(n_features)
            else:
                ii = f_iter

            if Q[ii, ii] == 0.0:
                continue

            w_ii = w[ii]  # Store previous value

            if w_ii != 0.0:
                # H -= w_ii * Q[ii]
                mw_ii = -w_ii
                daxpy(&n_features, &mw_ii, Q_ptr + ii * n_features, &one,
                      H_ptr, &one)

            tmp = q[ii] - H[ii]

            if positive and tmp < 0:
                w[ii] = 0.0
            else:
                w[ii] = fsign(tmp) * fmax(fabs(tmp) - alpha, 0) \
                        / (Q[ii, ii] + beta)

            if w[ii] != 0.0:
                # H +=  w[ii] * Q[ii] # Update H = X.T X w
                daxpy(&n_features, &w[ii], Q_ptr + ii * n_features, &one,
                      H_ptr, &one)

            # update the maximum absolute coefficient update
            d_w_ii = fabs(w[ii] - w_ii)
            if d_w_ii > d_w_max:
                d_w_max = d_w_ii

            if fabs(w[ii]) > w_max:
                w_max = fabs(w[ii])

        if w_max == 0.0 or d_w_max / w_max < d_w_tol or n_iter == max_iter - 1:
            # the biggest coordinate update of this iteration was smaller than
            # the tolerance: check the duality gap as ultimate stopping
            # criterion

            # q_dot_w = np.dot(w, q)
            q_dot_w = ddot(&n_features, w_ptr, &one, q_ptr, &one)

            for ii in range(n_features):
                XtA[ii] = q[ii] - H[ii] - beta * w[ii]
            if positive:
                dual_norm_XtA = max(n_features, XtA_ptr)
            else:
                dual_norm_XtA = abs_max(n_features, XtA_ptr)

            # temp = np.sum(w * H)
            tmp = 0.0
            for ii in range(n_features):
                tmp += w[ii] * H[ii]
            R_norm2 = y_norm2 + tmp - 2.0 * q_dot_w

            # w_norm2 = np.dot(w, w)
            w_norm2 = ddot(&n_features, &w[0], &one, &w[0], &one)

            if dual_norm_XtA > alpha:
                const = alpha / dual_norm_XtA
                A_norm2 = R_norm2 * (const ** 2)
                gap = 0.5 * (R_norm2 + A_norm2)
            else:
                const = 1.0
                gap = R_norm2

            # The call to dasum is equivalent to the L1 norm of w
            gap += (alpha * dasum(&n_features, &w[0], &one) -
                    const * y_norm2 +  const * q_dot_w +
                    0.5 * beta * (1 + const ** 2) * w_norm2)

            if gap < tol:
                # return if we reached desired tolerance
                break

    # return w, gap, tol, n_iter + 1