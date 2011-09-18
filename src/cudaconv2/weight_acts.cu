/* 
 * Copyright (c) 2011, Alex Krizhevsky (akrizhevsky@gmail.com)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * 
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <cudaconv2.cuh>

/*
 * Each block computes weight gradients for B_Y * pixelsPerThread pixels and B_X filters
 * threadIdx.x determines filter
 * threadIdx.y determines pixel in filter
 *
 * blockIdx.x determines filter batch of B_X, module batch of modulesPerBlock
 * blockIdx.y determines pixel batch of B_Y * pixelsPerThread
 *
 * Number of filters must be divisible by B_X
 * Number of images (cases) should be divisible by preloadCases if checkCaseBounds is false.
 *
 * images:      (numColors, imgPixels, numImages), with stride given
 * hidActs:     (numFilters, numModules, numImages)
 *
 * targets:     (numModules/modulesPerBlock, numColors, filterPixels, numFilters)
 *
 * B_Y * B_X should be divisible by preloadCases.
 * preloadCases one of 16, 32.
 * B_X one of 4, 8, 16, 32
 * B_Y arbitrary (satisfying divisibility constraints)
 * numModules must be divisible by modulesPerBlock
 *
 * After adding pixelsPerThread, register usage went from 20 to 23 (when pixelsPerThread = 1)...
 * so the compiler is messing up here somehow. It's unable to optimize that case away.
 */
template <int B_Y, int B_X, int pixelsPerThread, int preloadCases, int numColors, bool scale, bool checkCaseBounds>
__global__ void weight_acts_kernel2_color(float* images, float* hidActs, float* targets,
                                         const int numImages, const int numFilters,
                                         const int numModulesX,
                                         const int imgSize, const int filterSize,
                                         const int paddingStart, const int moduleStride, const int imgStride,
                                         const int modulesPerBlock,
                                         const float scaleTargets, const float scaleOutput) {
    __shared__ float shImages[pixelsPerThread * B_Y * numColors][preloadCases]; // preload preloadCases cases of B_Y * pixelsPerThread pixels
    __shared__ float shHidActs[B_X][preloadCases + 1]; // preload preloadCases cases of B_X hidActs

    const int tidx = B_X * threadIdx.y + threadIdx.x;
    const int loadY = tidx / preloadCases, loadX = tidx % preloadCases;

    const int filterPixels = filterSize * filterSize;
    const int imgPixels = imgSize * imgSize;

    const int blocksPerModule = numFilters / B_X;
    const int outputModuleIdx = blockIdx.x / blocksPerModule;
    const int moduleIdx = modulesPerBlock * outputModuleIdx;
    const int blockFilterIdx = B_X * (blockIdx.x % blocksPerModule);

//    const int moduleStride = (imgSize - filterSize + 1) / numModulesX; 
    const int numModules = numModulesX * numModulesX;

    const int blockPixelOffset = blockIdx.y * B_Y * pixelsPerThread;

    images += loadX;
    hidActs += moduleIdx * numImages
            + blockFilterIdx * numImages * numModules
            + loadY * numImages * numModules
            + loadX;
    
    targets += (outputModuleIdx * numFilters) * filterPixels * numColors
            + blockPixelOffset * numFilters
            + blockFilterIdx
            + threadIdx.y * numFilters + threadIdx.x;

    float* shImgLoad = &shImages[loadY][loadX];
    float* shHidActLoad = &shHidActs[loadY][loadX];

    float prod[numColors][pixelsPerThread];
    #pragma unroll
    for (int c = 0; c < numColors; c++) {
        #pragma unroll
        for (int p = 0; p < pixelsPerThread; p++) {
            prod[c][p] = 0;
        }
    }
    for (int m = moduleIdx; m < moduleIdx + modulesPerBlock; m++) {
        const int imgLoadModPosY = paddingStart + (m / numModulesX) * moduleStride;
        const int imgLoadModPosX = paddingStart + (m % numModulesX) * moduleStride;
        for (int caseIdx = 0; caseIdx < numImages; caseIdx += preloadCases) {
            if (loadY < B_Y * pixelsPerThread) {
                /*
                 * As long as B_Y * B_X is divisible by preloadCases this will loop the right
                 * number of times.
                 *
                 * This will load some imgGrads from filter pixels that don't exit (it'll set those to 0),
                 * but the code does not produce any output for those pixels (see last lines).
                 */
    //            #pragma unroll
                for (int y = 0; y < B_Y * pixelsPerThread; y += (B_X * B_Y) / preloadCases) {
                    // Make sure number of rows in the array is divisible by number of rows filled per iteration
                    if ((B_Y * pixelsPerThread) % (B_X * B_Y / preloadCases) == 0 || y + loadY < B_Y * pixelsPerThread) {
                        const int pxIdx = blockPixelOffset + loadY + y; // pixel idx in filter

                        if (pxIdx < filterPixels && (!checkCaseBounds || caseIdx + loadX < numImages)) {
                            const int pxY = imgLoadModPosY + pxIdx / filterSize; // pixel x,y coords in image
                            const int pxX = imgLoadModPosX + pxIdx % filterSize;
                            if (pxY >= 0 && pxY < imgSize && pxX >= 0 && pxX < imgSize) {
                                const int pixIdx = (pxY * imgSize + pxX) * imgStride;
                                #pragma unroll
                                for (int c = 0; c < numColors; c++) {
                                    shImgLoad[(y + c * pixelsPerThread * B_Y) * preloadCases] = images[caseIdx + c * imgPixels * imgStride + pixIdx];
                                }
                            } else {
                                #pragma unroll
                                for (int c = 0; c < numColors; c++) {
                                    shImgLoad[(y + c * pixelsPerThread * B_Y) * preloadCases] = 0;
                                }
                            }
                        } else {
                            #pragma unroll
                            for (int c = 0; c < numColors; c++) {
                                shImgLoad[(y + c * pixelsPerThread * B_Y) * preloadCases] = 0;
                            }
                        }
                    }
                }
            }
            if (loadY < B_X && (!checkCaseBounds || caseIdx + loadX < numImages)) {
                #pragma unroll
                for (int y = 0; y < B_X; y += (B_X * B_Y) / preloadCases) {
                    // Make sure number of rows in the array is divisible by number of rows filled per iteration
                    if (B_X % (B_X * B_Y / preloadCases) == 0 || y + loadY < B_X) {
                        shHidActLoad[y * (preloadCases + 1)] = hidActs[caseIdx + y * numImages * numModules];
                    }
                }
            }

            __syncthreads();
            #pragma unroll
            for (int p = 0; p < pixelsPerThread; p++) {
                #pragma unroll
                for (int i = 0; i < preloadCases; i++) {
                    #pragma unroll
                    for (int c = 0; c < numColors; c++) {
                        prod[c][p] += shImages[threadIdx.y + p * B_Y + c * pixelsPerThread * B_Y][i] * shHidActs[threadIdx.x][i];
                    }
                }
            }
            __syncthreads();
        }
        hidActs += numImages;
    }
    
    if (scale) {
        #pragma unroll
        for (int p = 0; p < pixelsPerThread; p++) {
            if (blockPixelOffset + p * B_Y + threadIdx.y < filterPixels) {
                #pragma unroll
                for (int c = 0; c < numColors; c++) {
                    targets[p * B_Y * numFilters + c * filterPixels * numFilters] = scaleTargets * targets[p * B_Y * numFilters + c * filterPixels * numFilters] + scaleOutput * prod[c][p];
                }
            }
        }
    } else {
        #pragma unroll
        for (int p = 0; p < pixelsPerThread; p++) {
            if (blockPixelOffset + p * B_Y + threadIdx.y < filterPixels) {
                #pragma unroll
                for (int c = 0; c < numColors; c++) {
                    targets[p * B_Y * numFilters + c * filterPixels * numFilters] = prod[c][p];
                }
            }
        }
    }
}

#define LO16(x)    ((x) & 0x0000FFFF)
#define HI16(x)     ((x) >> 16)
/*
 * Each block computes weight gradients for B_Y * pixelsPerThread pixels and B_X filters
 * threadIdx.x determines filter
 * threadIdx.y determines pixel in filter
 *
 * blockIdx.x determines filter batch of B_X, module batch of modulesPerBlock
 * blockIdx.y determines pixel, color batch of B_Y * pixelsPerThread * colorsPerThread
 *      In essence, blockIdx.y.x = 0...numFilterColors / colorsPerThread
 *                  blockIdx.y.y = 0...DIVUP(numPixels, B_Y*pixelsPerThread)
 * ============
 * CONSTRAINTS:
 * ============
 * numFilters/numGroups must be divisible by B_X
 * numImgColors/numGroups must be divisible by colorsPerThread
 * numFilters must be divisible by numGroups
 * numImgColors must be divisible by numGroups
 * Number of images (cases) should be divisible by preloadCases if checkCaseBounds is false.
 *
 * images:      (numImgColors, imgPixels, numImages), with stride given
 * hidActs:     (numFilters, numModules, numImages)
 *
 * targets:     (numModules, numFilterColors, filterPixels, numFilters)
 *
 * B_Y * B_X should be divisible by preloadCases.
 * preloadCases one of 16, 32.
 * B_X one of 4, 8, 16, 32
 * B_Y arbitrary (satisfying divisibility constraints)
 *
 * After adding pixelsPerThread, register usage went from 20 to 23 (when pixelsPerThread = 1)...
 * so the compiler is messing up here somehow. It's unable to optimize that case away.
 */
template <int B_Y, int B_X, int pixelsPerThread, int colorsPerThread, int preloadCases, bool scale, bool checkCaseBounds>
__global__ void weight_acts_kernel2_manycolor(float* images, float* hidActs, float* targets,
                                         const int numImages, const int numFilters,
                                         const int numModulesX,
                                         const int imgSize, const int filterSize,
                                         const int paddingStart, const int moduleStride, const int imgStride,
                                         const int numImgColors, const int modulesPerBlock, const int numGroups,
                                         const float scaleTargets, const float scaleOutput) {
    __shared__ float shImages[colorsPerThread * pixelsPerThread * B_Y][preloadCases]; // preload preloadCases cases of B_Y * pixelsPerThread pixels
    __shared__ float shHidActs[B_X][preloadCases + 1]; // preload preloadCases cases of B_X hidacts

    const int tidx = B_X * threadIdx.y + threadIdx.x;
    const int loadY = tidx / preloadCases, loadX = tidx % preloadCases;

    const int filterPixels = filterSize * filterSize;
    const int imgPixels = imgSize * imgSize;

    const int blocksPerModule = numFilters / B_X;
    const int outputModuleIdx = (blockIdx.x / blocksPerModule);
    const int moduleIdx = modulesPerBlock * outputModuleIdx;
    const int blockFilterIdx = B_X * (blockIdx.x % blocksPerModule);
    const int numModules = numModulesX * numModulesX;
    
    const int numFiltersPerGroup = numFilters / numGroups;
    const int blockGroupIdx = blockFilterIdx / numFiltersPerGroup;
    const int numFilterColors = numImgColors / numGroups;
    const int groupColorIdx = blockGroupIdx * numFilterColors;

    const int blockPixelOffset = (blockIdx.y / (numFilterColors/colorsPerThread)) * B_Y * pixelsPerThread;
    const int blockColorIdx = (blockIdx.y % (numFilterColors/colorsPerThread)) * colorsPerThread;

    images += (groupColorIdx + blockColorIdx) * imgPixels * imgStride + loadX;

    hidActs += moduleIdx * numImages
            + blockFilterIdx * numImages * numModules
            + loadY * numImages * numModules
            + loadX;
    
    targets += outputModuleIdx * numFilters * filterPixels * numFilterColors
            + blockColorIdx * filterPixels * numFilters
            + blockPixelOffset * numFilters
            + blockFilterIdx
            + threadIdx.y * numFilters + threadIdx.x;

    float* shHidActLoad = &shHidActs[loadY][loadX];
    float* shImgLoad = &shImages[loadY][loadX];
    float prod[colorsPerThread][pixelsPerThread];
    #pragma unroll
    for (int c = 0; c < colorsPerThread; c++) {
        #pragma unroll
        for (int p = 0; p < pixelsPerThread; p++) {
            prod[c][p] = 0;
        }
    }
    
    // This avoids doing a division in an inner loop
    __shared__ int pxDivs[B_Y*pixelsPerThread];
    if (tidx < B_Y * pixelsPerThread) {
        pxDivs[tidx] = ((blockPixelOffset + tidx) / filterSize) + (((blockPixelOffset + tidx) % filterSize) << 16);
    }
    __syncthreads();
    for (int m = moduleIdx; m < moduleIdx + modulesPerBlock; m++) {
        const int imgLoadModPosY = paddingStart + (m / numModulesX) * moduleStride;
        const int imgLoadModPosX = paddingStart + (m % numModulesX) * moduleStride;
        for (int caseIdx = 0; caseIdx < numImages; caseIdx += preloadCases) {
            if (loadY < B_Y * pixelsPerThread) {
                /*
                 * As long as B_Y * B_X is divisible by preloadCases this will loop the right
                 * number of times.
                 *
                 * This will load some images from filter pixels that don't exist (it'll set those to 0),
                 * but the code does not produce any output for those pixels (see last lines).
                 */
    //            #pragma unroll
                for (int y = 0; y < B_Y * pixelsPerThread; y += (B_X * B_Y) / preloadCases) {
                    
                    // Make sure number of rows in the array is divisible by number of rows filled per iteration
                    if ((B_Y * pixelsPerThread) % (B_X * B_Y / preloadCases) == 0 || y + loadY < B_Y * pixelsPerThread) {
                        const int pxIdx = loadY + y; // pixel idx in filter

                        if (pxIdx + blockPixelOffset < filterPixels && (!checkCaseBounds || caseIdx + loadX < numImages)) {
                            const int pxY = imgLoadModPosY + LO16(pxDivs[pxIdx]); // pixel x,y coords in image
                            const int pxX = imgLoadModPosX + HI16(pxDivs[pxIdx]);
                            if (pxY >= 0 && pxY < imgSize && pxX >= 0 && pxX < imgSize) {
                                const int pixIdx = (pxY * imgSize + pxX) * imgStride; // pixel idx in image
                                #pragma unroll
                                for (int c = 0; c < colorsPerThread; c++) {
                                    shImgLoad[(y + c * pixelsPerThread * B_Y) * preloadCases] = images[caseIdx + c * imgPixels * imgStride + pixIdx];
                                }
                            } else {
                                #pragma unroll
                                for (int c = 0; c < colorsPerThread; c++) {
                                    shImgLoad[(y + c * pixelsPerThread * B_Y) * preloadCases] = 0;
                                }
                            }
                        } else {
                            #pragma unroll
                            for (int c = 0; c < colorsPerThread; c++) {
                                shImgLoad[(y + c * pixelsPerThread * B_Y) * preloadCases] = 0;
                            }
                        }
                    }
                }
            }
            if (loadY < B_X && (!checkCaseBounds || caseIdx + loadX < numImages)) {
                #pragma unroll
                for (int y = 0; y < B_X; y += (B_X * B_Y) / preloadCases) {
                    // Make sure number of rows in the array is divisible by number of rows filled per iteration
                    if (B_X % (B_X * B_Y / preloadCases) == 0 || y + loadY < B_X) {
                        shHidActLoad[y * (preloadCases + 1)] = hidActs[caseIdx + y * numImages * numModules];
                    }
                }
            }

            __syncthreads();

            #pragma unroll
            for (int c = 0; c < colorsPerThread; c++) {
                #pragma unroll
                for (int i = 0; i < preloadCases; i++) {
                    #pragma unroll
                    for (int p = 0; p < pixelsPerThread; p++) {
                        prod[c][p] += shImages[threadIdx.y + p * B_Y + c * pixelsPerThread * B_Y][i] * shHidActs[threadIdx.x][i];
                    }
                }
            }
            __syncthreads();
        }
        hidActs += numImages;
    }

    if (scale) {
        #pragma unroll
        for (int p = 0; p < pixelsPerThread; p++) {
            if (blockPixelOffset + p * B_Y + threadIdx.y < filterPixels) {
                #pragma unroll
                for (int c = 0; c < colorsPerThread; c++) {
                    targets[p * B_Y * numFilters + c * filterPixels * numFilters] = scaleTargets * targets[p * B_Y * numFilters + c * filterPixels * numFilters] + scaleOutput * prod[c][p];
                }
            }
        }
    } else {
        #pragma unroll
        for (int p = 0; p < pixelsPerThread; p++) {
            if (blockPixelOffset + p * B_Y + threadIdx.y < filterPixels) {
                #pragma unroll
                for (int c = 0; c < colorsPerThread; c++) {
                    targets[p * B_Y * numFilters + c * filterPixels * numFilters] = prod[c][p];
                }
            }
        }
    }
}

/*
 * Each block computes weight gradients for B_Y pixels and B_X * filtersPerThread filters
 * threadIdx.x determines filter
 * threadIdx.y determines pixel in filter
 *
 * blockIdx.x determines filter batch of B_X * filtersPerThread, module batch of modulesPerBlock
 * blockIdx.y determines pixel, color batch of B_Y * colorsPerThread
 *      In essence, blockIdx.y.x = 0...numFilterColors / colorsPerThread
 *                  blockIdx.y.y = 0...DIVUP(numPixels, B_Y)
 * ============
 * CONSTRAINTS:
 * ============
 * numFilters/numGroups must be divisible by B_X * filtersPerThread
 * numImgColors/numGroups must be divisible by colorsPerThread
 * numFilters must be divisible by numGroups
 * numImgColors must be divisible by numGroups
 * Number of images (cases) should be divisible by preloadCases if checkCaseBounds is false.
 *
 * images:      (numImgColors, imgPixels, numImages), with stride given
 * hidActs:     (numFilters, numModules, numImages)
 *
 * targets:     (numModules, numFilterColors, filterPixels, numFilters)
 *
 * B_Y * B_X should be divisible by preloadCases.
 * preloadCases one of 16, 32.
 * B_X one of 4, 8, 16, 32
 * B_Y arbitrary (satisfying divisibility constraints)
 * 
 * This routine is especially fast when numFilters > 32. That's when it should be used.
 */
template <int B_Y, int B_X, int filtersPerThread, int colorsPerThread, int preloadCases, bool scale, bool checkCaseBounds>
__global__ void weight_acts_kernel2_manycolor_manyfilter(float* images, float* hidActs, float* targets,
                                                         const int numImages, const int numFilters,
                                                         const int numModulesX,
                                                         const int imgSize, const int filterSize,
                                                         const int paddingStart, const int moduleStride, const int imgStride,
                                                         const int numImgColors, const int modulesPerBlock,
                                                         const int numGroups,
                                                         const float scaleTargets, const float scaleOutput) {
    __shared__ float shImages[colorsPerThread * B_Y][preloadCases]; // preload preloadCases cases of B_Y * pixelsPerThread pixels
    __shared__ float shHidActs[filtersPerThread * B_X][preloadCases + 1]; // preload preloadCases cases of B_X hidacts

    const int tidx = B_X * threadIdx.y + threadIdx.x;
    const int loadY = tidx / preloadCases, loadX = tidx % preloadCases;

    const int filterPixels = filterSize * filterSize;
    const int imgPixels = imgSize * imgSize;

    const int numFilterBlocks = numFilters / (B_X * filtersPerThread);
    const int outputModuleIdx = blockIdx.x / numFilterBlocks;
    const int moduleIdx = modulesPerBlock * outputModuleIdx;
    const int blockFilterIdx = filtersPerThread * B_X * (blockIdx.x % numFilterBlocks);
    const int numModules = numModulesX * numModulesX;
    
    const int numFiltersPerGroup = numFilters / numGroups;
    const int blockGroupIdx = blockFilterIdx / numFiltersPerGroup;
    const int numFilterColors = numImgColors / numGroups;
    
    const int blockPixelOffset = (blockIdx.y / (numFilterColors/colorsPerThread)) * B_Y;
    const int filterColorIdx = (blockIdx.y % (numFilterColors/colorsPerThread)) * colorsPerThread;
    const int imgColorIdx = filterColorIdx + blockGroupIdx * numFilterColors;

    images += imgColorIdx * imgPixels * imgStride + loadX;

    hidActs += moduleIdx * numImages
            + blockFilterIdx * numImages * numModules
            + loadY * numImages * numModules
            + loadX;
    
    targets += outputModuleIdx * numFilters * filterPixels * numFilterColors
            + filterColorIdx * filterPixels * numFilters
            + blockPixelOffset * numFilters
            + blockFilterIdx
            + threadIdx.y * numFilters + threadIdx.x;

    float* shHidActLoad = &shHidActs[loadY][loadX];
    float* shImgLoad = &shImages[loadY][loadX];
    float prod[colorsPerThread][filtersPerThread];
    #pragma unroll
    for (int c = 0; c < colorsPerThread; c++) {
        #pragma unroll
        for (int f = 0; f < filtersPerThread; f++) {
            prod[c][f] = 0;
        }
    }
    // This avoids doing a division in an inner loop
    __shared__ int pxDivs[B_Y];
    __shared__ int pxMods[B_Y];
    if (tidx < B_Y) {
        pxDivs[tidx] = (blockPixelOffset + tidx) / filterSize;
        pxMods[tidx] = (blockPixelOffset + tidx) % filterSize;
    }
    __syncthreads();
    for (int m = moduleIdx; m < moduleIdx + modulesPerBlock; m++) {
        const int imgLoadModPosY = paddingStart + (m / numModulesX) * moduleStride;
        const int imgLoadModPosX = paddingStart + (m % numModulesX) * moduleStride;
        for (int caseIdx = 0; caseIdx < numImages; caseIdx += preloadCases) {
            if (loadY < B_Y) {
                /*
                 * As long as B_Y * B_X is divisible by preloadCases this will loop the right
                 * number of times.
                 *
                 * This will load some images from filter pixels that don't exist (it'll set those to 0),
                 * but the code does not produce any output for those pixels (see last lines).
                 */
    //            #pragma unroll
                for (int y = 0; y < B_Y; y += (B_X * B_Y) / preloadCases) {
                    // Make sure number of rows in the array is divisible by number of rows filled per iteration
                    if (B_Y % (B_X * B_Y / preloadCases) == 0 || y + loadY < B_Y) {
                        const int pxIdx = loadY + y; // pixel idx in filter

                        if (pxIdx + blockPixelOffset < filterPixels && (!checkCaseBounds || caseIdx + loadX < numImages)) {
                            const int pxY = imgLoadModPosY + pxDivs[pxIdx];//pxIdx / filterSize; // pixel x,y coords in image
                            const int pxX = imgLoadModPosX + pxMods[pxIdx];
                            if (pxY >= 0 && pxY < imgSize && pxX >= 0 && pxX < imgSize) {
                                const int pixIdx = (pxY * imgSize + pxX) * imgStride; // pixel idx in image
                                #pragma unroll
                                for (int c = 0; c < colorsPerThread; c++) {
                                    shImgLoad[(y + c * B_Y) * preloadCases] = images[caseIdx + c * imgPixels * imgStride + pixIdx];
                                }
                            } else {
                                #pragma unroll
                                for (int c = 0; c < colorsPerThread; c++) {
                                    shImgLoad[(y + c * B_Y) * preloadCases] = 0;
                                }
                            }
                        } else {
                            #pragma unroll
                            for (int c = 0; c < colorsPerThread; c++) {
                                shImgLoad[(y + c * B_Y) * preloadCases] = 0;
                            }
                        }
                    }
                }
            }
            if (loadY < B_X * filtersPerThread && (!checkCaseBounds || caseIdx + loadX < numImages)) {
                #pragma unroll
                for (int y = 0; y < B_X * filtersPerThread; y += (B_X * B_Y) / preloadCases) {
                    // Make sure number of rows in the array is divisible by number of rows filled per iteration
                    if ((B_X * filtersPerThread) % (B_X * B_Y / preloadCases) == 0 || y + loadY < B_X * filtersPerThread) {
                        shHidActLoad[y * (preloadCases + 1)] = hidActs[caseIdx + y * numImages * numModules];
                    }
                }
            }

            __syncthreads();

            #pragma unroll
            for (int c = 0; c < colorsPerThread; c++) {
                #pragma unroll
                for (int i = 0; i < preloadCases; i++) {
                    #pragma unroll
                    for (int f = 0; f < filtersPerThread; f++) {
                        prod[c][f] += shImages[threadIdx.y + c * B_Y][i] * shHidActs[threadIdx.x + f * B_X][i];
                    }
                }
            }
            __syncthreads();
        }
        hidActs += numImages;
    }
    if (blockPixelOffset + threadIdx.y < filterPixels) {
        if (scale) {
            #pragma unroll
            for (int f = 0; f < filtersPerThread; f++) {
                #pragma unroll
                for (int c = 0; c < colorsPerThread; c++) {
                    targets[c * filterPixels * numFilters + f * B_X] = scaleTargets * targets[c * filterPixels * numFilters + f * B_X] + scaleOutput * prod[c][f];
                }
            }
        } else {
            #pragma unroll
            for (int f = 0; f < filtersPerThread; f++) {
                #pragma unroll
                for (int c = 0; c < colorsPerThread; c++) {
                    targets[c * filterPixels * numFilters + f * B_X] = prod[c][f];
                }
            }
        }
    }
}

/*
 * images:      (numImgColors, imgPixels, numImages), with stride given
 * hidActs:     (numFilters, numModules, numImages)
 *
 * targets:     (numModules, numFilterColors, filterPixels, numFilters)
 *
 * images: The images matrix.
 * hidActs: The filter activity matrix.
 * targets: Result matrix.
 * numModulesX: number of filter applications in the x (or equivalently y) dimension. So the total
 *              number of modules will be the square of this number.
 * filterSize: the width (or equivalently height) of the filter.
 * paddingStart: non-positive number indicating where the first filter should be applied.
 * moduleStride: stride between filter applications.
 * numColors: number of color channels in images and filters.
 * hidActsOrder: how the hidActs matrix is laid out (see hidActs comment above).
 */
void convWeightActs(NVMatrix& images, NVMatrix& hidActs, NVMatrix& targets,
                       int numModulesX, int filterSize, int paddingStart, int moduleStride, int numImgColors, int numGroups) {
    convWeightActs(images, hidActs, targets, numModulesX, filterSize, paddingStart, moduleStride, numImgColors, numGroups, 0, 1, 0);
}

void convWeightActs(NVMatrix& images, NVMatrix& hidActs, NVMatrix& targets,
        int numModulesX, int filterSize, int paddingStart, int moduleStride, int numImgColors,
        int numGroups, float scaleTargets, float scaleOutput, int moduleSum) {
    
    int numFilterColors = numImgColors / numGroups;
    int imgStride = images.getStride();
    int numImages = images.getNumCols();
    int imgPixels = images.getNumRows() / numImgColors;
    int imgSize = int(sqrt(imgPixels));
    int numModules = numModulesX * numModulesX;
    int numFilters = hidActs.getNumRows() / numModules;
    int numFiltersPerGroup = numFilters / numGroups;
    
    assert(numImgColors % numGroups == 0);
    assert(numFilters % (16*numGroups) == 0);
    assert(numGroups > 1 || (numImgColors > 0 && (numImgColors <= 3 || numImgColors % 4 == 0)));
    assert(numGroups == 1 || numFilterColors % 4 == 0);
    assert(imgSize * imgSize == imgPixels);
    assert(images.getNumRows() == imgPixels * numImgColors);

    int filterPixels = filterSize * filterSize;
    moduleSum = moduleSum == 0 ? numModules : moduleSum;

    assert(numModules % moduleSum == 0);
    assert(hidActs.getNumCols() == numImages);

    // These routines don't handle the case when only part of the image is visited in the convolution
    assert(paddingStart <= 0 && paddingStart + (numModules-1)*moduleStride + filterSize >= imgSize);
    assert(moduleStride <= filterSize);
    
    assert(numModules * numFilters == hidActs.getNumRows());

    assert(!images.isTrans());
    assert(!hidActs.isTrans());
    assert(hidActs.isContiguous());

    assert(!targets.isTrans());
    assert(targets.isContiguous());
    
    int preloadCases = 32;

    dim3 blocks, threads;
    int bx, by;
    int pixelsPerThread, filtersPerThread, colorsPerThread;
    // Worth playing with these parameters to find best values for your problem.
    // These values work relatively well, but not optimal for all problems.
    if (numFilterColors > 3) {
        if (numFiltersPerGroup % 32 == 0) {
            filtersPerThread = 2;
            colorsPerThread = numFilterColors % 8 == 0 ? 8 : 4;
            by = numFiltersPerGroup % 64 == 0 ? 4 : 8;
            bx = numFiltersPerGroup % 64 == 0 ? 32 : 16;
            blocks = dim3((numModules/moduleSum)*(numFilters/(bx*filtersPerThread)), DIVUP(filterPixels, by) * (numFilterColors / colorsPerThread));
        } else {
            // This routine (weight_acts_kernel2_manycolor) isn't really very good and it's only
            // called when the number of filters is 16. But I should probably get rid of it even in that case.
            pixelsPerThread = 2;
            colorsPerThread = numFilterColors % 8 == 0 ? 8 : 4;
            by = numFiltersPerGroup % 32 == 0 ? 4 : 8; // by == 4 seems to work best
            bx = numFiltersPerGroup % 32 == 0 ? 32 : 16; 
            blocks = dim3((numModules/moduleSum)*(numFilters/bx), DIVUP(filterPixels, by*pixelsPerThread) * (numFilterColors / colorsPerThread));
        }
    } else {
        assert(numGroups == 1); // Just for sanity
        pixelsPerThread = numFilters % 32 == 0 ? (numImgColors == 1 ? 8 : 5) : (numImgColors == 1 ? 5 : 2);
        by = numFilters % 32 == 0 ? 4 : 8; // by == 4 seems to work best
        bx = numFilters % 32 == 0 ? 32 : 16; 
        blocks = dim3((numModules/moduleSum)*(numFilters/bx), DIVUP(filterPixels, by*pixelsPerThread));
    }
    assert((by * bx) % preloadCases == 0);
    threads = dim3(bx, by);
    bool checkCaseBounds = numImages % 32 != 0;
    
    if (scaleTargets == 0 && scaleOutput == 1) {
        targets.resize((numModules/moduleSum) * numFilterColors*filterPixels, numFilters);
    } else {
        assert(targets.getNumRows() == (numModules/moduleSum) * numFilterColors*filterPixels);
        assert(targets.getNumCols() == numFilters);
    }
    if (numFilterColors > 3) {
        if (scaleTargets == 0 && scaleOutput == 1) { // do not scale
            if (numFiltersPerGroup % 32 == 0) {
                if (numFiltersPerGroup % 64 == 0) {
                    if (numFilterColors % 8 == 0) {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                } else {
                    if (numFilterColors % 8 == 0) {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                }
            } else {
                if (numFilterColors % 8 == 0) {
                    if (checkCaseBounds) {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,8,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,8,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,8,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,8,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,8,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,8,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,8,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,8,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                } else {
                    if (checkCaseBounds) {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,4,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,4,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,4,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,4,32,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,4,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,4,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,4,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,4,32,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                }
            }
        } else {
            if (numFiltersPerGroup % 32 == 0) {
                if (numFiltersPerGroup % 64 == 0) {
                    if (numFilterColors % 8 == 0) {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,8,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<4,32,2,4,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                } else {
                    if (numFilterColors % 8 == 0) {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,8,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (checkCaseBounds) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32, false, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32, false, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor_manyfilter<8,16,2,4,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                }
            } else {
                if (numFilterColors % 8 == 0) {
                    if (checkCaseBounds) {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,8,32, true, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,8,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,8,32, true, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,8,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,8,32, true, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,8,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,8,32, true, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,8,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                } else {
                    if (checkCaseBounds) {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,4,32, true, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,4,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,4,32, true, true>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,4,32,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    } else {
                        if (numFiltersPerGroup % 32 == 0) {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<4,32,2,4,32, true, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<4,32,2,4,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        } else {
                            cudaFuncSetCacheConfig(weight_acts_kernel2_manycolor<8,16,2,4,32, true, false>, cudaFuncCachePreferShared);
                            weight_acts_kernel2_manycolor<8,16,2,4,32,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                                           numImages, numFilters, numModulesX, imgSize, filterSize,
                                                                                           paddingStart, moduleStride, imgStride, numImgColors, moduleSum, numGroups, scaleTargets, scaleOutput);
                        }
                    }
                }
            }
        }
    } else { // numColors in 1,2,3
        if (scaleTargets == 0 && scaleOutput == 1) { // do not scale
            if (numFilterColors == 1) {
                if (checkCaseBounds) {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,8,32,1, false, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,8,32,1,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,5,32,1, false, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,5,32,1,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                } else {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,8,32,1, false, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,8,32,1,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,5,32,1, false, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,5,32,1,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                }
            } else if (numFilterColors == 2) {
                if (checkCaseBounds) {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,2, false, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,2,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,2, false, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,2,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                } else {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,2, false, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,2,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,2, false, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,2,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                }
            } else if (numFilterColors == 3) {
                if (checkCaseBounds) {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,3, false, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,3,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,3, false, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,3,false, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                } else {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,3, false, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,3,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,3, false, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,3,false, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                }
            }

        } else { // do scale
            if (numFilterColors == 1) {
                if (checkCaseBounds) {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,8,32,1, true, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,8,32,1,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,5,32,1, true, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,5,32,1,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                } else {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,8,32,1, true, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,8,32,1,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,5,32,1, true, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,5,32,1,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                }
            } else if (numFilterColors == 2) {
                if (checkCaseBounds) {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,2, true, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,2,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,2, true, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,2,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                } else {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,2, true, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,2,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,2, true, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,2,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                }
            } else if (numFilterColors == 3) {
                if (checkCaseBounds) {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,3, true, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,3,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,3, true, true>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,3,true, true><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                } else {
                    if (numFilters % 32 == 0) {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<4,32,5,32,3, true, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<4,32,5,32,3,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    } else {
                        cudaFuncSetCacheConfig(weight_acts_kernel2_color<8,16,2,32,3, true, false>, cudaFuncCachePreferShared);
                        weight_acts_kernel2_color<8,16,2,32,3,true, false><<<blocks, threads>>>(images.getDevData(), hidActs.getDevData(), targets.getDevData(),
                                                                numImages, numFilters, numModulesX, imgSize, filterSize, paddingStart, moduleStride, imgStride, moduleSum, scaleTargets, scaleOutput);
                    }
                }
            }
        }
    }
    cutilCheckMsg("convWeightActs: kernel execution failed");
}