/* 
 * File:   layer.cuh
 * Author: Alex Krizhevsky (akrizhevsky@gmail.com)
 *
 * Created on June 11, 2011, 6:19 AM
 */

#ifndef LAYER_CUH
#define	LAYER_CUH

#include <string>
#include <vector>
#include <map>
#include <cutil_inline.h>
#include <assert.h>
#include <nvmatrix.cuh>
#include <matrix.h>
#include <CudaConv2.cuh>

#include "ConvNet.cuh"
#include "data.cuh"
#include "error.cuh"
#include "weights.cuh"
#include "neuron.cuh"
#include "util.cuh"
#include "layer_kernels.cuh"

class ErrorResult;
class ConvNet;
class CostLayer;
class DataLayer;

/*
 * Abstract layer.
 */
class Layer {
protected:
    std::vector<Layer*> _prev, _next;
    int _rcvdFInputs, _rcvdBInputs;
    NVMatrix _acts, _actGrads;
    bool _gradConsumer, _gradProducer, _trans;
    int _numGradProducersNext;
    std::string _name;
    void fpropNext();
    virtual void truncBwdActs(); 
    virtual void _fprop(NVMatrixV& v) = 0;
    virtual void bpropCommon(NVMatrix& v) {
        // do nothing by default
    }
    virtual void bpropActs(NVMatrix& v) {
        assert(!_gradProducer); // only do nothing if not grad producer
    }
    virtual void bpropWeights(NVMatrix& v) {
        // do nothing if this layer has no weights
    }
public:
    static bool _saveActGrads, _saveActs, _checkingGrads;
    
    Layer(PyObject* paramsDict,
          bool gradConsumer, bool gradProducer, bool trans);
    
    virtual void updateWeights(int numCases) {
        // do nothing if this layer has no weights
    }
    
    virtual void checkGradients(ConvNet* convNet) {
        // do nothing if this layer has no weights
    }
    
    virtual void fprop();
    void fprop(NVMatrix& v);
    virtual void fprop(NVMatrixV& v);
    virtual void bprop();
    void bprop(NVMatrix& v);
    void reset();
    int getRcvdFInputs();
    int getRcvdBInputs();
    bool isGradConsumer();
    bool isGradProducer();
    std::string& getName();
    void addNext(Layer* l);
    void addPrev(Layer* l);
    std::vector<Layer*>& getPrev();
    std::vector<Layer*>& getNext();
    NVMatrix& getActs();
    NVMatrix& getActGrads();

    virtual void copyToCPU() {
        // do nothing if this layer has no weights
    }
    
    virtual void copyToGPU()  {
        // do nothing if this layer has no weights
    }
};

class FCLayer : public Layer {
private:
    WeightList _weights;
    Weights _biases;
    Neuron* _neuron;
    void multByInput(NVMatrix& input, int idx);
protected:
    void _fprop(NVMatrixV& v);
    void bpropCommon(NVMatrix& v);
    void bpropActs(NVMatrix& v);
    void bpropWeights(NVMatrix& v);
public:
    FCLayer(PyObject* paramsDict);
 
    void updateWeights(int numCases);  
    void copyToCPU();
    void copyToGPU();
    void checkGradients(ConvNet* convNet);
};

class SoftmaxLayer : public Layer {
protected:
    void _fprop(NVMatrixV& v);
    void bpropActs(NVMatrix& v);
public:
    SoftmaxLayer(PyObject* paramsDict);
};

class DataLayer : public Layer {
private:
    int _dataIdx;
protected:
    void _fprop(NVMatrixV& data);
public:
    DataLayer(PyObject* paramsDict);
    
    void fprop();
    void fprop(NVMatrixV& data);
};

class ConvLayer : public Layer {
private:
    Weights _weights, _biases;
    Neuron* _neuron;
    int _modulesX, _padding, _stride, _filterSize, _channels, _imgSize;
    int _imgPixels, _filterPixels, _modules;
    int _partialSum;
    int _numFilters;
    bool _sharedBiases;
    NVMatrix _weightGradsTmp;
protected:
    void _fprop(NVMatrixV& v);
    void bpropCommon(NVMatrix& v);
    void bpropActs(NVMatrix& v);
    void bpropWeights(NVMatrix& v);
    void truncBwdActs();
public:
    ConvLayer(PyObject* paramsDict);

    void updateWeights(int numCases);  
    void copyToCPU();
    void copyToGPU();
    void checkGradients(ConvNet* convNet);
}; 

class PoolLayer : public Layer {
private:
    int _channels, _sizeX, _start, _stride, _outputsX;
    int _imgSize;
    string _pool;
protected:
    void _fprop(NVMatrixV& v);
    void bpropActs(NVMatrix& v);
public:
    PoolLayer(PyObject* paramsDict);
}; 

class ContrastNormLayer : public Layer {
private:
    int _channels, _sizeX;
    float _scale;
    NVMatrix _denoms;
protected:
    void _fprop(NVMatrixV& v);
    void bpropActs(NVMatrix& v);
    void truncBwdActs();
public:
    ContrastNormLayer(PyObject* paramsDict);
}; 

class CostLayer : public Layer {
protected:
    double _coeff;
    doublev _err;
public:
    CostLayer(PyObject* paramsDict, bool gradConsumer, bool gradProducer, bool trans);
    void bprop(); // This is what's called by other layers
    virtual doublev& getError();
    double getCoeff();
    
    static CostLayer& makeCostLayer(string& type, PyObject* paramsDict);
};

/*
 * input 0: labels
 * input 1: logistic regression outputs
 */
class LogregCostLayer : public CostLayer {
protected:
    void _fprop(NVMatrixV& v);
    void bpropActs(NVMatrix& v);
public:
    LogregCostLayer(PyObject* paramsDict);
};

#endif	/* LAYER_CUH */
