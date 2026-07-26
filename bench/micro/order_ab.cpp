// The second serial phase: materialising the map into a vector and sorting D pairs (the `order`
// timer in iqr_cpu_flags_groupby). Is it also a bottleneck once the merge is fixed?
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <execution>
#include <random>
#include <unordered_map>
#include <vector>
using clk = std::chrono::steady_clock;
static double ms(clk::time_point t){return std::chrono::duration<double,std::milli>(clk::now()-t).count();}
int main(int argc,char**argv){
    size_t D = argc>1?std::strtoull(argv[1],nullptr,10):1351462;
    std::unordered_map<int64_t,uint64_t> all;
    all.reserve(D*2);
    std::mt19937_64 rng(7);
    for(size_t i=0;i<D;i++) all[90091+(int64_t)(rng()%D)*7] = 1+rng()%50;
    std::printf("D = %zu (map size %zu)\n", D, all.size());

    auto t0=clk::now();
    std::vector<std::pair<int64_t,uint64_t>> ord(all.begin(), all.end());
    double mat=ms(t0);

    auto t1=clk::now();
    std::sort(ord.begin(), ord.end(), [](auto&a,auto&b){return a.first<b.first;});
    double srt=ms(t1);

    auto t2=clk::now();
    uint64_t cc=0; for(auto&e:ord) cc+=e.second;
    double scan=ms(t2);

    std::printf("  materialise map -> vector  %8.1f ms   (D random reads over a node-based map)\n", mat);
    std::printf("  std::sort (SERIAL)         %8.1f ms\n", srt);
    std::printf("  cumulative scan            %8.1f ms\n", scan);
    std::printf("  order total                %8.1f ms   (checksum %llu)\n", mat+srt+scan,(unsigned long long)cc);
    return 0;
}
