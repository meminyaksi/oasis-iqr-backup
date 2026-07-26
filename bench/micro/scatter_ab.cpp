// RESULTS.md 9.31: the radix scatter is ~9x off memory bandwidth. Why, and what fixes it.
// A = current (256 partitions, direct stores)   B = fewer partitions   C = software write-combining
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <thread>
#include <vector>
using U = uint64_t; using clk = std::chrono::steady_clock;
static double ms(clk::time_point t){return std::chrono::duration<double,std::milli>(clk::now()-t).count();}
template<class F> static void par(size_t n,size_t nt,F&&fn){size_t c=(n+nt-1)/nt;
  std::vector<std::thread> w; for(size_t t=0;t<nt;t++){size_t a=t*c; if(a>=n)break;
  w.emplace_back([&fn,t,a,b=std::min(n,a+c)]{fn(t,a,b);});} for(auto&x:w)x.join();}
static double med(std::vector<double> x){std::sort(x.begin(),x.end());return x[x.size()/2];}
static inline size_t H(U x){uint64_t h=x*0x9E3779B97F4A7C15ull;return (size_t)(h^(h>>29));}

// shared: counts + offsets
static void offsets(const int64_t*v,size_t n,size_t nt,size_t P,
                    std::vector<size_t>&ps,std::vector<std::vector<size_t>>&off){
    std::vector<std::vector<size_t>> cnt(nt,std::vector<size_t>(P,0));
    par(n,nt,[&](size_t t,size_t a,size_t b){auto&c=cnt[t];for(size_t i=a;i<b;i++)c[H((U)v[i])&(P-1)]++;});
    ps.assign(P+1,0);
    for(size_t p=0;p<P;p++){size_t s=0;for(size_t t=0;t<nt;t++)s+=cnt[t][p];ps[p+1]=ps[p]+s;}
    off.assign(nt,std::vector<size_t>(P,0));
    for(size_t p=0;p<P;p++){size_t r=ps[p];for(size_t t=0;t<nt;t++){off[t][p]=r;r+=cnt[t][p];}}
}
int main(int argc,char**argv){
    size_t n=argc>1?std::strtoull(argv[1],nullptr,10):59986052;
    size_t nt=argc>2?std::strtoull(argv[2],nullptr,10):32;
    int reps=argc>3?std::atoi(argv[3]):5;
    size_t D=1351462;
    std::vector<int64_t> v(n);
    par(n,std::thread::hardware_concurrency(),[&](size_t t,size_t a,size_t b){
        std::mt19937_64 r(9+t); for(size_t i=a;i<b;i++) v[i]=90091+(int64_t)(r()%D)*7;});
    std::vector<int64_t> buf(n);
    const double MB=n*8.0/1e6;
    std::printf("n=%zu (%.0f MB moved per pass)  threads=%zu\n\n",n,MB,nt);
    std::printf("%-46s %9s %11s\n","scatter variant","ms","eff GB/s");

    for(size_t P : {256ul, 64ul, 16ul}){
        std::vector<size_t> ps; std::vector<std::vector<size_t>> off;
        offsets(v.data(),n,nt,P,ps,off);
        std::vector<double> ts;
        for(int r=0;r<reps;r++) ts.push_back(ms(clk::now())*0+[&]{auto t0=clk::now();
            par(n,nt,[&](size_t t,size_t a,size_t b){auto L=off[t];
                for(size_t i=a;i<b;i++) buf[L[H((U)v[i])&(P-1)]++]=v[i];});
            return ms(t0);}());
        char lab[64]; std::snprintf(lab,sizeof lab,"A/B direct stores, P=%zu",P);
        std::printf("%-46s %9.1f %11.1f\n",lab,med(ts),3*MB/med(ts));
    }
    // C: software write-combining -- stage 8 values per partition, flush a full 64B line
    for(size_t P : {256ul, 64ul}){
        std::vector<size_t> ps; std::vector<std::vector<size_t>> off;
        offsets(v.data(),n,nt,P,ps,off);
        std::vector<double> ts;
        for(int r=0;r<reps;r++){auto t0=clk::now();
            par(n,nt,[&](size_t t,size_t a,size_t b){
                auto L=off[t];
                std::vector<int64_t> wc(P*8); std::vector<uint8_t> fill(P,0);
                for(size_t i=a;i<b;i++){size_t p=H((U)v[i])&(P-1);
                    wc[p*8+fill[p]]=v[i];
                    if(++fill[p]==8){std::memcpy(&buf[L[p]],&wc[p*8],64);L[p]+=8;fill[p]=0;}}
                for(size_t p=0;p<P;p++) for(uint8_t k=0;k<fill[p];k++) buf[L[p]++]=wc[p*8+k];});
            ts.push_back(ms(t0));}
        char lab[64]; std::snprintf(lab,sizeof lab,"C write-combining (8/line), P=%zu",P);
        std::printf("%-46s %9.1f %11.1f\n",lab,med(ts),3*MB/med(ts));
    }
    return 0;
}
