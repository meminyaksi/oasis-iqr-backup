// RESULTS.md 9.32: ParallelRanges spawns and joins fresh std::threads on EVERY call. The groupby path
// calls it 4x per query (count, scatter, aggregate, flags). How much is that worth, and what does a
// persistent pool recover? Dataset-size independent, so it hurts the SMALL datasets most.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>
using clk = std::chrono::steady_clock;
static double ms(clk::time_point t){return std::chrono::duration<double,std::milli>(clk::now()-t).count();}
static double med(std::vector<double> x){std::sort(x.begin(),x.end());return x[x.size()/2];}

// --- A: what ships -- spawn + join per call
template <class F> static void spawn_ranges(size_t n,size_t nt,F&&fn){
    if(!n)return; if(nt<=1){fn(0,0,n);return;}
    size_t c=(n+nt-1)/nt; std::vector<std::thread> w; w.reserve(nt);
    for(size_t t=0;t<nt;t++){size_t a=t*c; if(a>=n)break;
        w.emplace_back([&fn,t,a,b=std::min(n,a+c)]{fn(t,a,b);});}
    for(auto&x:w)x.join();
}

// --- B: a persistent pool, started once
struct Pool {
    std::vector<std::thread> th; std::mutex m; std::condition_variable cv, done_cv;
    std::function<void(size_t,size_t,size_t)> job; size_t n=0, nt=0, gen=0, finished=0;
    bool stop=false;
    explicit Pool(size_t k){ nt=k; for(size_t i=0;i<k;i++) th.emplace_back([this,i]{worker(i);}); }
    ~Pool(){ {std::unique_lock<std::mutex> l(m); stop=true;} cv.notify_all(); for(auto&t:th)t.join(); }
    void worker(size_t id){
        size_t seen=0;
        for(;;){ std::unique_lock<std::mutex> l(m);
            cv.wait(l,[&]{return stop||gen!=seen;});
            if(stop)return; seen=gen; auto f=job; size_t N=n,K=nt; l.unlock();
            size_t c=(N+K-1)/K, a=id*c;
            if(a<N) f(id,a,std::min(N,a+c));
            l.lock(); if(++finished==K) done_cv.notify_one();
        }
    }
    void run(size_t N, std::function<void(size_t,size_t,size_t)> f){
        std::unique_lock<std::mutex> l(m);
        job=std::move(f); n=N; finished=0; ++gen;
        cv.notify_all();
        done_cv.wait(l,[&]{return finished==nt;});
    }
};

int main(int argc,char**argv){
    size_t nt=argc>1?std::strtoull(argv[1],nullptr,10):32;
    int calls=argc>2?std::atoi(argv[2]):4;      // count, scatter, aggregate, flags
    int reps=argc>3?std::atoi(argv[3]):20;
    // A tiny amount of real work per range, so we measure dispatch overhead, not the work.
    std::vector<uint64_t> sink(nt,0);
    auto work=[&](size_t t,size_t a,size_t b){ uint64_t s=0; for(size_t i=a;i<b;i++) s+=i; sink[t]+=s; };
    const size_t N=nt*64;   // trivial payload

    std::vector<double> ta, tb;
    for(int r=0;r<reps;r++){ auto t0=clk::now();
        for(int c=0;c<calls;c++) spawn_ranges(N,nt,work); ta.push_back(ms(t0)); }
    { Pool p(nt);
      for(int r=0;r<reps;r++){ auto t0=clk::now();
        for(int c=0;c<calls;c++) p.run(N,work); tb.push_back(ms(t0)); } }

    std::printf("threads=%zu  ParallelRanges calls per query=%d  (median of %d)\n\n",nt,calls,reps);
    std::printf("%-44s %9s\n","dispatch mechanism","ms/query");
    std::printf("%-44s %9.2f\n","A: spawn+join per call (as shipped)",med(ta));
    std::printf("%-44s %9.2f\n","B: persistent pool",med(tb));
    std::printf("\nsaving per query: %.2f ms  (%.1fx cheaper dispatch)\n", med(ta)-med(tb), med(ta)/med(tb));
    uint64_t k=0; for(auto s:sink)k^=s; std::printf("(checksum %llu)\n",(unsigned long long)k);
    return 0;
}
