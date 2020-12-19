/* References:
 *
 *      Baseline
 *          Harish, Pawan, and P. J. Narayanan.
 *          "Accelerating large graph algorithms on the GPU using CUDA."
 *          International conference on high-performance computing.
 *          Springer, Berlin, Heidelberg, 2007.
 *
 *      Coalesce
 *          Hong, Sungpack, et al.
 *          "Accelerating CUDA graph algorithms at maximum warp."
 *          Acm Sigplan Notices 46.8 (2011): 267-276.
 *
 */

#include <cuda.h>
#include <fstream>
#include <stdint.h>
#include <stdio.h>
#include <iostream>
#include <string.h>
#include <getopt.h>
//#include "helper_cuda.h"
#include <algorithm>
#include <vector>
#include <numeric>
#include <iterator>
#include <math.h>
#include <chrono>
#include <ctime>
#include <ratio>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdexcept>

#include <nvm_ctrl.h>
#include <nvm_types.h>
#include <nvm_queue.h>
#include <nvm_util.h>
#include <nvm_admin.h>
#include <nvm_error.h>
#include <nvm_cmd.h>
#include <buffer.h>
#include "settings.h"
#include <ctrl.h>
#include <event.h>
#include <queue.h>
#include <nvm_parallel_queue.h>
#include <nvm_io.h>
#include <page_cache.h>
#include <util.h>

using error = std::runtime_error;
using std::string;
//const char* const ctrls_paths[] = {"/dev/libnvm0", "/dev/libnvm1", "/dev/libnvm2", "/dev/libnvm3", "/dev/libnvm4", "/dev/libnvm5", "/dev/libnvm6", "/dev/libnvm7"};
const char* const ctrls_paths[] = {"/dev/libnvm0"};

#define MYINFINITY 0xFFFFFFFF

#define WARP_SHIFT 5
#define WARP_SIZE 32

#define CHUNK_SHIFT 3
#define CHUNK_SIZE (1 << CHUNK_SHIFT)

#define BLOCK_NUM 1024ULL

typedef uint64_t EdgeT;

typedef enum {
    BASELINE = 0,
    COALESCE = 1,
    COALESCE_CHUNK = 2,
    BASELINE_PC = 3,
    COALESCE_PC = 4, 
    COALESCE_CHUNK_PC =5
} impl_type;

typedef enum {
    GPUMEM = 0,
    UVM_READONLY = 1,
    UVM_DIRECT = 2,
    UVM_READONLY_NVLINK = 3,
    UVM_DIRECT_NVLINK = 4,
    DRAGON_MAP = 5,
    BAFS_DIRECT= 6,
} mem_type;

__global__ void kernel_baseline(uint32_t *label, const uint32_t level, const uint64_t vertex_count, 
                        const uint64_t *vertexList, const EdgeT *edgeList, bool *changed, unsigned long long int *globalvisitedcount_d, unsigned long long int *vertexVisitCount_d
    ) {
    const uint64_t tid = blockDim.x * BLOCK_NUM * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;

    // if(tid==0)
    //         printf("Warning: The code is not optimal because of additional counters added for profiling\n");

    if(tid < vertex_count && label[tid] == level) {
        const uint64_t start = vertexList[tid];
        const uint64_t end = vertexList[tid+1];

        for(uint64_t i = start; i < end; i++) {
            const EdgeT next = edgeList[i];
            //performance code
            // atomicAdd(&vertexVisitCount_d[next], 1);

            if(label[next] == MYINFINITY) {
                //performance code
                // unsigned int pre_val = atomicCAS(&(label[next]),(unsigned int)MYINFINITY,(unsigned int)(level+1));
                // if(pre_val == MYINFINITY){
                //     atomicAdd(&globalvisitedcount_d[0], (unsigned long long int)(vertexList[next+1] - vertexList[next]));
                // }
                // *changed = true;

                label[next] = level + 1;
                *changed = true;
            }
        }
    }
}



__global__ void kernel_baseline_pc(array_t<uint64_t>* da, uint32_t *label, const uint32_t level, const uint64_t vertex_count,
                        const uint64_t *vertexList, const EdgeT *edgeList, bool *changed, unsigned long long int *globalvisitedcount_d, unsigned long long int *vertexVisitCount_d
    ) {
    const uint64_t tid = blockDim.x * BLOCK_NUM * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;

//    array_d_t<uint64_t> d_array = *da;
    // if(tid==0)
    //         printf("Warning: The code is not optimal because of additional counters added for profiling\n");

    if(tid < vertex_count && label[tid] == level) {
        const uint64_t start = vertexList[tid];
        const uint64_t end = vertexList[tid+1];

        for(uint64_t i = start; i < end; i++) {
            EdgeT next = da->seq_read(i);
//                printf("tid: %llu, idx: %llu next: %llu\n", (unsigned long long) tid, (unsigned long long) i, (unsigned long long) next);
            //performance code
            // atomicAdd(&vertexVisitCount_d[next], 1);

            if(label[next] == MYINFINITY) {
                //performance code
                // unsigned int pre_val = atomicCAS(&(label[next]),(unsigned int)MYINFINITY,(unsigned int)(level+1));
                // if(pre_val == MYINFINITY){
                //     atomicAdd(&globalvisitedcount_d[0], (unsigned long long int)(vertexList[next+1] - vertexList[next]));
                // }
                // *changed = true;

                label[next] = level + 1;
                *changed = true;
            }
        }
    }
}





__global__ void kernel_coalesce(uint32_t *label, const uint32_t level, const uint64_t vertex_count, const uint64_t *vertexList, const EdgeT *edgeList, bool *changed) {
    const uint64_t tid = blockDim.x * BLOCK_NUM * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;
    const uint64_t warpIdx = tid >> WARP_SHIFT;
    const uint64_t laneIdx = tid & ((1 << WARP_SHIFT) - 1);
    
    if(warpIdx < vertex_count && label[warpIdx] == level) {
        const uint64_t start = vertexList[warpIdx];
        const uint64_t shift_start = start & 0xFFFFFFFFFFFFFFF0;
        const uint64_t end = vertexList[warpIdx+1];

        for(uint64_t i = shift_start + laneIdx; i < end; i += WARP_SIZE) {
//        printf("Inside kernel %llu %llu %llu\n", (unsigned long long) i, (unsigned long long)start, (unsigned long long) (end-start));
            if (i >= start) {
                const EdgeT next = edgeList[i];
  //printf("tid: %llu, idx: %llu next: %llu\n", (unsigned long long) tid, (unsigned long long) i, (unsigned long long) next);

                if(label[next] == MYINFINITY) {
                    label[next] = level + 1;
                    *changed = true;
                }
            }
        }
    }
}


__launch_bounds__(1024,1)
__global__ void kernel_coalesce_pc(array_t<uint64_t>* da, uint32_t *label, const uint32_t level, const uint64_t vertex_count, const uint64_t *vertexList, const EdgeT *edgeList, bool *changed) {
    const uint64_t tid = blockDim.x * BLOCK_NUM * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;
    const uint64_t warpIdx = tid >> WARP_SHIFT;
    const uint64_t laneIdx = tid & ((1 << WARP_SHIFT) - 1);
//    array_d_t<uint64_t> d_array = *da;
    if(warpIdx < vertex_count && label[warpIdx] == level) {
        const uint64_t start = vertexList[warpIdx];
        const uint64_t shift_start = start & 0xFFFFFFFFFFFFFFF0;
        const uint64_t end = vertexList[warpIdx+1];

        for(uint64_t i = shift_start + laneIdx; i < end; i += WARP_SIZE) {
            if (i >= start) {
                //const EdgeT next = edgeList[i];
                EdgeT next = da->seq_read(i);
//                printf("tid: %llu, idx: %llu next: %llu\n", (unsigned long long) tid, (unsigned long long) i, (unsigned long long) next);

                if(label[next] == MYINFINITY) {
                    label[next] = level + 1;
                    *changed = true;
                }
            }
        }
    }
}


__global__ void kernel_coalesce_chunk(uint32_t *label, const uint32_t level, const uint64_t vertex_count, const uint64_t *vertexList, const EdgeT *edgeList, bool *changed) {
    const uint64_t tid = blockDim.x * BLOCK_NUM * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;
    const uint64_t warpIdx = tid >> WARP_SHIFT;
    const uint64_t laneIdx = tid & ((1 << WARP_SHIFT) - 1);
    const uint64_t chunkIdx = warpIdx * CHUNK_SIZE;
    uint64_t chunk_size = CHUNK_SIZE;

    if((chunkIdx + CHUNK_SIZE) > vertex_count) {
        if ( vertex_count > chunkIdx )
            chunk_size = vertex_count - chunkIdx;
        else
            return;
    }

    for(uint32_t i = chunkIdx; i < chunk_size + chunkIdx; i++) {
        if(label[i] == level) {
            const uint64_t start = vertexList[i];
            const uint64_t shift_start = start & 0xFFFFFFFFFFFFFFF0;
            const uint64_t end = vertexList[i+1];

            for(uint64_t j = shift_start + laneIdx; j < end; j += WARP_SIZE) {
                if (j >= start) {
                    const EdgeT next = edgeList[j];
          
                    if(label[next] == MYINFINITY) {
                        label[next] = level + 1;
                        *changed = true;
                    }
                }
            }
        }
    }
}


__global__  __launch_bounds__(1024,1)
void kernel_coalesce_chunk_pc(array_t<uint64_t>* da, uint32_t *label, const uint32_t level, const uint64_t vertex_count, const uint64_t *vertexList, const EdgeT *edgeList, bool *changed) {
    const uint64_t tid = blockDim.x * BLOCK_NUM * blockIdx.y + blockDim.x * blockIdx.x + threadIdx.x;
    const uint64_t warpIdx = tid >> WARP_SHIFT;
    const uint64_t laneIdx = tid & ((1 << WARP_SHIFT) - 1);
    const uint64_t chunkIdx = warpIdx * CHUNK_SIZE;
    uint64_t chunk_size = CHUNK_SIZE;
//    array_d_t<uint64_t> d_array = *da;
    if((chunkIdx + CHUNK_SIZE) > vertex_count) {
        if ( vertex_count > chunkIdx )
            chunk_size = vertex_count - chunkIdx;
        else
            return;
    }

    for(uint32_t i = chunkIdx; i < chunk_size + chunkIdx; i++) {
        if(label[i] == level) {
            const uint64_t start = vertexList[i];
            const uint64_t shift_start = start & 0xFFFFFFFFFFFFFFF0;
            const uint64_t end = vertexList[i+1];

            for(uint64_t j = shift_start + laneIdx; j < end; j += WARP_SIZE) {
                if (j >= start) {
                    // const EdgeT next = edgeList[j];
                    EdgeT next = da->seq_read(j);
                    // printf("tid: %llu, idx: %llu next: %llu\n", (unsigned long long) tid, (unsigned long long) i, (unsigned long long) next);

                    if(label[next] == MYINFINITY) {
                        label[next] = level + 1;
                        *changed = true;
                    }
                }
            }
        }
    }
}


__global__ void throttle_memory(uint32_t *pad) {
    pad[1] = pad[0];
}

int main(int argc, char *argv[]) {
    using namespace std::chrono; 
    std::ifstream file;
    std::string vertex_file, edge_file;
    std::string filename;
    
    bool changed_h, *changed_d, no_src = false;
    int c, num_run = 1, arg_num = 0;
    impl_type type;
    mem_type mem;
    uint32_t *pad;
    uint32_t *label_d, level, zero, iter;
    uint64_t *vertexList_h, *vertexList_d;
    EdgeT *edgeList_h, *edgeList_d;
    uint64_t vertex_count, edge_count, vertex_size, edge_size;
    uint64_t typeT, src;
    uint64_t numblocks, numthreads;
    size_t freebyte, totalbyte;
    EdgeT *edgeList_dtmp;

    float milliseconds;
    double avg_milliseconds;

    Settings settings;
    uint64_t pc_page_size = 4096; 
    uint64_t pc_pages = 2*1024*1024;//1M*4096 = 4GB of page cache.  

    cudaEvent_t start, end;

    while ((c = getopt(argc, argv, "f:r:t:i:m:p:s:h")) != -1) {
        switch (c) {
            case 'f':
                filename = optarg;
                arg_num++;
                break;
            case 'r':
                if (!no_src)
                    src = atoll(optarg);
                arg_num++;
                break;
            case 't':
                type = (impl_type)atoi(optarg);
                arg_num++;
                break;
            case 'i':
                no_src = true;
                src = 0;
                num_run = atoi(optarg);
                arg_num++;
                break;
            case 'm':
                mem = (mem_type)atoi(optarg);
                arg_num++;
                break;
            case 'p':
                //Need to add type condition check.
                pc_page_size = atoi(optarg); 
                arg_num++;
                break;
            case 's':
                pc_pages = atoi(optarg); 
                arg_num++; 
                break;
            case 'h':
                printf("\t-f | input file name (must end with .bel)\n");
                printf("\t-r | BFS root (unused when i > 1)\n");
                printf("\t-t | type of BFS to run.\n");
                printf("\t   | BASELINE = 0, COALESCE = 1, COALESCE_CHUNK = 2\n");
                printf("\t   | BASELINE_PC = 3, COALESCE_PC = 4, COALESCE_CHUNK_PC = 5\n");
                printf("\t-m | memory allocation.\n");
                printf("\t   | GPUMEM = 0, UVM_READONLY = 1, UVM_DIRECT = 2\n");
                printf("\t   | UVM_READONLY_NVLINK = 3, UVM_DIRECT_NVLINK = 4, BAFS_DIRECT = 6\n");
                printf("\t-i | number of iterations to run\n");
                printf("\t-p | (applies only for PC) page cache page size in bytes\n");
                printf("\t-s | (applies only for PC) number of entries in page cache\n");
                printf("\t-h | help message\n");
                return 0;
            case '?':
                break;
            default:
                break;
        }
    }

    if (arg_num < 4) {
        printf("\t-f | input file name (must end with .bel)\n");
        printf("\t-r | BFS root (unused when i > 1)\n");
        printf("\t-t | type of BFS to run.\n");
        printf("\t   | BASELINE = 0, COALESCE = 1, COALESCE_CHUNK = 2\n");
        printf("\t   | BASELINE_PC = 3, COALESCE_PC = 4, COALESCE_CHUNK_PC = 5\n");
        printf("\t-m | memory allocation.\n");
        printf("\t   | GPUMEM = 0, UVM_READONLY = 1, UVM_DIRECT = 2\n");
        printf("\t   | UVM_READONLY_NVLINK = 3, UVM_DIRECT_NVLINK = 4, BAFS_DIRECT = 6\n");
        printf("\t-i | number iterations to run\n");
        printf("\t-p | (applies only for PC) page cache page size in bytes\n");
        printf("\t-s | (applies only for PC) number of entries in page cache\n");
        printf("\t-h | help message\n");
        return 0;
    }

    cuda_err_chk(cudaEventCreate(&start));
    cuda_err_chk(cudaEventCreate(&end));

    vertex_file = filename + ".col";
    edge_file = filename + ".dst";

    std::cout << filename << std::endl;
    fprintf(stderr, "File %s\n", filename.c_str());
    // Read files
    file.open(vertex_file.c_str(), std::ios::in | std::ios::binary);
    if (!file.is_open()) {
        fprintf(stderr, "Vertex file open failed\n");
        exit(1);
    };

    file.read((char*)(&vertex_count), 8);
    file.read((char*)(&typeT), 8);

    vertex_count--;

    printf("Vertex: %llu, ", vertex_count);
    vertex_size = (vertex_count+1) * sizeof(uint64_t);

    vertexList_h = (uint64_t*)malloc(vertex_size);

    file.read((char*)vertexList_h, vertex_size);
    file.close();

    file.open(edge_file.c_str(), std::ios::in | std::ios::binary);
    if (!file.is_open()) {
        fprintf(stderr, "Edge file open failed\n");
        exit(1);
    };

    file.read((char*)(&edge_count), 8);
    file.read((char*)(&typeT), 8);

    printf("Edge: %llu\n", edge_count);
    fflush(stdout);
    edge_size = edge_count * sizeof(EdgeT); //4096 padding for weights and edges. TODO. confirm page aligned address mapping on cudamallocmanaged.
    edge_size = edge_size + (4096 - (edge_size & 0xFFFULL));

    edgeList_h = NULL;

    // Allocate memory for GPU
    cuda_err_chk(cudaMalloc((void**)&vertexList_d, vertex_size));
    cuda_err_chk(cudaMalloc((void**)&label_d, vertex_count * sizeof(uint32_t)));
    cuda_err_chk(cudaMalloc((void**)&changed_d, sizeof(bool)));

    std::vector<unsigned long long int> vertexVisitCount_h;
    unsigned long long int* vertexVisitCount_d;
    unsigned long long int globalvisitedcount_h;
    unsigned long long int* globalvisitedcount_d;

    vertexVisitCount_h.resize(vertex_count);
    cuda_err_chk(cudaMalloc((void**)&globalvisitedcount_d, sizeof(unsigned long long int)));
    cuda_err_chk(cudaMemset(globalvisitedcount_d, 0, sizeof(unsigned long long int)));
    cuda_err_chk(cudaMalloc((void**)&vertexVisitCount_d, vertex_count*sizeof(unsigned long long int)));
    cuda_err_chk(cudaMemset(vertexVisitCount_d, 0, vertex_count*sizeof(unsigned long long int)));

    switch (mem) {
        case GPUMEM:
            edgeList_h = (EdgeT*)malloc(edge_size);
            file.read((char*)edgeList_h, edge_size);
            cuda_err_chk(cudaMalloc((void**)&edgeList_d, edge_size));
            file.close();
            break;
        case UVM_READONLY:
            cuda_err_chk(cudaMallocManaged((void**)&edgeList_d, edge_size));
            file.read((char*)edgeList_d, edge_size);
            cuda_err_chk(cudaMemAdvise(edgeList_d, edge_size, cudaMemAdviseSetReadMostly, 0));

            cuda_err_chk(cudaMemGetInfo(&freebyte, &totalbyte));
            if (totalbyte < 16*1024*1024*1024ULL)
                printf("total memory sizeo of current GPU is %llu byte, no need to throttle\n", totalbyte);
            else {
                printf("total memory sizeo of current GPU is %llu byte, throttling %llu byte.\n", totalbyte, totalbyte - 16*1024*1024*1024ULL);
                cuda_err_chk(cudaMalloc((void**)&pad, totalbyte - 16*1024*1024*1024ULL));
                throttle_memory<<<1,1>>>(pad);
            }
            file.close();
            break;
        case UVM_DIRECT:
        {
            cuda_err_chk(cudaMallocManaged((void**)&edgeList_d, edge_size));
            // printf("Address is %p   %p\n", edgeList_d, &edgeList_d[0]); 
            high_resolution_clock::time_point ft1 = high_resolution_clock::now();
            file.read((char*)edgeList_d, edge_size);
            file.close();
            high_resolution_clock::time_point ft2 = high_resolution_clock::now();
            duration<double> time_span = duration_cast<duration<double>>(ft2 -ft1);
            std::cout<< "edge file read time: "<< time_span.count() <<std::endl;
            cuda_err_chk(cudaMemAdvise(edgeList_d, edge_size, cudaMemAdviseSetAccessedBy, 0));
            break;
        }
/*        case UVM_READONLY_NVLINK:
            cuda_err_chk(cudaSetDevice(2));
            cuda_err_chk(cudaMallocManaged((void**)&edgeList_d, edge_size));
            file.read((char*)edgeList_d, edge_size);
            cuda_err_chk(cudaMemAdvise(edgeList_d, edge_size, cudaMemAdviseSetReadMostly, 0));
            cuda_err_chk(cudaMemPrefetchAsync(edgeList_d, edge_size, 2, 0));
            cuda_err_chk(cudaDeviceSynchronize());
            cuda_err_chk(cudaSetDevice(0));
            file.close();
            break;
        case UVM_DIRECT_NVLINK:
            cuda_err_chk(cudaSetDevice(2));
            cuda_err_chk(cudaMallocManaged((void**)&edgeList_d, edge_size));
            file.read((char*)edgeList_d, edge_size);
            cuda_err_chk(cudaMemPrefetchAsync(edgeList_d, edge_size, 2, 0));
            cuda_err_chk(cudaDeviceSynchronize());
            cuda_err_chk(cudaSetDevice(0));
            cuda_err_chk(cudaMemAdvise(edgeList_d, edge_size, cudaMemAdviseSetAccessedBy, 0));
            file.close();
            break;
        case DRAGON_MAP:
            if((dragon_map(edge_file.c_str(), (edge_size+16), D_F_READ, (void**) &edgeList_dtmp)) != D_OK){
                  printf("Dragon Map Failed for edgelist\n");
                  return -1;
            }
            edgeList_d = edgeList_dtmp+2;
            break;
*/
        case BAFS_DIRECT: 
            cuda_err_chk(cudaMemGetInfo(&freebyte, &totalbyte));
            if (totalbyte < 16*1024*1024*1024ULL)
                printf("total memory sizeo of current GPU is %llu byte, no need to throttle\n", totalbyte);
            else {
                printf("total memory sizeo of current GPU is %llu byte, throttling %llu byte.\n", totalbyte, totalbyte - 16*1024*1024*1024ULL);
                cuda_err_chk(cudaMalloc((void**)&pad, totalbyte - 16*1024*1024*1024ULL));
                throttle_memory<<<1,1>>>(pad);
            }
            break;
    }


    printf("Allocation finished\n");
    fflush(stdout);

    // Initialize values
    cuda_err_chk(cudaMemcpy(vertexList_d, vertexList_h, vertex_size, cudaMemcpyHostToDevice));

    if (mem == GPUMEM){
        cuda_err_chk(cudaMemcpy(edgeList_d, edgeList_h, edge_size, cudaMemcpyHostToDevice));
    }
    
    numthreads = 1024;

    switch (type) {
        case BASELINE:
        case BASELINE_PC:
            numblocks = ((vertex_count + numthreads) / numthreads);
            break;
        case COALESCE:
        case COALESCE_PC:
            numblocks = ((vertex_count * WARP_SIZE + numthreads) / numthreads);
            break;
        case COALESCE_CHUNK:
        case COALESCE_CHUNK_PC:
            numblocks = ((vertex_count * (WARP_SIZE / CHUNK_SIZE) + numthreads) / numthreads);
            break;
        default:
            fprintf(stderr, "Invalid type\n");
            exit(1);
            break;
    }

    dim3 blockDim(BLOCK_NUM, (numblocks+BLOCK_NUM)/BLOCK_NUM);

    avg_milliseconds = 0.0f;

    printf("Initialization done\n");
    fflush(stdout);

    if((type==BASELINE_PC)||(type == COALESCE_PC) ||(type == COALESCE_CHUNK_PC)){
            printf("page size: %d, pc_entries: %llu\n", pc_page_size, pc_pages);
    }

    try{         
            std::vector<Controller*> ctrls(settings.n_ctrls);
            if(mem == BAFS_DIRECT){
                cuda_err_chk(cudaSetDevice(settings.cudaDevice));
                for (size_t i = 0 ; i < settings.n_ctrls; i++)
                    ctrls[i] = new Controller(ctrls_paths[i], settings.nvmNamespace, settings.cudaDevice, settings.queueDepth, settings.numQueues);
            }

            page_cache_t* h_pc; 
            range_t<uint64_t>* h_range;
            std::vector<range_t<uint64_t>*> vec_range(1);
            array_t<uint64_t>* h_array; 
            uint64_t n_pages = ceil(((float)edge_size)/pc_page_size); 
            
            if((type==BASELINE_PC)||(type == COALESCE_PC) ||(type == COALESCE_CHUNK_PC)){
//             page_cache_t h_pc(pc_page_size, pc_pages, settings, (uint64_t) 64); 
//             range_t<uint64_t>* d_range = (range_t<uint64_t>*) h_range.d_range_ptr;
               h_pc =new page_cache_t(pc_page_size, pc_pages, settings.cudaDevice, ctrls[0][0], (uint64_t) 1, ctrls);
               h_range = new range_t<uint64_t>((int)0 ,(uint64_t)edge_count, (int) 0,(uint64_t)n_pages, (int)0, (uint64_t)pc_page_size, h_pc, settings.cudaDevice); //, (uint8_t*)edgeList_d);
               vec_range[0] = h_range; 
               h_array = new array_t<uint64_t>(edge_count, 0, vec_range, settings.cudaDevice);
               
               printf("Page cache initialized\n");
               fflush(stdout);
            }
            // Set root
            for (int i = 0; i < num_run; i++) {
                zero = 0;
                cuda_err_chk(cudaMemset(label_d, 0xFF, vertex_count * sizeof(uint32_t)));
                cuda_err_chk(cudaMemcpy(&label_d[src], &zero, sizeof(uint32_t), cudaMemcpyHostToDevice));

                level = 0;
                iter = 0;

                cuda_err_chk(cudaEventRecord(start, 0));

                // Run BFS
                do {
                    changed_h = false;
                    cuda_err_chk(cudaMemcpy(changed_d, &changed_h, sizeof(bool), cudaMemcpyHostToDevice));

                    switch (type) {
                        case BASELINE:
                            kernel_baseline<<<blockDim, numthreads>>>(label_d, level, vertex_count, vertexList_d, edgeList_d, changed_d, globalvisitedcount_d, vertexVisitCount_d);
                            break;
                        case COALESCE:
                            kernel_coalesce<<<blockDim, numthreads>>>(label_d, level, vertex_count, vertexList_d, edgeList_d, changed_d);
                            break;
                        case COALESCE_CHUNK:
                            kernel_coalesce_chunk<<<blockDim, numthreads>>>(label_d, level, vertex_count, vertexList_d, edgeList_d, changed_d);
                            break;
                        case BASELINE_PC:
                            //printf("Calling Page cache enabled baseline kernel\n");
                            kernel_baseline_pc<<<blockDim, numthreads>>>(h_array->d_array_ptr, label_d, level, vertex_count, vertexList_d, edgeList_d, changed_d, globalvisitedcount_d, vertexVisitCount_d);
                            break;
                        case COALESCE_PC:
                            //printf("Calling Page cache enabled coalesce kernel\n");
                            kernel_coalesce_pc<<<blockDim, numthreads>>>(h_array->d_array_ptr, label_d, level, vertex_count, vertexList_d, edgeList_d, changed_d);
                            break;
                        case COALESCE_CHUNK_PC:
                            //printf("Calling Page cache enabled coalesce chunk kernel\n");
                            kernel_coalesce_chunk_pc<<<blockDim, numthreads>>>(h_array->d_array_ptr, label_d, level, vertex_count, vertexList_d, edgeList_d, changed_d);
                            break;
                        default:
                            fprintf(stderr, "Invalid type\n");
                            exit(1);
                            break;
                    }

                    iter++;
                    level++;

                    cuda_err_chk(cudaMemcpy(&changed_h, changed_d, sizeof(bool), cudaMemcpyDeviceToHost));
                    //break;
                } while(changed_h);

                cuda_err_chk(cudaEventRecord(end, 0));
                cuda_err_chk(cudaEventSynchronize(end));
                cuda_err_chk(cudaEventElapsedTime(&milliseconds, start, end));

                printf("run %*d: ", 3, i);
                printf("src %*u, ", 10, src);
                printf("iteration %*u, ", 3, iter);
                printf("time %*f ms\n", 12, milliseconds);
                fflush(stdout);

                avg_milliseconds += (double)milliseconds;

                src += vertex_count / num_run;

                /*if (i < num_run - 1) {
                   EdgeT *edgeList_temp;

                   switch (mem) {
                       case UVM_READONLY:
                           cuda_err_chk(cudaMallocManaged((void**)&edgeList_temp, edge_size));
                           memcpy(edgeList_temp, edgeList_d, edge_size);
                           cuda_err_chk(cudaFree(edgeList_d));
                           edgeList_d = edgeList_temp;
                           cuda_err_chk(cudaMemAdvise(edgeList_d, edge_size, cudaMemAdviseSetReadMostly, 0));
                           break;
                       case UVM_READONLY_NVLINK:
                           cuda_err_chk(cudaSetDevice(2));
                           cuda_err_chk(cudaMallocManaged((void**)&edgeList_temp, edge_size));
                           memcpy(edgeList_temp, edgeList_d, edge_size);
                           cuda_err_chk(cudaFree(edgeList_d));
                           edgeList_d = edgeList_temp;
                           cuda_err_chk(cudaMemAdvise(edgeList_d, edge_size, cudaMemAdviseSetReadMostly, 0));
                           cuda_err_chk(cudaMemPrefetchAsync(edgeList_d, edge_size, 2, 0));
                           cuda_err_chk(cudaDeviceSynchronize());
                           cuda_err_chk(cudaSetDevice(0));
                           break;
                       default:
                           break;
                   }
                }*/
            }
            printf("\nAverage run time %f ms\n", avg_milliseconds / num_run);
            

            free(vertexList_h);
            if((type==BASELINE_PC)||(type == COALESCE_PC) ||(type == COALESCE_CHUNK_PC)){
               delete h_pc; 
               delete h_range; 
               delete h_array;
            }
            if (edgeList_h)
                free(edgeList_h);
            cuda_err_chk(cudaFree(vertexList_d));
            cuda_err_chk(cudaFree(label_d));
            cuda_err_chk(cudaFree(changed_d));

            cuda_err_chk(cudaFree(globalvisitedcount_d));
            cuda_err_chk(cudaFree(vertexVisitCount_d));
            vertexVisitCount_h.clear();

            cuda_err_chk(cudaFree(edgeList_d));
            
            for (size_t i = 0 ; i < settings.n_ctrls; i++)
                delete ctrls[i];
    }
    catch (const error& e){
        fprintf(stderr, "Unexpected error: %s\n", e.what());
        return 1;
    }
    return 0;
}
