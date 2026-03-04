/**
 * Product Quantization (PQ) for Vector Compression
 * 
 * P1-46: Product Quantization Implementation
 * 
 * Product Quantization compresses high-dimensional vectors by splitting them
 * into subvectors and quantizing each subvector independently using k-means
 * clustering. This enables:
 * - 4-32x memory reduction
 * - Fast approximate distance computation using lookup tables
 * - Efficient large-scale similarity search
 * 
 * Algorithm Overview:
 * 1. Split D-dimensional vector into M subvectors of D/M dimensions
 * 2. Train k-means codebook for each subspace (typically k=256)
 * 3. Encode each subvector as its nearest centroid ID (1 byte)
 * 4. Store M bytes per vector instead of D*4 bytes
 * 
 * Example (1536-dim, M=96):
 * - Original: 1536 * 4 = 6144 bytes
 * - Compressed: 96 * 1 = 96 bytes
 * - Compression ratio: 64x
 * 
 * Distance Computation:
 * - Precompute distance table: query to all centroids
 * - For each database vector: sum lookup table values
 * - Complexity: O(M) instead of O(D)
 */

#include <cmath>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <random>
#include <limits>

namespace kuzu {
namespace extension {
namespace vector {

/**
 * Product Quantization Configuration
 */
struct PQConfig {
    size_t dimension;           // Full vector dimension D
    size_t numSubspaces;        // Number of subspaces M (D must be divisible by M)
    size_t numCentroids;        // Centroids per subspace (typically 256)
    size_t subspaceDim;         // D / M
    size_t maxIterations;       // K-means iterations
    float convergenceThreshold; // K-means convergence threshold
    
    PQConfig(size_t dim = 1536, size_t m = 96, size_t k = 256)
        : dimension(dim), numSubspaces(m), numCentroids(k),
          maxIterations(25), convergenceThreshold(1e-6f) {
        subspaceDim = dimension / numSubspaces;
    }
};

/**
 * Product Quantization Index
 * 
 * Stores codebooks and provides encode/decode/search operations.
 */
class ProductQuantization {
public:
    explicit ProductQuantization(const PQConfig& config)
        : config_(config) {
        // Allocate codebook storage
        // Shape: [numSubspaces][numCentroids][subspaceDim]
        codebooks_.resize(config_.numSubspaces);
        for (auto& cb : codebooks_) {
            cb.resize(config_.numCentroids * config_.subspaceDim);
        }
    }
    
    /**
     * Train PQ codebooks using k-means on training vectors
     */
    void train(const std::vector<float>& trainingData, size_t numVectors) {
        // For each subspace, run k-means on the corresponding dimensions
        for (size_t m = 0; m < config_.numSubspaces; m++) {
            trainSubspace(m, trainingData, numVectors);
        }
        trained_ = true;
    }
    
    /**
     * Encode a single vector into PQ codes
     * 
     * @param vector Input vector of size config_.dimension
     * @param codes Output codes of size config_.numSubspaces
     */
    void encode(const float* vector, uint8_t* codes) const {
        for (size_t m = 0; m < config_.numSubspaces; m++) {
            codes[m] = encodeSubvector(m, vector + m * config_.subspaceDim);
        }
    }
    
    /**
     * Encode multiple vectors
     */
    void encodeBatch(const std::vector<float>& vectors, size_t numVectors,
                     std::vector<uint8_t>& codes) const {
        codes.resize(numVectors * config_.numSubspaces);
        for (size_t i = 0; i < numVectors; i++) {
            encode(vectors.data() + i * config_.dimension,
                   codes.data() + i * config_.numSubspaces);
        }
    }
    
    /**
     * Decode PQ codes back to approximate vector
     */
    void decode(const uint8_t* codes, float* output) const {
        for (size_t m = 0; m < config_.numSubspaces; m++) {
            const float* centroid = getCentroid(m, codes[m]);
            std::copy(centroid, centroid + config_.subspaceDim,
                     output + m * config_.subspaceDim);
        }
    }
    
    /**
     * Compute distance table for asymmetric distance computation (ADC)
     * 
     * @param query Query vector
     * @param distanceTable Output table [numSubspaces][numCentroids]
     */
    void computeDistanceTable(const float* query,
                              std::vector<float>& distanceTable) const {
        distanceTable.resize(config_.numSubspaces * config_.numCentroids);
        
        for (size_t m = 0; m < config_.numSubspaces; m++) {
            const float* subQuery = query + m * config_.subspaceDim;
            float* tableRow = distanceTable.data() + m * config_.numCentroids;
            
            for (size_t k = 0; k < config_.numCentroids; k++) {
                const float* centroid = getCentroid(m, k);
                tableRow[k] = l2DistanceSquared(subQuery, centroid, config_.subspaceDim);
            }
        }
    }
    
    /**
     * Compute approximate L2 distance using precomputed table
     * 
     * @param distanceTable Precomputed distances [numSubspaces][numCentroids]
     * @param codes PQ codes of target vector
     * @return Approximate squared L2 distance
     */
    float computeADCDistance(const std::vector<float>& distanceTable,
                             const uint8_t* codes) const {
        float distance = 0.0f;
        for (size_t m = 0; m < config_.numSubspaces; m++) {
            distance += distanceTable[m * config_.numCentroids + codes[m]];
        }
        return distance;
    }
    
    /**
     * Search for k nearest neighbors using ADC
     * 
     * @param query Query vector
     * @param codes Database PQ codes [numVectors * numSubspaces]
     * @param numVectors Number of database vectors
     * @param k Number of neighbors to return
     * @param indices Output indices of k nearest neighbors
     * @param distances Output distances to k nearest neighbors
     */
    void search(const float* query, const uint8_t* codes, size_t numVectors,
                size_t k, std::vector<size_t>& indices,
                std::vector<float>& distances) const {
        // Compute distance table once
        std::vector<float> distanceTable;
        computeDistanceTable(query, distanceTable);
        
        // Compute all distances using table lookups
        std::vector<std::pair<float, size_t>> allDistances(numVectors);
        for (size_t i = 0; i < numVectors; i++) {
            float dist = computeADCDistance(distanceTable,
                                           codes + i * config_.numSubspaces);
            allDistances[i] = {dist, i};
        }
        
        // Partial sort to get top-k
        std::partial_sort(allDistances.begin(), allDistances.begin() + k,
                         allDistances.end());
        
        // Extract results
        indices.resize(k);
        distances.resize(k);
        for (size_t i = 0; i < k; i++) {
            indices[i] = allDistances[i].second;
            distances[i] = allDistances[i].first;
        }
    }
    
    /**
     * Get compression ratio
     */
    float getCompressionRatio() const {
        size_t originalBytes = config_.dimension * sizeof(float);
        size_t compressedBytes = config_.numSubspaces * sizeof(uint8_t);
        return static_cast<float>(originalBytes) / compressedBytes;
    }
    
    /**
     * Get memory footprint for codebooks
     */
    size_t getCodebookMemory() const {
        return config_.numSubspaces * config_.numCentroids * 
               config_.subspaceDim * sizeof(float);
    }
    
    const PQConfig& getConfig() const { return config_; }
    bool isTrained() const { return trained_; }

private:
    PQConfig config_;
    std::vector<std::vector<float>> codebooks_; // [M][K*d]
    bool trained_ = false;
    
    /**
     * Get centroid for subspace m, centroid index k
     */
    const float* getCentroid(size_t m, size_t k) const {
        return codebooks_[m].data() + k * config_.subspaceDim;
    }
    
    float* getCentroid(size_t m, size_t k) {
        return codebooks_[m].data() + k * config_.subspaceDim;
    }
    
    /**
     * Train k-means for a single subspace
     */
    void trainSubspace(size_t m, const std::vector<float>& data, size_t numVectors) {
        // Extract subvectors for this subspace
        std::vector<float> subvectors(numVectors * config_.subspaceDim);
        for (size_t i = 0; i < numVectors; i++) {
            const float* src = data.data() + i * config_.dimension + m * config_.subspaceDim;
            float* dst = subvectors.data() + i * config_.subspaceDim;
            std::copy(src, src + config_.subspaceDim, dst);
        }
        
        // Run k-means
        kmeans(subvectors, numVectors, codebooks_[m]);
    }
    
    /**
     * K-means clustering
     */
    void kmeans(const std::vector<float>& data, size_t numVectors,
                std::vector<float>& centroids) {
        const size_t d = config_.subspaceDim;
        const size_t k = config_.numCentroids;
        
        // Initialize centroids randomly
        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_int_distribution<size_t> dist(0, numVectors - 1);
        
        for (size_t i = 0; i < k; i++) {
            size_t idx = dist(gen);
            std::copy(data.data() + idx * d, data.data() + (idx + 1) * d,
                     centroids.data() + i * d);
        }
        
        std::vector<size_t> assignments(numVectors);
        std::vector<float> newCentroids(k * d);
        std::vector<size_t> counts(k);
        
        for (size_t iter = 0; iter < config_.maxIterations; iter++) {
            // Assign points to nearest centroid
            for (size_t i = 0; i < numVectors; i++) {
                float minDist = std::numeric_limits<float>::max();
                size_t bestK = 0;
                
                for (size_t j = 0; j < k; j++) {
                    float dist = l2DistanceSquared(data.data() + i * d,
                                                  centroids.data() + j * d, d);
                    if (dist < minDist) {
                        minDist = dist;
                        bestK = j;
                    }
                }
                assignments[i] = bestK;
            }
            
            // Update centroids
            std::fill(newCentroids.begin(), newCentroids.end(), 0.0f);
            std::fill(counts.begin(), counts.end(), 0);
            
            for (size_t i = 0; i < numVectors; i++) {
                size_t c = assignments[i];
                counts[c]++;
                for (size_t j = 0; j < d; j++) {
                    newCentroids[c * d + j] += data[i * d + j];
                }
            }
            
            // Average and check convergence
            float maxShift = 0.0f;
            for (size_t c = 0; c < k; c++) {
                if (counts[c] > 0) {
                    for (size_t j = 0; j < d; j++) {
                        newCentroids[c * d + j] /= counts[c];
                    }
                }
                float shift = l2DistanceSquared(centroids.data() + c * d,
                                               newCentroids.data() + c * d, d);
                maxShift = std::max(maxShift, shift);
            }
            
            centroids = newCentroids;
            
            if (maxShift < config_.convergenceThreshold) {
                break;
            }
        }
    }
    
    /**
     * Find nearest centroid for a subvector
     */
    uint8_t encodeSubvector(size_t m, const float* subvector) const {
        float minDist = std::numeric_limits<float>::max();
        uint8_t bestK = 0;
        
        for (size_t k = 0; k < config_.numCentroids; k++) {
            float dist = l2DistanceSquared(subvector, getCentroid(m, k),
                                          config_.subspaceDim);
            if (dist < minDist) {
                minDist = dist;
                bestK = static_cast<uint8_t>(k);
            }
        }
        
        return bestK;
    }
    
    /**
     * Squared L2 distance (inline for performance)
     */
    static float l2DistanceSquared(const float* a, const float* b, size_t d) {
        float sum = 0.0f;
        for (size_t i = 0; i < d; i++) {
            float diff = a[i] - b[i];
            sum += diff * diff;
        }
        return sum;
    }
};

} // namespace vector
} // namespace extension
} // namespace kuzu

/**
 * Usage Example:
 * 
 * // Configure PQ (1536-dim vectors, 96 subspaces, 256 centroids)
 * PQConfig config(1536, 96, 256);
 * ProductQuantization pq(config);
 * 
 * // Train on sample data
 * pq.train(trainingVectors, numTrainingVectors);
 * 
 * // Encode database
 * std::vector<uint8_t> codes;
 * pq.encodeBatch(databaseVectors, numDatabaseVectors, codes);
 * 
 * // Search
 * std::vector<size_t> indices;
 * std::vector<float> distances;
 * pq.search(queryVector, codes.data(), numDatabaseVectors, 10, indices, distances);
 * 
 * Compression Ratios:
 * | Dimension | M | Compression | Memory/1M vectors |
 * |-----------|---|-------------|-------------------|
 * | 1536 | 96 | 64x | 91 MB |
 * | 1536 | 48 | 128x | 46 MB |
 * | 768 | 48 | 64x | 46 MB |
 * | 384 | 24 | 64x | 23 MB |
 */