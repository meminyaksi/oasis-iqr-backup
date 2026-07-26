// Validates the shipped IqrThreadPool + ParallelRanges: every element visited exactly once, thread
// indices in range, identical partitioning to the spawn version, and exceptions propagated (the old
// std::thread version called std::terminate instead).
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
#include "pool_core.inc"

int main() {
    bool ok = true;
    size_t cases = 0;
    // (a) coverage: every index hit exactly once, thread_idx < nthreads
    for (size_t n : {size_t(0), 1ul, 7ul, 8ul, 63ul, 64ul, 1000ul, 100000ul, 1000003ul})
        for (size_t nt : {1ul, 2ul, 3ul, 8ul, 32ul, 64ul, 100ul}) {
            std::vector<int> hits(n, 0);
            std::atomic<size_t> bad_idx{0};
            ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
                if (t >= nt) bad_idx++;
                for (size_t i = lo; i < hi; i++) hits[i]++;
            });
            for (size_t i = 0; i < n; i++) if (hits[i] != 1) {
                std::printf("FAIL coverage n=%zu nt=%zu idx=%zu hits=%d\n", n, nt, i, hits[i]); ok=false; break; }
            if (bad_idx) { std::printf("FAIL thread_idx out of range n=%zu nt=%zu\n", n, nt); ok=false; }
            cases++;
        }
    // (b) identical partitioning to the spawn version (the GROUP BY count/scatter passes depend on it)
    for (size_t n : {1000ul, 59986052ul}) for (size_t nt : {8ul, 32ul}) {
        std::vector<std::pair<size_t,size_t>> a(nt,{0,0}), b(nt,{0,0});
        ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi){ a[t]={lo,hi}; });
        { size_t c=(n+nt-1)/nt; std::vector<std::thread> w;
          for(size_t t=0;t<nt;t++){size_t lo=t*c; if(lo>=n)break;
            w.emplace_back([&,t,lo]{ b[t]={lo,std::min(n,lo+c)}; });}
          for(auto&x:w)x.join(); }
        if (a!=b){ std::printf("FAIL partitioning differs n=%zu nt=%zu\n",n,nt); ok=false; }
        cases++;
    }
    // (c) exceptions must reach the caller, not terminate
    for (size_t nt : {1ul, 32ul}) {
        bool caught=false;
        try { ParallelRanges(10000, nt, [](size_t t,size_t lo,size_t hi){
                if (t==0) throw std::runtime_error("boom"); }); }
        catch (const std::runtime_error &e) { caught = (std::string(e.what())=="boom"); }
        catch (...) {}
        if(!caught){ std::printf("FAIL exception not propagated (nt=%zu)\n",nt); ok=false; }
        cases++;
    }
    // (d) reuse: the pool must survive many sequential runs (a query does ~4, a suite thousands)
    { std::atomic<uint64_t> sum{0};
      for (int r=0;r<3000;r++) ParallelRanges(4096,32,[&](size_t,size_t lo,size_t hi){
            uint64_t s=0; for(size_t i=lo;i<hi;i++) s+=i; sum+=s; });
      const uint64_t want = uint64_t(4095)*4096/2*3000;
      if (sum != want){ std::printf("FAIL reuse: %llu vs %llu\n",(unsigned long long)sum.load(),(unsigned long long)want); ok=false; }
      cases++; }
    std::printf("%s  (%zu cases)\n", ok?"POOL OK: coverage, partitioning, exceptions, 3000x reuse":"FAILURES", cases);
    return ok?0:1;
}
