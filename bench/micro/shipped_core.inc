constexpr size_t IQR_CPU_HIST_BINS = 1u << 16;

// Histogram counter type. uint64 doubles the table footprint versus uint32 (see above) and is kept by
// preference; the merge loop widths below follow this typedef, so changing it here is sufficient.
using IqrHistCount = uint64_t;

// One "find the rank-th smallest value inside [lo,hi]" question, narrowed one histogram level at a
// time. Several of these are advanced together so that q1 and q3 share a single pass over the column.
template <class T>
struct RankQuery {
    T      lo;
    T      hi;
    size_t rank; // 0-indexed, relative to the elements currently inside [lo,hi]
    bool   done;
    T      result;
};

// Advances every unfinished query by one level in a SINGLE pass over the column. Queries whose
// ranges are identical (which is always the case on the first level, where both quartiles span
// [min,max]) share one histogram instead of building the same counts twice.
template <class T>
void AdvanceRankQueries(const T *v, size_t n, size_t nt, RankQuery<T> *q, size_t nq,
                        std::vector<std::vector<IqrHistCount>> &scratch) {
    using U                    = typename std::make_unsigned<T>::type;
    constexpr size_t MAX_ACTIVE = 4;

    size_t   active[MAX_ACTIVE];   // index into q[] of each unfinished query
    size_t   hist_of[MAX_ACTIVE];  // which histogram that query reads
    U        base[MAX_ACTIVE];
    unsigned shift[MAX_ACTIVE];
    size_t   nbins[MAX_ACTIVE];
    size_t   na = 0, nh = 0;

    for (size_t i = 0; i < nq && na < MAX_ACTIVE; i++) {
        if (q[i].done) {
            continue;
        }
        if (q[i].lo == q[i].hi) { // range collapsed to one value: that is the answer
            q[i].result = q[i].lo;
            q[i].done   = true;
            continue;
        }
        const U  b     = static_cast<U>(q[i].lo);
        const U  range = static_cast<U>(q[i].hi) - b;
        unsigned sh    = 0;
        while ((range >> sh) >= IQR_CPU_HIST_BINS) {
            sh++;
        }
        // Share a histogram with an earlier active query covering exactly the same range.
        size_t reuse = nh;
        for (size_t j = 0; j < na; j++) {
            if (q[active[j]].lo == q[i].lo && q[active[j]].hi == q[i].hi) {
                reuse = hist_of[j];
                break;
            }
        }
        if (reuse == nh) {
            base[nh]  = b;
            shift[nh] = sh;
            nbins[nh] = static_cast<size_t>(range >> sh) + 1;
            nh++;
        }
        hist_of[na] = reuse;
        active[na]  = i;
        na++;
    }
    if (na == 0) {
        return;
    }

    // Span of each histogram as an unsigned offset from its base. Hoisted out of the scan: unsigned
    // wrap puts any out-of-range value above the span, so membership is a single compare per element.
    U span[MAX_ACTIVE];
    for (size_t h = 0; h < nh; h++) {
        span[h] = ((static_cast<U>(nbins[h]) - 1) << shift[h]) | ((U(1) << shift[h]) - 1);
    }

    const size_t stride = IQR_CPU_HIST_BINS;
    if (scratch.size() != nt) {
        scratch.assign(nt, {});
    }
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        auto &sc = scratch[t];
        if (sc.size() < stride * nh) {
            sc.assign(stride * nh, 0);
        } else {
            std::fill(sc.begin(), sc.begin() + stride * nh, 0);
        }
        IqrHistCount *sp = sc.data();
        if (nh == 1) {
            // The first level always lands here (both quartiles share [min,max]). Keeping it a flat
            // loop over scalars, with nothing indexed by a loop variable, is worth a lot to the
            // vectorizer compared with the general path below.
            const U        b0 = base[0], s0 = span[0];
            const unsigned k0 = shift[0];
            for (size_t i = lo; i < hi; i++) {
                const U off = static_cast<U>(v[i]) - b0;
                if (off <= s0) {
                    sp[static_cast<size_t>(off >> k0)]++;
                }
            }
            return;
        }
        for (size_t i = lo; i < hi; i++) {
            const T x = v[i];
            for (size_t h = 0; h < nh; h++) {
                const U off = static_cast<U>(x) - base[h];
                if (off <= span[h]) {
                    sp[h * stride + static_cast<size_t>(off >> shift[h])]++;
                }
            }
        }
    });

    for (size_t j = 0; j < na; j++) {
        RankQuery<T> &qq = q[active[j]];
        const size_t  h  = hist_of[j];

        uint64_t cum = 0, before = 0;
        size_t   chosen = nbins[h] - 1;
        bool     found  = false;
        for (size_t b = 0; b < nbins[h]; b++) {
            uint64_t c = 0;
            for (size_t t = 0; t < nt; t++) {
                const auto &sc = scratch[t];
                if (sc.size() >= stride * nh) {
                    c += sc[h * stride + b];
                }
            }
            if (cum + c > qq.rank) {
                chosen = b;
                before = cum;
                found  = true;
                break;
            }
            cum += c;
        }
        if (!found) {
            before = cum; // rank past the end: clamp into the last bin
        }
        qq.rank -= static_cast<size_t>(before);

        const T nlo = static_cast<T>(base[h] + (static_cast<U>(chosen) << shift[h]));
        if (shift[h] == 0) {
            qq.result = nlo; // one distinct value per bin -- exact
            qq.done   = true;
            continue;
        }
        T nhi = static_cast<T>(base[h] + ((static_cast<U>(chosen + 1) << shift[h]) - 1));
        if (nhi > qq.hi) {
            nhi = qq.hi;
        }
        qq.lo = nlo;
        qq.hi = nhi;
    }
}

// Exact order statistics k1 and k3 (both 0-indexed) by iterative histogram narrowing, with both
// quartiles advanced in the same pass. No sort, no candidate materialization, O(N) per level and at
// most a handful of levels (every dataset here needs two).
template <class T>
void SelectQuartiles(const T *v, size_t n, size_t k1, size_t k3, size_t nt, T &q1, T &q3) {
    T vmin, vmax;
    ParallelMinMax<T>(v, n, nt, vmin, vmax);
    if (vmin == vmax) {
        q1 = q3 = vmin; // constant column: every order statistic is that value
        return;
    }

    RankQuery<T> q[2] = {{vmin, vmax, k1, false, T {}}, {vmin, vmax, k3, false, T {}}};
    std::vector<std::vector<IqrHistCount>> scratch;
    while (!q[0].done || !q[1].done) {
        AdvanceRankQueries<T>(v, n, nt, q, 2, scratch);
    }
    q1 = q[0].result;
    q3 = q[1].result;
}

