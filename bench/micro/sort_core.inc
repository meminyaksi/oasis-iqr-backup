// A persistent worker pool behind ParallelRanges.
//
// Why: the CPU operators call ParallelRanges several times per query (min/max, each histogram level,
// the flag mask; or count, scatter, aggregate, flags on the GROUP BY path) and the original version
// created and joined 32 fresh std::threads EVERY call. Measured at 32 threads with 4 calls per query
// (bench/micro/threads_ab.cpp): **4.95 ms of pure dispatch, vs 0.61 ms with a pool -- 4.34 ms saved
// per query, independent of dataset size.** That is ~20 % of taxi_d1's operator and ~3 % of sf10's,
// so it matters most on the small datasets. RESULTS.md 9.32.
//
// Also fixes a latent crash: callers throw from inside the parallel region (ReadColumnCpu raises on a
// short read), and an exception escaping a std::thread lambda calls std::terminate. The pool captures
// the first exception and rethrows it on the caller's thread.
class IqrThreadPool {
public:
    static IqrThreadPool &Get() {
        static IqrThreadPool pool;
        return pool;
    }

    // Runs body(worker_id, worker_count) on every pooled thread. The CALLER is responsible for
    // mapping its logical ranges onto worker_count workers -- see ParallelRanges, which strides. Do
    // NOT assume worker_count equals the caller's requested thread count; it is the pool size.
    //
    // Returns false if the pool is already in use (a nested or concurrent call), so the caller can
    // fall back to spawning. Keeps this non-reentrant pool safe without serialising queries.
    bool TryRun(const std::function<void(size_t, size_t)> &body) {
        std::unique_lock<std::mutex> gate(run_mutex_, std::try_to_lock);
        if (!gate.owns_lock()) {
            return false;
        }
        {
            std::lock_guard<std::mutex> l(m_);
            body_   = &body;
            err_    = nullptr;
            pending_ = workers_.size();
            gen_++;
        }
        cv_.notify_all();
        {
            std::unique_lock<std::mutex> l(m_);
            done_cv_.wait(l, [this] { return pending_ == 0; });
            body_ = nullptr;
            if (err_) {
                auto e = err_;
                err_   = nullptr;
                std::rethrow_exception(e);
            }
        }
        return true;
    }

    size_t size() const { return workers_.size(); }

private:
    IqrThreadPool() {
        const size_t k = std::max<unsigned>(1, std::thread::hardware_concurrency());
        workers_.reserve(k);
        for (size_t i = 0; i < k; i++) {
            workers_.emplace_back([this, i] { Worker(i); });
        }
    }
    ~IqrThreadPool() {
        {
            std::lock_guard<std::mutex> l(m_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto &w : workers_) {
            w.join();
        }
    }

    void Worker(size_t id) {
        size_t seen = 0;
        for (;;) {
            const std::function<void(size_t, size_t)> *body = nullptr;
            {
                std::unique_lock<std::mutex> l(m_);
                cv_.wait(l, [&] { return stop_ || gen_ != seen; });
                if (stop_) {
                    return;
                }
                seen = gen_;
                body = body_; // every worker participates; the caller strides

            }
            if (body) {
                try {
                    (*body)(id, workers_.size());
                } catch (...) {
                    std::lock_guard<std::mutex> l(m_);
                    if (!err_) {
                        err_ = std::current_exception();
                    }
                }
            }
            {
                std::lock_guard<std::mutex> l(m_);
                if (--pending_ == 0) {
                    done_cv_.notify_one();
                }
            }
        }
    }

    std::vector<std::thread>           workers_;
    std::mutex                         m_, run_mutex_;
    std::condition_variable            cv_, done_cv_;
    const std::function<void(size_t, size_t)> *body_ = nullptr;
    std::exception_ptr                         err_;
    size_t                                     gen_ = 0, pending_ = 0;
    bool                               stop_ = false;
};

// Splits [0, n) into at most `nthreads` contiguous ranges and runs fn(thread_idx, lo, hi) on each.
// thread_idx is always < nthreads, so callers can index per-thread scratch by it. The chunking is
// identical to the original spawn-per-call version, so passes that must agree on ranges (the GROUP BY
// count and scatter passes) still do.
template <class F>
void ParallelRanges(size_t n, size_t nthreads, F &&fn) {
    if (n == 0) {
        return;
    }
    if (nthreads <= 1) {
        fn(size_t(0), size_t(0), n);
        return;
    }
    const size_t chunk = (n + nthreads - 1) / nthreads;
    // Each pooled worker takes every k-th logical range, so `nthreads` may be larger OR smaller than
    // the pool. Mapping ranges 1:1 onto workers would silently DROP ranges when nthreads > pool size
    // (caught by bench/micro/pool_test.cpp: n=1000, nt=100 left elements 640.. unvisited). Distinct
    // logical ranges still get distinct `t`, so per-thread scratch indexed by `t` stays correct.
    auto body = [&](size_t id, size_t k) {
        for (size_t t = id; t < nthreads; t += k) {
            const size_t lo = t * chunk;
            if (lo >= n) {
                break; // t increasing => lo increasing, so nothing later can be in range
            }
            fn(t, lo, std::min(n, lo + chunk));
        }
    };
    if (IqrThreadPool::Get().TryRun(body)) {
        return;
    }
    // Fallback: pool busy (nested or concurrent call). Same semantics, just pays the spawn.
    std::vector<std::thread> workers;
    workers.reserve(nthreads);
    for (size_t t = 0; t < nthreads; t++) {
        size_t lo = t * chunk;
        if (lo >= n) {
            break;
        }
        size_t hi = std::min(n, lo + chunk);
        workers.emplace_back([&fn, t, lo, hi] { fn(t, lo, hi); });
    }
    for (auto &w : workers) {
        w.join();
    }
}

// Bottom-up parallel merge sort over the (value, count) pairs -- the `order` phase.
//
// This was a single-threaded std::sort and it is the dominant cost on high-cardinality columns:
// **83.64 ms of tpch_extprice's 126.14 ms operator (66 %)** at D = 933,900, and 121 ms on sf10 at
// D = 1.35 M (RESULTS.md 9.33). Low-cardinality columns are unaffected either way (tpch_qty's `order`
// is 0.02 ms at D = 50), which is why this is the fix for extprice/sf10 specifically.
//
// Bottom-up rather than a K-way merge: each round merges disjoint adjacent pairs of runs, so every
// round is embarrassingly parallel and needs no coordination. The final rounds have few pairs and so
// less parallelism -- that is inherent to merge sort and is why the expected speedup is ~5-6x, not 32x.
template <class T>
void ParallelSortPairs(std::pair<T, uint64_t> *v, size_t n, size_t nt) {
    auto cmp = [](const std::pair<T, uint64_t> &a, const std::pair<T, uint64_t> &b) {
        return a.first < b.first;
    };
    // Below this the dispatch and the scratch allocation cost more than the sort saves.
    if (n < 1u << 15 || nt <= 1) {
        std::sort(v, v + n, cmp);
        return;
    }
    const size_t runs  = std::min(nt, n / 4096);
    const size_t chunk = (n + runs - 1) / runs;
    ParallelRanges(n, runs, [&](size_t, size_t lo, size_t hi) { std::sort(v + lo, v + hi, cmp); });

    // Scratch via new[]: std::pair<integral, uint64_t> is trivially default-constructible, so this
    // does NOT initialise. A std::vector here would memset it first (9.24 step 12c, 9.31).
    std::unique_ptr<std::pair<T, uint64_t>[]> scratch(new std::pair<T, uint64_t>[n]);
    std::pair<T, uint64_t> *src = v, *dst = scratch.get();
    for (size_t width = chunk; width < n; width *= 2) {
        const size_t npairs = (n + 2 * width - 1) / (2 * width);
        ParallelRanges(npairs, std::min(nt, npairs), [&](size_t, size_t plo, size_t phi) {
            for (size_t q = plo; q < phi; q++) {
                const size_t lo  = q * 2 * width;
                if (lo >= n) {
                    break;
                }
                const size_t mid = std::min(n, lo + width);
                const size_t hi  = std::min(n, lo + 2 * width);
                std::merge(src + lo, src + mid, src + mid, src + hi, dst + lo, cmp);
            }
        });
        std::swap(src, dst);
    }
    if (src != v) {
        std::copy(src, src + n, v);
    }
}

