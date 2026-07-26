// Does the radix-partitioned GROUP BY produce the same q1/q3 as the serial-merge version, and as a
// brute-force sort? Mirrors the shipped logic incl. the cc*4>=t / cc*4>=3t rule.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <random>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>
using U = uint64_t;
template <class F> static void par(size_t n,size_t nt,F&&fn){ if(!n)return; size_t c=(n+nt-1)/nt;
  std::vector<std::thread> w; for(size_t t=0;t<nt;t++){size_t a=t*c; if(a>=n)break;
  w.emplace_back([&fn,t,a,b=std::min(n,a+c)]{fn(t,a,b);});} for(auto&x:w)x.join(); }

static void quart_from_pairs(std::vector<std::pair<int64_t,uint64_t>>&ord,size_t n,int64_t&q1,int64_t&q3){
    std::sort(ord.begin(),ord.end(),[](auto&a,auto&b){return a.first<b.first;});
    const uint64_t t=n; bool h1=false,h3=false; uint64_t cc=0;
    q1=q3=ord.empty()?0:ord.back().first;
    for(auto&e:ord){ cc+=e.second;
        if(!h1&&cc*4>=t){q1=e.first;h1=true;}
        if(!h3&&cc*4>=3*t){q3=e.first;h3=true;break;} }
}
static void serial_merge(const int64_t*v,size_t n,size_t nt,int64_t&q1,int64_t&q3,size_t&D){
    std::vector<std::unordered_map<int64_t,uint64_t>> parts(nt);
    par(n,nt,[&](size_t t,size_t a,size_t b){auto&m=parts[t];m.reserve(1024);for(size_t i=a;i<b;i++)m[v[i]]++;});
    std::unordered_map<int64_t,uint64_t> all=std::move(parts[0]);
    for(size_t t=1;t<nt;t++){for(auto&kv:parts[t])all[kv.first]+=kv.second;parts[t]={};}
    D=all.size(); std::vector<std::pair<int64_t,uint64_t>> ord(all.begin(),all.end());
    quart_from_pairs(ord,n,q1,q3);
}
static void radix(const int64_t*v,size_t n,size_t nt,int64_t&q1,int64_t&q3,size_t&D){
    constexpr size_t P=256,PM=P-1;
    auto h=[](U x){uint64_t z=x*0x9E3779B97F4A7C15ull;return (size_t)(z^(z>>29));};
    std::vector<std::vector<size_t>> cnt(nt,std::vector<size_t>(P,0));
    par(n,nt,[&](size_t t,size_t a,size_t b){auto&c=cnt[t];for(size_t i=a;i<b;i++)c[h((U)v[i])&PM]++;});
    std::vector<size_t> ps(P+1,0);
    for(size_t p=0;p<P;p++){size_t s=0;for(size_t t=0;t<nt;t++)s+=cnt[t][p];ps[p+1]=ps[p]+s;}
    std::vector<std::vector<size_t>> off(nt,std::vector<size_t>(P,0));
    for(size_t p=0;p<P;p++){size_t r=ps[p];for(size_t t=0;t<nt;t++){off[t][p]=r;r+=cnt[t][p];}}
    std::vector<int64_t> buf(n);
    par(n,nt,[&](size_t t,size_t a,size_t b){auto L=off[t];for(size_t i=a;i<b;i++)buf[L[h((U)v[i])&PM]++]=v[i];});
    std::vector<std::vector<std::pair<int64_t,uint64_t>>> pr(P);
    par(P,std::min(nt,P),[&](size_t,size_t pl,size_t ph){ std::unordered_map<int64_t,uint64_t> m;
        for(size_t p=pl;p<ph;p++){m.clear();m.reserve((ps[p+1]-ps[p])/4+16);
        for(size_t i=ps[p];i<ps[p+1];i++)m[buf[i]]++; pr[p].assign(m.begin(),m.end());}});
    D=0; for(auto&x:pr)D+=x.size();
    std::vector<std::pair<int64_t,uint64_t>> ord; ord.reserve(D);
    for(size_t p=0;p<P;p++){ord.insert(ord.end(),pr[p].begin(),pr[p].end());pr[p]={};}
    quart_from_pairs(ord,n,q1,q3);
}
int main(){
    std::mt19937_64 rng(31337); bool ok=true; size_t trials=0;
    for(size_t nt:{1ul,4ul,32ul}) for(int rep=0;rep<40;rep++){
        size_t n=1000+rng()%300000;
        size_t D=1+rng()%(1+rng()%50000);          // sweep cardinality from 1 to ~50k
        std::vector<int64_t> v(n);
        for(auto&x:v) x=(int64_t)(rng()%D)*((rep%3)?7:1) - (int64_t)(rep%2?1<<20:0);
        int64_t a1,a3,b1,b3; size_t D1,D2;
        serial_merge(v.data(),n,nt,a1,a3,D1);
        radix(v.data(),n,nt,b1,b3,D2);
        // brute force: exact order statistics via the same cc*4>=t rule on a full sort
        std::vector<int64_t> s=v; std::sort(s.begin(),s.end());
        std::vector<std::pair<int64_t,uint64_t>> rl;
        for(size_t i=0;i<n;){size_t j=i;while(j<n&&s[j]==s[i])j++;rl.push_back({s[i],j-i});i=j;}
        int64_t c1,c3; quart_from_pairs(rl,n,c1,c3);
        if(a1!=b1||a3!=b3||b1!=c1||b3!=c3||D1!=D2||D1!=rl.size()){
            std::printf("FAIL n=%zu nt=%zu D=%zu/%zu/%zu  serial(%ld,%ld) radix(%ld,%ld) brute(%ld,%ld)\n",
                        n,nt,D1,D2,rl.size(),(long)a1,(long)a3,(long)b1,(long)b3,(long)c1,(long)c3); ok=false; }
        trials++;
    }
    std::printf("%s  (%zu trials)\n", ok?"ALL AGREE: radix == serial-merge == brute force":"FAILURES", trials);
    return ok?0:1;
}
