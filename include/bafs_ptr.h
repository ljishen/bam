#ifndef __BAFS_PTR_H__
#define __BAFS_PTR_H__

#ifndef __CUDACC__
#define __device__
#define __host__
#define __forceinline__ inline
#endif

#include "page_cache.h"
#include <cstdint> 

template<class T>
class bafs_ptr {
private:
    array_d_t<T>* pData;
    uint64_t start_idx;
public:
    __host__ __device__ bafs_ptr():
        pData(NULL),start_idx(0){
    }
    __host__ __device__ bafs_ptr(array_d_t<T>* const pValue):
        pData(pValue),start_idx(0){
    }

    __host__ __device__ bafs_ptr(array_d_t<T>* const pValue, const uint64_t start_off):
        pData(pValue),start_idx(start_off){
    }

    __host__ __device__ ~bafs_ptr(){}

    __host__ __device__ bafs_ptr(const bafs_ptr &var){
        pData = var.pData;
        start_idx = var.start_idx;
    }

    __device__ T operator*(){
        return (*pData)[start_idx];
    }

    __host__ __device__ bafs_ptr<T>& operator=(const bafs_ptr<T>& obj) {
        if(this == obj)
            return *this;
        else{
            this->pData = obj.pData;
            this->start_idx = obj.start_idx;
        }
        return *this;
    }

    __host__ __device__ T operator[](const uint64_t i){
        return (*pData)[start_idx+i];
    }

    __host__ __device__ const T operator[](const uint64_t i) const {
        return (*pData)[start_idx+i];
    }

    __host__ __device__ bafs_ptr<T> operator+(const uint64_t i){
        uint64_t new_start_idx = this->start_idx+i;
        return bafs_ptr<T>(this->pData, new_start_idx);
    }
    __host__ __device__ bafs_ptr<T> operator-(const uint64_t i){
        uint64_t new_start_idx = this->start_idx-i;
        return bafs_ptr<T>(this->pData, new_start_idx);
    }
//posfix operator
    __host__ __device__ bafs_ptr<T> operator++(int){
        bafs_ptr<T> cpy = *this;
        this->start_idx += 1;
        return cpy;
    }
//prefix operator
    __host__ __device__ bafs_ptr<T>& operator++(){
        this->start_idx += 1;
        return *this;
    }

//posfix operator
    __host__ __device__ bafs_ptr<T> operator--(int){
        bafs_ptr<T> cpy = *this;
        this->start_idx -= 1;
        return cpy;
    }
//prefix operator
    __host__ __device__ bafs_ptr<T>& operator--(){
        this->start_idx -= 1;
        return *this;
    }
};

   

#ifndef __CUDACC__
#undef __device__
#undef __host__
#undef __forceinline__
#endif
     
#endif
